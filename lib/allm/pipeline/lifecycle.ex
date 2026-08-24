defmodule ALLM.Pipeline.Lifecycle do
  @moduledoc """
  The run lifecycle guard, as ONE implementation with two consumers.

  A `PipelineRun` must reach a terminal status on every exit path — success, a
  named failure, a raise, an **exit** and a **throw**. `use ALLM.Pipeline`
  generates that guarantee for a declared pipeline; this module is where the
  guarantee actually lives, so a **hand-written** entry point can have it by
  calling `owned_run/4` instead of growing a third hand-rolled copy of
  `try/rescue/catch` + `complete/2` + `fail_pipeline_run/2`.

  That was not a hypothetical. Before Phase 4 the tree carried four orchestrator
  entry points that terminated their run on *no* path, and two more with no
  `rescue` at all; the DSL closed the declared ones and left the hand-written
  `*_single` helpers — which resolve their own working set and therefore have no
  declaration to express — one copy short.

  ## The two consumers

  | Consumer | Uses |
  |---|---|
  | `ALLM.Pipeline.Dsl.Runtime.execute/4` | `guard/2` and `settle/4` separately, because resource teardown (Phase 4 D3) runs *between* them |
  | A hand-written entry point | `owned_run/4`, which composes create → `guard/2` → `settle/4` |

  Splitting `guard/2` from `settle/4` is what lets D3's ordering — stages →
  outcome computed → **teardown** → terminal write — be expressed as three
  statements in `Runtime` rather than as a flag threaded through one function.

  ## Versus `ALLM.Pipeline.Executor.finish_run/2`

  There are two complete-or-fail tails in this framework and the boundary is
  which one owns *creation* and the *guard*:

  | | `Executor.finish_run/2` | `Lifecycle.owned_run/4` |
  |---|---|---|
  | Creates the run | no — you hand it one you already own | yes |
  | Metadata argument | no | yes, from the body's return |
  | Guards raise / exit / throw | **no** | yes |
  | Teardown-error merging | no | via `settle/4` |
  | Returns | your `result`, unchanged | `{:ok, value}` / `{:error, reason}` |

  So a hand-written entry point that **creates its own run** wants
  `owned_run/4`: `finish_run/2` on its own leaves every raise, exit and throw
  between the create and the tail unterminated, which is the defect that put
  four such entry points in the tree. `finish_run/2` remains right for a caller
  that already holds an owning handle, has no metadata to write, and is already
  inside somebody else's guard.

  ## Ownership

  `owned_run/4` mints its handle through `ALLM.Pipeline.Executor.create_pipeline_run/3`
  and hands the body the **borrowed** projection, exactly as the generated
  `run/1` does. The owning handle never leaves this module, so a body cannot
  complete its own parent run, and this module introduces no third mint point
  (`PipelineRun.create/3` and `PipelineRun.assume_ownership/1` remain the only
  two).
  """

  alias ALLM.Pipeline.{Encodable, Executor, PipelineRun, Telemetry}
  alias ALLM.Pipeline.Dsl.Resource

  require Logger

  @typedoc """
  What `guard/2` produced. `{:raised, …}` carries the kind so `settle/4` can
  re-raise it unchanged — `reraise` alone cannot, because an exit is not an
  exception.
  """
  @type guarded(value) ::
          {:ok, value} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  @typedoc """
  What `settle/4` writes. `{:ok, value, metadata}` completes the run with
  `metadata` and returns `value`; `{:error, reason}` and `{:raised, …}` fail it.
  """
  @type settlement ::
          {:ok, term(), map()}
          | {:error, term()}
          | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  @doc """
  Run `fun`, converting a raise, an exit **or** a throw into `{:raised, …}`.

  `rescue` alone is insufficient and that is the whole point: two orchestrators
  in this tree had only a `rescue`, so an exit or a throw stranded their run at
  `status = :running`. `label` names the unit in the log line.

  The failure is logged here and re-raised by `settle/4`, never swallowed.
  """
  @spec guard(String.t(), (-> value)) :: guarded(value) when value: var
  def guard(label, fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    kind, reason ->
      Logger.error(
        "#{label} aborted with #{kind} #{inspect(reason)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      {:raised, kind, reason, __STACKTRACE__}
  end

  @doc """
  Write the run's terminal status and return the caller's value.

  `owning` must be an owning handle. `teardown_errors` are
  `ALLM.Pipeline.Dsl.Resource.release/2`'s output; when non-empty they are
  merged into the run's metadata under `"resource_teardown_errors"` on **either**
  terminal path, and they never change the status — a leaked handle is an
  operational fault recorded beside the work's outcome, not a failure of it
  (Phase 4 D3).

  Returns `{:ok, value, completed_run}` on success and `{:error, reason}` on a
  named failure. A `{:raised, …}` settlement fails the run and then re-raises
  the original kind/reason/stacktrace, so a caller's own error handling is
  unaffected — this adds the terminal write those paths were missing, and
  nothing else.

  If the terminal write itself does not land — a refused non-owning handle, or a
  failed update — this returns `{:error, {:not_completed, reason}}` rather than
  the work's value. Reporting `{:ok, …}` there would be a fail-open: the row is
  left at `:running` with no `completed_at`, so a success report is false, and
  a false success on the one function whose entire job is the terminal write is
  the shape hardest to notice. Not reachable from either in-tree consumer, both
  of which hold an owning handle by construction.
  """
  @spec settle(String.t(), PipelineRun.t(), settlement(), [Resource.teardown_error()]) ::
          {:ok, term(), PipelineRun.t()} | {:error, term()}
  def settle(label, owning, {:ok, value, metadata}, teardown_errors) when is_map(metadata) do
    # `PipelineRun.complete/2` DIRECTLY, while the two failure clauses below reach
    # their write through `Executor.fail_pipeline_run/2` and therefore through
    # `Store.impl()`. The asymmetry is deliberate and load-bearing: the DSL's
    # whole claim is that a ported pipeline calls what a hand-written one calls,
    # and every hand-written orchestrator in this tree completes its run this way
    # (the design doc's "it calls what a hand-written orchestrator calls"
    # contract). `Store.Ecto.complete_run/2` is a `defdelegate` to this same
    # function, so the default adapter is unaffected either way. Do not "fix" the
    # asymmetry into a `store().complete_run(...)` without deciding that question
    # deliberately — code review 4.1 F8.
    case PipelineRun.complete(owning, merge_teardown(metadata, teardown_errors)) do
      {:ok, run} ->
        # The canonical settle point, so `[:allm_pipeline, :run, :stop]` fires
        # here for every DSL / `owned_run/4` run. `duration` is native units
        # derived from the persisted wall-clock timestamps (there is no
        # monotonic run-start reference on the ownership handle). See
        # `ALLM.Pipeline.Telemetry`'s run-family accounting.
        Telemetry.run_stop(
          %{duration: run_duration(owning.started_at, run.completed_at)},
          %{name: run.name, run_id: run.id, trigger: run.trigger, status: run.status}
        )

        {:ok, value, run}

      {:error, reason} ->
        Logger.error(
          "#{label}: could not complete run #{owning.id}: #{Encodable.render(reason)}. The row " <>
            "is left at :running; reporting the work's value as a success would hide that."
        )

        {:error, {:not_completed, reason}}
    end
  end

  def settle(_label, owning, {:error, reason}, teardown_errors) do
    owning |> record_teardown(teardown_errors) |> Executor.fail_pipeline_run(reason)

    Telemetry.run_stop(
      %{duration: run_duration(owning.started_at, DateTime.utc_now())},
      %{name: owning.name, run_id: owning.id, trigger: owning.trigger, status: :failed}
    )

    {:error, reason}
  end

  def settle(_label, owning, {:raised, kind, reason, stacktrace}, teardown_errors) do
    owning |> record_teardown(teardown_errors) |> Executor.fail_pipeline_run({kind, reason})

    Telemetry.run_exception(
      %{duration: run_duration(owning.started_at, DateTime.utc_now())},
      %{name: owning.name, run_id: owning.id, kind: kind, reason: reason}
    )

    :erlang.raise(kind, reason, stacktrace)
  end

  # Run `duration` in native time units, derived from the persisted wall-clock
  # timestamps — the ownership handle carries no monotonic run-start reference,
  # and the run family is a consumer-less integration surface (see
  # `ALLM.Pipeline.Telemetry`). `started_at` is set by `create_pipeline_run/3`
  # before `settle/4` ever runs, so the `nil` clause is defensive only.
  @spec run_duration(DateTime.t() | nil, DateTime.t()) :: integer()
  defp run_duration(nil, _to), do: 0

  defp run_duration(from, to),
    do: to |> DateTime.diff(from, :microsecond) |> System.convert_time_unit(:microsecond, :native)

  @doc """
  Run `fun` under a fresh, fully-guarded `PipelineRun`.

  The framework affordance for a **hand-written** entry point — one that
  resolves its own working set and therefore has no `use ALLM.Pipeline`
  declaration to express. It gives that entry point the same guarantee the
  generated `run/1` has: the run reaches a terminal status on every exit path,
  including an exit and a throw.

      def run_single(record, opts) do
        Lifecycle.owned_run("meeting_single", %{id: record.id}, [], fn run ->
          case process(run, record, opts) do
            {:ok, stats}     -> {:ok, stats, serialize(stats)}
            {:error, reason} -> {:error, reason}
          end
        end)
      end

  `fun` receives the **borrowed** run and returns `{:ok, value, metadata}`
  (complete the run with `metadata`, return `{:ok, value}`), `{:ok, value}`
  (complete with `%{}`), or `{:error, reason}` (fail the run, return
  `{:error, reason}`). `attrs` reaches `Executor.create_pipeline_run/3` — that
  is where `:parent_run_id` and `:trigger` go.
  """
  @spec owned_run(
          String.t(),
          map(),
          keyword(),
          (PipelineRun.t() -> {:ok, term(), map()} | {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, term()}
  def owned_run(name, metadata, attrs, fun) when is_function(fun, 1) do
    case Executor.create_pipeline_run(name, metadata, attrs) do
      {:ok, owning} ->
        borrowed = PipelineRun.borrow(owning)

        # `normalize_body/1` runs INSIDE the guarded closure, not around it. Its
        # `ArgumentError` for an unsanctioned body shape is a contract violation
        # like any other raise, so it has to become a `{:raised, …}` settlement
        # that fails the run and is then re-raised unchanged. Evaluated outside
        # the guard it escaped `owned_run/4` with the run already created and
        # never terminated — `status = :running`, `completed_at = nil` — which is
        # the exact orphan-run defect this module exists to close.
        settlement = unwrap(guard(name, fn -> normalize_body(fun.(borrowed)) end))

        case settle(name, owning, settlement, []) do
          {:ok, value, _run} -> {:ok, value}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.error("#{name}: could not create pipeline run: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The body's own return shape, mapped to a settlement. Called from inside
  # `guard/2`, so the raise below is caught, fails the run, and is re-raised.
  @spec normalize_body(term()) :: {:ok, term(), map()} | {:error, term()}
  defp normalize_body({:ok, value, metadata}) when is_map(metadata), do: {:ok, value, metadata}
  defp normalize_body({:ok, value}), do: {:ok, value, %{}}
  defp normalize_body({:error, reason}), do: {:error, reason}

  defp normalize_body(other) do
    raise ArgumentError,
          "ALLM.Pipeline.Lifecycle.owned_run/4's body returned #{inspect(other)}. Return " <>
            "`{:ok, value, metadata}`, `{:ok, value}` or `{:error, reason}`."
  end

  # `guard/2` wraps a clean return in `{:ok, …}`; `settle/4` takes the settlement
  # itself. This is the only step left outside the guard, and it cannot raise.
  @spec unwrap(guarded({:ok, term(), map()} | {:error, term()})) :: settlement()
  defp unwrap({:ok, settlement}), do: settlement
  defp unwrap({:raised, _kind, _reason, _stacktrace} = raised), do: raised

  # ONE rule — "teardown failures are merged into the metadata the terminal write
  # persists" — written twice, because the two writers offer different channels
  # and neither one covers both.
  #
  # `complete/2` takes the metadata as an ARGUMENT, so it goes there.
  # `fail_pipeline_run/2` does not, so it rides on the run struct's own metadata
  # (which `PipelineRun.fail/2` merges as its base) — and that channel is not
  # available to `complete/2`, because when the merge result equals the struct's
  # metadata Ecto sees no change and silently drops the field. Measured: a
  # teardown failure under a `complete_metadata:` returning `%{}` wrote nothing
  # to the row, while the identical code path with a non-empty metadata map
  # wrote it. `fail/2` always adds its `"error"` key, so it always changes.
  #
  # Encoding follows the same split. `complete/2` runs `Encodable.encode/1` over
  # its metadata ARGUMENT, so the merge path is covered; `fail/2` encodes its
  # `%{"error" => …}` half only and merges the struct's metadata as an untouched
  # base, so `record_teardown/2` encodes for itself. Do not rely on
  # `Resource.release/2` returning strings instead — jsonb-safety in this tree
  # is `Encodable.encode/1`'s job and nothing else's, and it is idempotent by
  # contract, so the pass costs nothing on an already-string map.
  @spec merge_teardown(map(), [Resource.teardown_error()]) :: map()
  defp merge_teardown(metadata, []), do: metadata

  defp merge_teardown(metadata, errors),
    do: Map.put(metadata, "resource_teardown_errors", errors)

  @spec record_teardown(PipelineRun.t(), [Resource.teardown_error()]) :: PipelineRun.t()
  defp record_teardown(run, []), do: run

  defp record_teardown(run, errors),
    do: %{run | metadata: Encodable.encode(merge_teardown(run.metadata || %{}, errors))}
end
