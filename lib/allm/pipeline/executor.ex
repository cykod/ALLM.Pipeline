defmodule ALLM.Pipeline.Executor do
  @moduledoc """
  Base utilities for executing pipeline steps.

  Provides step execution, validation, and artifact storage.
  Specific pipelines (CommitteePipeline, MeetingsPipeline, etc.) use these
  utilities to orchestrate their domain-specific flows.

  ## Persistence goes through `ALLM.Pipeline.Store`

  Every run/step write and read here dispatches through `store()`
  (= `ALLM.Pipeline.Store.impl/0`, the host-wired adapter, default
  `ALLM.Pipeline.Store.Ecto`) rather than naming `PipelineRun` / `StepLog`
  directly.

  **Two calls deliberately do NOT:** `PipelineRun.borrow/1` (in
  `borrowed_run/1`) and `PipelineRun.assume_ownership/1` (named in `resume/2`'s
  `@doc`). Both are pure struct operations on the completion token with no
  backend involvement, so they are absent from the behaviour on purpose —
  routing them through an adapter is how a third token mint point gets created.
  See `ALLM.Pipeline.Store`'s "Not callbacks" section.
  """

  alias ALLM.Pipeline.{
    PipelineRun,
    StepLog,
    ArtifactStore,
    Context,
    Step,
    Store,
    LLMCallLog,
    Telemetry,
    Text
  }

  require Logger

  @type run_step_result ::
          {:ok, StepLog.t(), output :: struct()}
          | {:error, StepLog.t() | nil, reason :: term()}

  @doc """
  Create a new pipeline run record.

  The returned run is the **owning** handle: it carries the completion token
  that `PipelineRun.complete/2` requires. Lend it to an inner pipeline through
  the `:pipeline_run` opt and the inner side strips the token via
  `borrowed_run/1`, so only this caller can complete the run.

  `attrs` carries first-class COLUMN values — `:trigger` (what fired the run)
  and `:parent_run_id` (a linking sub-pipeline parent). They ride as scalar
  changeset fields, NOT through `metadata`, so they stay SQL/GraphQL-filterable
  (Subphase 2).

  When `:trigger` is absent from `attrs`, it is backfilled from the process
  dictionary via `trigger_from_process/0` (cron-stamped `"cron:<name>"`, else
  `"cli"`). This is the single default point so every cron-dispatchable pipeline
  records the right trigger without each call site re-supplying it, and ad-hoc
  CLI single runs (which pass no `attrs`) are consistently tagged `"cli"` rather
  than `nil`. A call site can still override by passing `:trigger` explicitly.
  """
  @spec create_pipeline_run(String.t(), map(), keyword()) ::
          {:ok, PipelineRun.t()} | {:error, Ecto.Changeset.t()}
  def create_pipeline_run(name, metadata \\ %{}, attrs \\ []) do
    attrs = Keyword.put_new_lazy(attrs, :trigger, &trigger_from_process/0)

    # `PipelineRun.create/3` encodes `metadata` itself. `Encodable.encode/1` is
    # idempotent, so this used to be applied twice on this path with two
    # DIFFERENT rule sets (design doc §2.11) — now it is applied once, there.
    case store().create_run(name, metadata, attrs) do
      {:ok, pipeline_run} ->
        # `Repo.update` carries `changeset.data`'s virtual fields through, so
        # the completion token minted by `create/3` survives `start/1`.
        case store().start_run(pipeline_run) do
          {:ok, run} = ok ->
            # The single run-creation point, so `[:allm_pipeline, :run, :start]`
            # fires once per self-owned run (a borrowed pipeline never gets
            # here). See `ALLM.Pipeline.Telemetry`'s run-family accounting.
            Telemetry.run_start(%{name: run.name, run_id: run.id, trigger: run.trigger})
            ok

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc """
  Resolve a **borrowed** pipeline run from an inner pipeline's `opts`.

  The canonical borrowed-run boundary. An umbrella pipeline lends its run by
  putting it under the `:pipeline_run` opt; the inner pipeline reads it here and
  receives a NON-OWNING handle (`PipelineRun.borrow/1`), so an accidental
  `PipelineRun.complete/2` on the inner side is a detectable
  `{:error, :not_run_owner}` rather than a silent mid-loop `:success` that
  clobbers the umbrella's aggregate metadata.

  The strip happens on RECEIPT rather than at the lending call site on purpose:
  a future umbrella that forgets to mark its lend still cannot have its run
  completed out from under it. Returns `:error` when no run was lent, which is
  the self-owned (`*_single` / CLI) branch.
  """
  @spec borrowed_run(keyword()) :: {:ok, PipelineRun.t()} | :error
  def borrowed_run(opts) do
    case Keyword.fetch(opts, :pipeline_run) do
      {:ok, %PipelineRun{} = pipeline_run} -> {:ok, PipelineRun.borrow(pipeline_run)}
      _ -> :error
    end
  end

  @doc """
  The `trigger` value for a run, sourced from the process dictionary.

  `AmesburyScraper.Runner` (the cron entry point) stamps `:pipeline_trigger`
  before dispatching synchronously in the same process, so a pipeline's own
  `create_pipeline_run` call reads it here. Absent (the dev `mix scraper.run`
  path, which never goes through the cron Runner, and any direct/`iex` call),
  it falls back to `"cli"`. Best-effort: this never raises.
  """
  @spec trigger_from_process() :: String.t()
  def trigger_from_process do
    Process.get(:pipeline_trigger, "cli")
  end

  @doc """
  Execute a single step with typed I/O validation and logging.

  ## Parameters

  - `pipeline_run` - The parent pipeline run
  - `step_module` - Module implementing the Step behavior
  - `input_struct` - Validated input struct matching the step's input_schema
  - `input_step_id` - Optional ID of the step that produced this input (for lineage)
  - `opts` - Additional options passed to the step context

  ## Returns

  - `{:ok, step_log, output_struct}` on success
  - `{:error, step_log, reason}` on failure
  - `{:error, nil, reason}` when the failure happened before a step log existed
    (input-schema mismatch, or the `step_logs` insert itself failing)

  **Never raises for a failure it can name.** Callers fan this out through
  `Task.async_stream`, which LINKS its children — so a raise here kills the whole
  fan-out (and, with `trap_exit` off, the caller process itself) rather than
  failing one item. Every failure path therefore returns a tuple.
  """
  @spec run_step(PipelineRun.t(), module(), struct(), Ecto.UUID.t() | nil, keyword()) ::
          run_step_result()
  def run_step(pipeline_run, step_module, input_struct, input_step_id \\ nil, opts \\ []) do
    # Validate input against schema. The CAST struct is what proceeds, not the
    # caller's term — see `validate_input/2`.
    case validate_input(step_module, input_struct) do
      {:ok, cast_input} ->
        execute_step(pipeline_run, step_module, cast_input, input_step_id, opts)

      {:error, reason} ->
        Logger.error("Input validation failed for #{step_module}: #{inspect(reason)}")
        {:error, nil, reason}
    end
  end

  @doc """
  Log a section marker for visual grouping in the admin pipeline review UI.
  """
  @spec log_section(PipelineRun.t(), String.t(), Ecto.UUID.t() | nil) ::
          {:ok, StepLog.t()} | {:error, Ecto.Changeset.t()}
  def log_section(pipeline_run, title, input_step_id \\ nil) do
    store().log_section(pipeline_run.id, title, input_step_id)
  end

  @doc """
  Record a step carrying structured `output_data` (e.g. a decision-log summary)
  for inspection in the pipeline-review UI.
  """
  @spec log_summary(PipelineRun.t(), String.t(), map(), Ecto.UUID.t() | nil) ::
          {:ok, StepLog.t()} | {:error, Ecto.Changeset.t()}
  def log_summary(pipeline_run, step_type, output_data, input_step_id \\ nil) do
    store().log_summary(pipeline_run.id, step_type, output_data, input_step_id)
  end

  @doc """
  Write a visible `:skipped` step log for a gate decision that declined to
  process an item — the record a `fan_out` body writes before it returns
  `{{:skipped, payload}, acc}`.

  `input_step_id` is the fan-out's parent (`Context.input_step_id(ctx)`), so the
  skip lands in the lineage tree at the position the processed step would have
  occupied. `reason` is stored jsonb-safe (see `StepLog.create_skipped/4`). The
  metric increment stays in the body — this call adds the LOG, not the count.
  """
  @spec log_skipped(PipelineRun.t(), String.t(), term(), Ecto.UUID.t() | nil) ::
          {:ok, StepLog.t()} | {:error, Ecto.Changeset.t()}
  def log_skipped(pipeline_run, step_type, reason, input_step_id \\ nil) do
    store().log_skipped(pipeline_run.id, step_type, reason, input_step_id)
  end

  @doc """
  Mark pipeline run as completed with statistics.

  Requires an owning handle — see `PipelineRun.complete/2`. The guard lives on
  the schema function, not here: this wrapper is only 2 of the 17 call sites
  that complete a run, so guarding it alone would leave the other 15 unprotected.
  """
  @spec complete_pipeline_run(PipelineRun.t(), [run_step_result()], [run_step_result()]) ::
          {:ok, PipelineRun.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}
  def complete_pipeline_run(pipeline_run, detail_results \\ [], transform_results \\ []) do
    stats = store().pipeline_stats(pipeline_run.id)

    result_metadata = %{
      stats: stats,
      detail_count: length(detail_results),
      transform_count: length(transform_results),
      detail_success_count: count_successes(detail_results),
      transform_success_count: count_successes(transform_results)
    }

    store().complete_run(pipeline_run, result_metadata)
  end

  @doc """
  Mark pipeline run as failed.

  Requires an owning handle, exactly as `complete_pipeline_run/3` does — see
  `PipelineRun.fail/2`. The guard lives on the schema function, not here, for
  the same reason: this wrapper is only some of the sites that fail a run.
  """
  @spec fail_pipeline_run(PipelineRun.t(), term()) ::
          {:ok, PipelineRun.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}
  def fail_pipeline_run(pipeline_run, error) do
    store().fail_run(pipeline_run, error)
  end

  @doc """
  Terminate the run you own according to `result`, and return `result` unchanged.

  The complete-or-fail tail every self-owned pipeline entry point needs. It lived
  hand-written in four places (three `run_list_only/1` helpers plus
  `VideoSummaryPipeline`'s own copy) before being lifted here, which is also
  where it belongs: "finish the run you own" is framework logic, not consumer
  logic, so it travels with `Executor` when the framework moves.

  Matches both result shapes the codebase produces — the 2-tuple a pipeline
  returns (`{:ok, stats}` / `{:error, reason}`) and the 3-tuple `run_step/5`
  returns (`{:ok, step_log, output}` / `{:error, step_log, reason}`). Callers
  whose own return shape differs from the result they pass in keep that
  translation at the call site; this helper never reshapes.

  Requires an owning handle — both branches now refuse a borrowed or re-loaded
  run (`PipelineRun.complete/2`, `PipelineRun.fail/2`).

  **It does NOT guard.** A raise, exit or throw between the caller's
  `create_pipeline_run/3` and this call strands the run at `:running`; this
  function only writes the terminal status for a `result` it is handed. An entry
  point that creates its own run wants `ALLM.Pipeline.Lifecycle.owned_run/4`,
  which owns creation, the guard and the metadata argument as well — see that
  module's "Versus `Executor.finish_run/2`" table for the boundary.
  """
  @spec finish_run(PipelineRun.t(), result) :: result when result: var
  def finish_run(pipeline_run, {:ok, _stats} = result) do
    store().complete_run(pipeline_run, %{})
    result
  end

  def finish_run(pipeline_run, {:ok, _step_log, _output} = result) do
    complete_pipeline_run(pipeline_run)
    result
  end

  def finish_run(pipeline_run, {:error, reason} = result) do
    fail_pipeline_run(pipeline_run, reason)
    result
  end

  def finish_run(pipeline_run, {:error, _step_log, reason} = result) do
    fail_pipeline_run(pipeline_run, reason)
    result
  end

  @doc """
  Re-open a failed pipeline run, having checked that `from_step_id` belongs to
  it. **Two limitations, both current behaviour rather than bugs to route
  around:**

  1. **It does not replay anything.** All it does is validate the step and put
     the run back to `:running` (`PipelineRun.start/1`); no step output is
     restored and no step is skipped, so a caller that re-drives the pipeline
     re-executes everything. Recorded in §2.5 of
     `steering/2026-08-10_ALLM_PIPELINE_EXTRACTION.md`; resume-from-log — step
     fingerprints, replaying a `:success` log instead of executing — is Phase 7
     (§3.11) and is not attempted here.
  2. **The returned handle is NOT an owner.** The run is loaded via
     `PipelineRun.get/1`, and `:completion_token` is virtual, so the handle
     comes back token-less by construction and `PipelineRun.complete/2`,
     `fail/2` and `cancel/1` all refuse it with `{:error, :not_run_owner}` — a
     caller that finishes the resumed run without noticing strands it at
     `:running`. A caller that means to finish it must say so explicitly:

         {:ok, run} = Executor.resume(run_id, step_id)
         run = PipelineRun.assume_ownership(run)

     Deliberately not re-minted inside this function: that would make `resume/2`
     a second, implicit mint point and undercut the invariant the whole
     ownership design rests on (user decision, 2026-08-13 — see
     `steering/2026-08-10_ALLM_PIPELINE_EXTRACTION_RECORDS.md`). Pinned by
     `pipeline_run_test.exs`'s "every terminal writer refuses a non-owning
     handle", which loops this provenance alongside borrowed and re-loaded ones.

  There are no production callers today; the callers are tests.
  """
  @spec resume(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def resume(pipeline_run_id, from_step_id) do
    case store().get_run(pipeline_run_id) do
      nil ->
        {:error, :pipeline_not_found}

      pipeline_run ->
        case store().get_step(from_step_id) do
          nil ->
            {:error, :step_not_found}

          step_log ->
            if step_log.pipeline_run_id == pipeline_run_id do
              # Mark pipeline as running again. `start/1` returns
              # `{:ok, run} | {:error, changeset}`, which is already this
              # function's declared return — pass it through rather than
              # bang-matching (a `MatchError` here escapes every caller).
              store().start_run(pipeline_run)
            else
              {:error, :step_not_in_pipeline}
            end
        end
    end
  end

  @doc """
  Get pipeline execution status and statistics.
  """
  @spec get_status(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def get_status(pipeline_run_id) do
    case store().get_run(pipeline_run_id) do
      nil ->
        {:error, :not_found}

      pipeline_run ->
        stats = store().pipeline_stats(pipeline_run_id)

        {:ok,
         %{
           pipeline_run: pipeline_run,
           stats: stats
         }}
    end
  end

  # Private functions

  # The `step_logs` insert is the LAST thing outside the try/rescue below, so a
  # failure here used to raise a `MatchError` straight through `run_step` and, via
  # `Task.async_stream`'s link, take down the whole fan-out. It fails for real
  # causes — an `input_data` jsonb the sanitizer missed (22P05), a `pipeline_run_id`
  # FK violation, a step module whose `step_type/0` is blank — so it is reported as
  # a normal step failure with no step log to attach it to.
  @spec execute_step(PipelineRun.t(), module(), struct(), Ecto.UUID.t() | nil, keyword()) ::
          run_step_result()
  defp execute_step(pipeline_run, step_module, input_struct, input_step_id, opts) do
    # Create step log record (status: running, captures start time)
    case store().log_step_start(pipeline_run.id, step_module, input_struct, input_step_id) do
      {:ok, step_log} ->
        run_with_step_log(pipeline_run, step_module, input_struct, step_log, opts)

      {:error, changeset} ->
        Logger.error(
          "Failed to log step start for #{inspect(step_module)} " <>
            "(pipeline_run #{pipeline_run.id}): #{inspect(changeset)}"
        )

        {:error, nil, {:step_log_start_failed, changeset}}
    end
  end

  @spec run_with_step_log(PipelineRun.t(), module(), struct(), StepLog.t(), keyword()) ::
          run_step_result()
  defp run_with_step_log(pipeline_run, step_module, input_struct, step_log, opts) do
    # Create execution context
    context = Context.new(pipeline_run, step_log, opts)

    # Start the per-step LLM-call collector before the step runs. The drain (in
    # the handlers below) stays INSIDE the try/rescue so it covers success,
    # {:error, _}, and rescued-exception paths alike.
    LLMCallLog.activate()

    # Structured metadata so every log line the step emits is correlatable
    # (extraction plan §3.7). Set BEFORE the step runs — set after, the step's
    # own log lines would carry no run/step id. Snapshot the prior metadata and
    # restore it in the `after` below: on the sequential/driver process these
    # keys would otherwise linger past the step, tagging unrelated later log
    # lines with a stale step id.
    prior_metadata = Logger.metadata()

    Logger.metadata(
      run_id: pipeline_run.id,
      step_id: step_log.id,
      step_type: step_log.step_type,
      pipeline_name: pipeline_run.name
    )

    meta = %{step_type: step_log.step_type, run_id: pipeline_run.id, step_id: step_log.id}
    started_mono = System.monotonic_time()
    queue_time = queue_time_from(opts, started_mono)

    Telemetry.step_start(meta)

    # Execute the step with exception handling
    try do
      result =
        case step_module.execute(context, input_struct) do
          {:ok, output_struct} ->
            handle_success(step_module, step_log, output_struct, opts)

          {:error, reason} ->
            handle_failure(step_log, reason, opts)
        end

      # AFTER the step-log row is persisted, so the queue_time_ms handler finds
      # the row. `elem(result, 0)` is `:ok` | `:error`.
      Telemetry.step_stop(
        %{duration: System.monotonic_time() - started_mono, queue_time: queue_time},
        Map.put(meta, :status, elem(result, 0))
      )

      result
    rescue
      e ->
        # Log the exception and update step log
        Logger.error(
          "Step #{step_module} raised exception: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        result = handle_failure(step_log, e, opts)

        Telemetry.step_exception(
          %{duration: System.monotonic_time() - started_mono, queue_time: queue_time},
          Map.merge(meta, %{kind: :error, reason: e})
        )

        result
    after
      # Restore the process's pre-step Logger metadata so the step-scoped keys
      # do not linger on the driver process after the step (success or raise).
      Logger.reset_metadata(prior_metadata)
    end
  end

  # `queue_time` is the backlog wait an item spent behind earlier fan-out items
  # / for a concurrency slot before its step began — measured from the fan-out
  # stage's dispatch timestamp (`:queue_since`, native monotonic), threaded here
  # by `ALLM.Pipeline.Dsl.Runtime`. It is NOT `started_at - inserted_at`, which
  # `StepLog.log_start/4` makes ~0 for every step. `nil` for a plain
  # (non-`fan_out`) stage, which has no queue.
  @spec queue_time_from(keyword(), integer()) :: integer() | nil
  defp queue_time_from(opts, started_mono) do
    case Keyword.get(opts, :queue_since) do
      since when is_integer(since) -> started_mono - since
      _ -> nil
    end
  end

  defp handle_success(step_module, step_log, output_struct, opts) do
    # Drain + persist the LLM-call artifact first (covers all exit paths since
    # both handlers drain). drain/0 deletes its key, so the fall-through to
    # handle_failure below re-drains harmlessly (returns []).
    llm_info = drain_and_store_llm(step_log.id, step_module)

    # Validate output against schema. Everything downstream uses the CAST
    # struct, not the step's raw return: `artifact_content/1` would `BadMapError`
    # on a bare map, `log_success/3` reads the flags off `__struct__`, and every
    # caller that pattern-matches `{:ok, _, %Mod{}}` depends on it.
    case validate_output(step_module, output_struct) do
      {:ok, cast_output} ->
        # Store artifact if step produces one
        artifact_info = maybe_store_artifact(step_log.id, step_module, cast_output)

        # Update step log with success (LLM columns folded into artifact_info)
        {:ok, updated_log} =
          store().log_step_success(step_log, cast_output, Map.merge(artifact_info, llm_info))

        {:ok, updated_log, cast_output}

      {:error, reason} ->
        Logger.error("Output validation failed for #{step_module}: #{inspect(reason)}")
        handle_failure(step_log, {:output_validation_failed, reason}, opts)
    end
  end

  # Called FROM the rescue body above as well as from the happy path, so it is
  # itself unrescued — a bang-match here escaped `run_step` entirely and took the
  # fan-out down with it. `reason` is the step's ORIGINAL failure; a failure to
  # persist it must not overwrite or mask it, so the error arm returns the same
  # reason with the un-updated step log.
  #
  # That arm is not seeded by a test: `log_failure/3` builds its changeset from an
  # already-persisted `step_log` plus `normalize_error/1` (which always returns a
  # map), so no public entry point can drive `Repo.update` to `{:error, changeset}`
  # here — the realistic failures (pool exhaustion, a stale row) RAISE instead.
  # `opts` is the CALLER's option list, and exactly one key is read out of it
  # here: `:is_retry`, which `StepLog.log_failure/3` turns into `retry_count`.
  # `ALLM.Pipeline.Dsl.Runtime` sets it from the second attempt of a `retry:`
  # declaration (Phase 4 D11), which is the only persisted trace a re-invoking
  # retry leaves — each attempt writes its own step log, so without it a second
  # failed attempt is indistinguishable from a first.
  @spec handle_failure(StepLog.t(), term(), keyword()) :: {:error, StepLog.t(), term()}
  defp handle_failure(step_log, reason, opts) do
    # Drain + persist the LLM-call artifact (a failed step's calls are the most
    # valuable to review). Idempotent on the success-validation-failure
    # fall-through: drain/0 already deleted its key, so this returns %{}.
    llm_info = drain_and_store_llm(step_log.id, nil)

    case store().log_step_failure(step_log, reason,
           llm_info: llm_info,
           is_retry: opts[:is_retry]
         ) do
      {:ok, updated_log} ->
        {:error, updated_log, reason}

      {:error, changeset} ->
        Logger.error("Failed to log step failure for step #{step_log.id}: #{inspect(changeset)}")

        {:error, step_log, reason}
    end
  end

  # Drain the per-step LLM-call collector and, if it captured anything, store
  # the envelope as a dedicated artifact keyed "<step_id>:llm". Returns the LLM
  # columns (atom-keyed) to fold into the StepLog logger; `%{}` when nothing was
  # captured. Wrapped so it can NEVER raise — LLM logging is observability and
  # must not fail the step (a build_envelope JSON-encode is a real raise
  # candidate). This Executor-level rescue is what isolates the whole record/drain/
  # store path end-to-end.
  @spec drain_and_store_llm(Ecto.UUID.t(), module() | nil) :: map()
  defp drain_and_store_llm(step_id, step_module) do
    case LLMCallLog.drain() do
      [] ->
        %{}

      calls ->
        envelope = build_envelope(step_id, step_module, calls)

        case ArtifactStore.store("#{step_id}:llm", envelope, "application/json") do
          {:ok, url, size, checksum} ->
            %{
              llm_artifact_url: url,
              llm_artifact_size_bytes: size,
              llm_artifact_checksum: checksum,
              llm_call_count: length(calls),
              llm_total_tokens: total_tokens(calls)
            }

          {:error, reason} ->
            Logger.warning("Failed to store LLM artifact for step #{step_id}: #{inspect(reason)}")
            # Still record the cheap counts even if the body didn't persist.
            %{llm_call_count: length(calls), llm_total_tokens: total_tokens(calls)}
        end
    end
  rescue
    e ->
      Logger.warning("LLM-call logging failed for step #{step_id}: #{Exception.message(e)}")
      %{}
  end

  # Build the JSON envelope (a binary) of all LLM calls a step made. Entries
  # arrive ALREADY image-redacted and NUL-scrubbed from
  # `LLMEngine.build_call_entry/6` (the in-memory collector never holds
  # un-redacted bytes), so build_envelope applies NO redaction/scrubbing — the
  # only transform here is the size-guard truncation.
  #
  # `total_tokens` (and the `llm_total_tokens` column) counts EVERY call the step
  # made, including ones the step discarded/retried internally — so it may exceed
  # an Output's `tokens_used`, which counts only the calls folded into the result.
  @spec build_envelope(Ecto.UUID.t(), module() | nil, [LLMCallLog.entry()]) :: binary()
  defp build_envelope(step_id, step_module, calls) do
    indexed_calls =
      calls
      |> Enum.with_index()
      |> Enum.map(fn {call, seq} -> Map.put(call, :seq, seq) end)

    envelope = %{
      step_log_id: step_id,
      step_type: step_type_string(step_module),
      call_count: length(calls),
      total_tokens: total_tokens(calls),
      calls: indexed_calls
    }

    json = Jason.encode!(envelope)

    # A SINGLE sanity pass. Oversize artifacts now have a real large-tier home
    # (`Artifacts.Tiered` → S3), so the envelope no longer has to fit a DynamoDB
    # item and the old second, body-dropping round (which existed only to
    # guarantee a fit and left a `_bodies_dropped` marker) is gone — a large
    # envelope is stored whole. This bound is a pathological-size guard only: a
    # runaway single prompt is head+tail windowed once so the envelope cannot
    # grow unbounded, and whatever that produces is stored as-is.
    if byte_size(json) > envelope_sanity_limit() do
      truncated = %{envelope | calls: Enum.map(indexed_calls, &truncate_call/1)}
      Jason.encode!(truncated)
    else
      json
    end
  end

  @spec step_type_string(module() | nil) :: String.t() | nil
  defp step_type_string(nil), do: nil
  defp step_type_string(step_module), do: to_string(step_module.step_type())

  # Head+tail window used when truncating a pathologically-large prompt/response
  # so one runaway call cannot bloat the envelope unbounded. Oversize envelopes
  # otherwise route whole to the large tier (`Artifacts.Tiered`). The truncation
  # itself lives on `Text.truncate/2`.
  @truncation_window Text.default_window()

  @spec truncate_call(map()) :: map()
  defp truncate_call(call) do
    call
    |> Map.update(:messages, [], fn messages -> Enum.map(messages, &truncate_message/1) end)
    |> Map.update(:response_text, nil, &truncate_text/1)
    |> Map.put(:_truncated, true)
  end

  @spec truncate_message(map()) :: map()
  defp truncate_message(%{content: content} = message) when is_binary(content) do
    %{message | content: truncate_text(content)}
  end

  defp truncate_message(message), do: message

  @spec truncate_text(String.t() | nil) :: String.t() | nil
  defp truncate_text(text), do: Text.truncate(text, @truncation_window)

  # Sum the per-call total_tokens (entries carry a `:usage` map from the
  # recorder, nil on error/empty); calls with no usage contribute 0.
  @spec total_tokens([LLMCallLog.entry()]) :: non_neg_integer()
  defp total_tokens(calls) do
    Enum.reduce(calls, 0, fn call, acc ->
      case call[:usage] do
        %{total_tokens: t} when is_integer(t) -> acc + t
        _ -> acc
      end
    end)
  end

  # A single pathological-size sanity bound for the LLM-call envelope, NOT a
  # DynamoDB-fit requirement (oversize envelopes route to the large tier). Set
  # generously above a normal large envelope and well below `ArtifactStore`'s
  # 64 MB gunzip ceiling, so a truncated envelope always inflates on fetch.
  @spec envelope_sanity_limit() :: pos_integer()
  defp envelope_sanity_limit, do: 4 * 1024 * 1024

  # Runs BEFORE `execute_step`'s try/rescue, so anything that raises here escapes
  # `run_step/5` into a `Task.async_stream` fan-out — which LINKS its children, so
  # a raise kills the calling process rather than failing one item. Every path
  # below therefore returns a tuple: the schema module not being a DSL schema, or
  # not being loadable at all (see `validate_against/3` / `dsl_schema?/1`);
  # `cast/1` on a non-castable term (`ALLM.Pipeline.Schema.__cast__/2`'s final
  # clause, pinned by `schema_test.exs`); and `cast/1` returning a shape neither
  # arm matches (`validate_against/3`'s catch-all).
  #
  # Returns the CAST struct, which is what `run_step/5` proceeds with. A caller
  # that hands `run_step/5` a bare map matching the schema therefore now succeeds
  # where it used to be rejected — a consequence of routing validation through one
  # contract, not a documented API promise (`run_step/5`'s `@spec` still says
  # `struct()`).
  @spec validate_input(module(), term()) :: {:ok, struct()} | {:error, String.t()}
  defp validate_input(step_module, input) do
    validate_against(step_module.input_schema(), input, "Input")
  end

  # Same shape as `validate_input/2`. This one runs INSIDE the try, so a raise here
  # was already rescued and could not reach the fan-out — it is guarded anyway
  # because the two are a symmetric pair, and because a Step that returns
  # `{:ok, <non-struct>}` produced a `%BadMapError{}` in `step_logs.error` instead
  # of naming the contract it broke.
  @spec validate_output(module(), term()) :: {:ok, struct()} | {:error, String.t()}
  defp validate_output(step_module, output) do
    validate_against(step_module.output_schema(), output, "Output")
  end

  # Two validation strategies, chosen by whether the schema is an
  # `ALLM.Pipeline.Schema` DSL module.
  #
  # The DSL's `cast/1` is the real contract: it reports unknown keys,
  # missing-or-nil required fields, duplicate keys and a wrong struct module, and
  # it accepts a map or keyword list as well as the struct itself.
  #
  # The fallback is NOT dead code. `input_schema/0` / `output_schema/0` are plain
  # callbacks returning any module, and a small set of Step schemas are
  # hand-rolled `defstruct`s with no DSL today. Calling `cast/1` on those would
  # raise `UndefinedFunctionError` right where a raise is most expensive, so they
  # keep the module comparison. That set's MEMBERSHIP is machine-guarded from the
  # host tree, where the Step modules can be named:
  # `apps/amesbury_scraper/test/amesbury_scraper/pipeline/step_schema_census_test.exs`
  # (`AmesburyScraper.Pipeline.StepSchemaCensusTest`) enumerates every Step's
  # `input_schema/0` / `output_schema/0` and pins the non-DSL set exactly, so a
  # new one cannot appear here silently. Re-derive by running that test, not by
  # hand — the set's members are listed there and nowhere else.
  #
  # `@spec`'s first parameter is `term()`, not `module()`: `input_schema/0` is an
  # unenforced behaviour callback that can return anything, which is why
  # `dsl_schema?/1` guards on `is_atom/1` rather than assuming.
  @spec validate_against(term(), term(), String.t()) :: {:ok, struct()} | {:error, String.t()}
  defp validate_against(expected_schema, term, label) do
    if dsl_schema?(expected_schema) do
      case expected_schema.cast(term) do
        {:ok, struct} ->
          {:ok, struct}

        {:error, issues} ->
          {:error,
           "#{label} must be #{expected_schema}, got #{render_shape(term)}: #{inspect(issues)}"}

        other ->
          # Belt and braces on an un-rescued path: `dsl_schema?/1` already keys on
          # `__allm_schema__/1`, so only an `ALLM.Pipeline.Schema` module reaches
          # here and its `cast/1` returns one of the two arms above. Without this
          # clause a third shape would raise `CaseClauseError` BEFORE
          # `execute_step`'s try/rescue, inside a linking `Task.async_stream` —
          # i.e. it would kill the caller instead of failing one item.
          {:error,
           "#{label} must be #{expected_schema}, got #{render_shape(term)}: " <>
             "#{expected_schema}.cast/1 returned an unrecognised result " <>
             "(#{render_shape(other)})"}
      end
    else
      validate_by_module(expected_schema, term, label)
    end
  end

  # Keys on `__allm_schema__/1`, NOT on the generic name `cast/1`.
  #
  # `ALLM.Pipeline.Schema`'s moduledoc spends a section arguing that a generically
  # named function is the wrong discriminator for "is this a DSL schema" — it is
  # the whole reason the introspection function is not called `__schema__/1`. That
  # argument applies to `:cast` at least as strongly: `Ecto.Type` exports `cast/1`
  # with a different contract (`{:ok, term} | :error | {:error, keyword}`), and a
  # bare `:error` from one would have missed the two-arm `case` above. Same
  # predicate as `ALLM.Pipeline.StepLog.drop_and_redact/1`'s, which asks the same
  # question of the same modules.
  #
  # "Module absent" is distinguished from "module present, not a DSL schema": the
  # former is a wiring bug that would otherwise silently pick the weaker path, and
  # `validate_by_module/3` will then reject EVERY term (a struct of an unloaded
  # module cannot be constructed), so the log line is what explains the rejection.
  @spec dsl_schema?(term()) :: boolean()
  defp dsl_schema?(schema) when is_atom(schema) do
    case Code.ensure_loaded(schema) do
      {:module, ^schema} ->
        function_exported?(schema, :__allm_schema__, 1)

      {:error, reason} ->
        Logger.warning(
          "Step schema module #{inspect(schema)} could not be loaded (#{inspect(reason)}); " <>
            "falling back to struct-module validation, which will reject every input"
        )

        false
    end
  end

  defp dsl_schema?(_schema), do: false

  @spec validate_by_module(module(), term(), String.t()) :: {:ok, struct()} | {:error, String.t()}
  defp validate_by_module(expected_schema, %mod{} = term, label) do
    if mod == expected_schema do
      {:ok, term}
    else
      {:error, "#{label} must be #{expected_schema}, got #{mod}"}
    end
  end

  defp validate_by_module(expected_schema, other, label) do
    {:error, "#{label} must be #{expected_schema}, got #{render_shape(other)}"}
  end

  # Renders the rejected term's SHAPE — its type, and for a map or keyword list
  # its key NAMES — and never its values.
  #
  # `run_step/5` logs this reason and returns it, host pipelines fail their run
  # with it (`pipeline_runs.metadata.error`), and `validate_output/2`'s half
  # reaches `step_logs.error` through `handle_failure/3`. None of those paths
  # touches `StepLog`'s serializer, so `redact: true` — which applies only at
  # serialization (`ALLM.Pipeline.Schema`, D3) — cannot reach them. A bare
  # `inspect(term)` here (what this built until subphase 2.3) therefore persisted
  # a rejected map's entire contents, and since `cast/1` made a bare map a
  # SUPPORTED input shape, rejected maps carrying real field values became a
  # realistic input rather than a malformed one.
  @spec render_shape(term()) :: String.t()
  defp render_shape(%mod{}), do: "#{mod}"
  defp render_shape(term) when is_map(term), do: "a map with keys #{inspect(Map.keys(term))}"

  defp render_shape(term) when is_list(term) do
    if Keyword.keyword?(term) do
      "a keyword list with keys #{inspect(Keyword.keys(term))}"
    else
      "a #{length(term)}-element list"
    end
  end

  defp render_shape(nil), do: "nil"
  defp render_shape(term) when is_boolean(term), do: "a boolean"
  defp render_shape(term) when is_atom(term), do: "an atom"
  defp render_shape(term) when is_binary(term), do: "a #{byte_size(term)}-byte binary"
  defp render_shape(term) when is_integer(term), do: "an integer"
  defp render_shape(term) when is_float(term), do: "a float"
  defp render_shape(term) when is_tuple(term), do: "a #{tuple_size(term)}-element tuple"
  defp render_shape(term) when is_function(term), do: "a function"
  defp render_shape(term) when is_pid(term), do: "a pid"
  defp render_shape(term) when is_reference(term), do: "a reference"
  defp render_shape(term) when is_port(term), do: "a port"

  # The only BEAM term left is a non-byte-aligned bitstring (`is_binary/1` above
  # takes the byte-aligned ones), so the catch-all stays genuinely reachable
  # rather than becoming provably-dead code. It must stay: a
  # `FunctionClauseError` here would raise on the un-rescued input path.
  defp render_shape(_term), do: "an unrenderable term"

  defp maybe_store_artifact(step_id, step_module, output_struct) do
    if Step.produces_artifact?(step_module) do
      content = step_module.artifact_content(output_struct)
      content_type = step_module.artifact_content_type()

      if content && byte_size(content) > 0 do
        case ArtifactStore.store(step_id, content, content_type) do
          {:ok, url, size, checksum} ->
            %{url: url, size_bytes: size, checksum: checksum}

          {:error, reason} ->
            Logger.warning("Failed to store artifact for step #{step_id}: #{inspect(reason)}")
            %{}
        end
      else
        %{}
      end
    else
      %{}
    end
  end

  defp count_successes(results) do
    Enum.count(results, &match?({:ok, _, _}, &1))
  end

  # The host-wired run/step persistence adapter, resolved at RUNTIME like every
  # config read in this package (`ALLM.Pipeline.Registry` fixes WHICH module at
  # the host's compile time; `impl/0` reads it here).
  @spec store() :: module()
  defp store, do: Store.impl()
end
