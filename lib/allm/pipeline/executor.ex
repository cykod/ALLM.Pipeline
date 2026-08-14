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
        store().start_run(pipeline_run)

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
    # Validate input against schema
    case validate_input(step_module, input_struct) do
      :ok ->
        execute_step(pipeline_run, step_module, input_struct, input_step_id, opts)

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

    # Execute the step with exception handling
    try do
      case step_module.execute(context, input_struct) do
        {:ok, output_struct} ->
          handle_success(step_module, step_log, output_struct)

        {:error, reason} ->
          handle_failure(step_log, reason)
      end
    rescue
      e ->
        # Log the exception and update step log
        Logger.error(
          "Step #{step_module} raised exception: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        handle_failure(step_log, e)
    end
  end

  defp handle_success(step_module, step_log, output_struct) do
    # Drain + persist the LLM-call artifact first (covers all exit paths since
    # both handlers drain). drain/0 deletes its key, so the fall-through to
    # handle_failure below re-drains harmlessly (returns []).
    llm_info = drain_and_store_llm(step_log.id, step_module)

    # Validate output against schema
    case validate_output(step_module, output_struct) do
      :ok ->
        # Store artifact if step produces one
        artifact_info = maybe_store_artifact(step_log.id, step_module, output_struct)

        # Update step log with success (LLM columns folded into artifact_info)
        {:ok, updated_log} =
          store().log_step_success(step_log, output_struct, Map.merge(artifact_info, llm_info))

        {:ok, updated_log, output_struct}

      {:error, reason} ->
        Logger.error("Output validation failed for #{step_module}: #{inspect(reason)}")
        handle_failure(step_log, {:output_validation_failed, reason})
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
  @spec handle_failure(StepLog.t(), term()) :: {:error, StepLog.t(), term()}
  defp handle_failure(step_log, reason) do
    # Drain + persist the LLM-call artifact (a failed step's calls are the most
    # valuable to review). Idempotent on the success-validation-failure
    # fall-through: drain/0 already deleted its key, so this returns %{}.
    llm_info = drain_and_store_llm(step_log.id, nil)

    case store().log_step_failure(step_log, reason, llm_info: llm_info) do
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

    if byte_size(json) > artifact_size_limit() do
      truncated = %{envelope | calls: Enum.map(indexed_calls, &truncate_call/1)}
      truncated_json = Jason.encode!(truncated)

      # A single huge prompt is reliably brought under budget by the per-call
      # head+tail truncation above. But a high-fan-out step (hundreds of calls)
      # can sum over the limit even after truncation, since the per-call window
      # is bounded but the call count is not. Re-measure: if STILL over, apply a
      # second, harder reduction that deterministically fits by dropping each
      # call's heavy bodies (messages/response_text) to a stub while keeping the
      # per-call metadata. This guarantees we never route to the unimplemented
      # S3 path and silently lose the artifact.
      if byte_size(truncated_json) > artifact_size_limit() do
        dropped =
          envelope
          |> Map.put(:calls, Enum.map(indexed_calls, &drop_call_bodies/1))
          |> Map.put(:_bodies_dropped, true)

        Jason.encode!(dropped)
      else
        truncated_json
      end
    else
      json
    end
  end

  @spec step_type_string(module() | nil) :: String.t() | nil
  defp step_type_string(nil), do: nil
  defp step_type_string(step_module), do: to_string(step_module.step_type())

  # Head+tail window used when truncating an oversized prompt/response so the
  # artifact still fits a DynamoDB item. We never rely on the (unimplemented) S3
  # path for oversize. The truncation itself lives on `Text.truncate/2`.
  @truncation_window Text.default_window()

  @spec truncate_call(map()) :: map()
  defp truncate_call(call) do
    call
    |> Map.update(:messages, [], fn messages -> Enum.map(messages, &truncate_message/1) end)
    |> Map.update(:response_text, nil, &truncate_text/1)
    |> Map.put(:_truncated, true)
  end

  # Harder reduction for the high-fan-out case: drop the heavy bodies
  # (messages/response_text) to short stubs, keeping the per-call metadata (seq,
  # schema_name, model, usage, outcome, duration_ms, …). Guarantees the envelope
  # fits under the dynamo limit regardless of call count.
  @body_dropped_stub "[dropped: envelope over size limit]"

  @spec drop_call_bodies(map()) :: map()
  defp drop_call_bodies(call) do
    call
    |> Map.put(:messages, @body_dropped_stub)
    |> Map.update(:response_text, nil, fn
      nil -> nil
      _ -> @body_dropped_stub
    end)
    |> Map.put(:_bodies_dropped, true)
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

  # A CONSERVATIVE pre-gzip bound on the envelope, not ArtifactStore's gate.
  # ArtifactStore now routes dynamo-vs-S3 on the post-gzip, post-base64 payload,
  # which for JSON is far smaller than this — so an envelope kept under 400KB of
  # raw JSON is guaranteed to fit a DynamoDB item. The truncation below therefore
  # over-truncates slightly; it stays until `Artifacts.S3` exists (design doc §3.6,
  # Phase 7), because until then an oversize artifact is silently discarded.
  @spec artifact_size_limit() :: pos_integer()
  defp artifact_size_limit, do: 400 * 1024

  # Runs BEFORE `execute_step`'s try/rescue, so `input_struct.__struct__` on a
  # non-struct (a bare map, a keyword list, nil — a caller that built its input by
  # hand) raised `BadMapError`/`KeyError` out through `run_step`. Matching `%mod{}`
  # in the head makes the non-struct case a normal `{:error, message}`.
  @spec validate_input(module(), term()) :: :ok | {:error, String.t()}
  defp validate_input(step_module, %mod{}) do
    expected_schema = step_module.input_schema()

    if mod == expected_schema do
      :ok
    else
      {:error, "Input must be #{expected_schema}, got #{mod}"}
    end
  end

  defp validate_input(step_module, other) do
    {:error, "Input must be #{step_module.input_schema()}, got #{inspect(other)}"}
  end

  # Same shape as `validate_input/2`. This one runs INSIDE the try, so a raise here
  # was already rescued and could not reach the fan-out — it is guarded anyway
  # because the two are a symmetric pair, and because a Step that returns
  # `{:ok, <non-struct>}` produced a `%BadMapError{}` in `step_logs.error` instead
  # of naming the contract it broke.
  @spec validate_output(module(), term()) :: :ok | {:error, String.t()}
  defp validate_output(step_module, %mod{}) do
    expected_schema = step_module.output_schema()

    if mod == expected_schema do
      :ok
    else
      {:error, "Output must be #{expected_schema}, got #{mod}"}
    end
  end

  defp validate_output(step_module, other) do
    {:error, "Output must be #{step_module.output_schema()}, got #{inspect(other)}"}
  end

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
