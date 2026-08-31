defmodule ALLM.Pipeline.Store do
  @moduledoc """
  Persistence behaviour for **runs and steps** — the observability record a
  pipeline leaves behind.

  Scope is deliberately narrow: `ALLM.Pipeline.PipelineRun` and
  `ALLM.Pipeline.StepLog`, nothing else.

    * `ALLM.Pipeline.PipelineMetric` / `ALLM.Pipeline.Metrics` is a **third**
      schema — the found → mapped → processed funnel, not run-or-step
      persistence — and widening `Store` to cover it would make every adapter
      implement a reporting table it may not want. It stays on its own module.
    * `ALLM.Pipeline.Lock.Advisory` also talks to a database, but it sits
      behind `ALLM.Pipeline.Lock`, whose entire contract is `with_lock/2`. A
      repo handle is not in that contract, and it is not in this one either.

  Both of those, and `Store.Ecto` itself, get their repo from
  `ALLM.Pipeline.Config.repo/0` — the package's single host-repo handle. See
  that module: `Store` does **not** subsume it.

  ## The structs are the contract; the backend is the adapter

  `%PipelineRun{}` and `%StepLog{}` are the framework's data types, and every
  adapter returns them. They happen to be Ecto schemas because `Store.Ecto` is
  the only adapter that exists; a different backend would populate the same
  structs.

  ⚠️ **`%PipelineRun{}` carries a virtual `:completion_token`, and this is
  exactly where it can be lost.** An adapter that RECONSTRUCTS a run from
  backend data instead of passing the created struct through silently returns a
  non-owning handle, and then every `complete/2` in the system answers
  `{:error, :not_run_owner}`. The token is never cast, never persisted, and
  absent from every migration, so no migration or round-trip test can see this
  — only `pipeline_run_test.exs`'s "create/3 mints a completion token that
  survives start/1" and "every terminal writer refuses a non-owning handle"
  can. There is one mint implementation (`PipelineRun`'s private
  `mint_token/1`) behind exactly two entry points, `PipelineRun.create/3` and
  `PipelineRun.assume_ownership/1`; an adapter must not add a third.

  ## Not callbacks

  `PipelineRun.borrow/1`, `owner?/1` and `assume_ownership/1` are pure struct
  operations with no backend involvement, so they stay on the schema module
  rather than becoming adapter surface — which also keeps the mint and the
  strip in one place each. `StepLog.log_skipped/2` (the UPDATE-an-existing-row
  skip path), `PipelineRun.list/1`,
  `count/1`, `get_with_steps/1` and the lineage/query functions are absent for
  a different reason: nothing in the framework calls them today (their callers
  are the host's review UI), and the extraction plan §3.2 routes host reads
  through a separate `ALLM.Pipeline.Query`. Add a callback when a framework
  caller appears, not before — which is exactly what happened for the CREATE
  skip path: Phase 7.4 wired the three `ProcessingDecision` skip branches to
  write a visible `:skipped` row, so `StepLog.create_skipped/4` earned the
  `log_skipped/4` callback below.

  ## Configuration

      config :allm_pipeline, ALLM.Pipeline.Store,
        impl: ALLM.Pipeline.Store.Ecto

  `impl/0` resolves at RUNTIME and defaults to `ALLM.Pipeline.Store.Ecto`, so
  the key is optional. A host that declares an `ALLM.Pipeline.Registry` supplies
  this key's default from its `store:` declaration instead; a config-file
  `impl:` still wins, per environment (see that module's "Precedence"). `Store.Memory` is **not planned, in this or any phase**:
  the lineage tree is a recursive CTE with no ETS equivalent, and every
  realistic consumer of an observability framework has a database.
  """

  alias ALLM.Pipeline.{PipelineRun, StepLog}

  @typedoc "A pipeline run — one execution, grouping its step logs."
  @type run :: PipelineRun.t()

  @typedoc "One step's execution record under a run."
  @type step :: StepLog.t()

  @typedoc """
  Aggregate counts and timings over a run's non-`section` steps.

  Spelled out rather than left as `map()` so a second adapter's
  `pipeline_stats/1` is checkable against the contract — which is what `Store`
  is for. The two `nil`s are real: SQL `sum`/`avg` over a run whose steps all
  carry a `NULL` `duration_ms` return `NULL`, and `avg` returns a `Decimal`.
  """
  @type stats :: %{
          total_steps: non_neg_integer(),
          successful: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          total_duration_ms: non_neg_integer() | nil,
          avg_duration_ms: Decimal.t() | nil
        }

  # ── Runs ───────────────────────────────────────────────────────────────────

  @doc """
  Insert a run at `:pending` and return the **owning** handle.

  `attrs` carries first-class column values (`:trigger`, `:parent_run_id`), not
  metadata. The returned struct must be the one the mint stamped — see the
  moduledoc's warning.
  """
  @callback create_run(name :: String.t(), metadata :: map(), attrs :: keyword()) ::
              {:ok, run()} | {:error, Ecto.Changeset.t()}

  @doc "Move a run to `:running` and stamp `started_at`. Must carry the completion token through."
  @callback start_run(run()) :: {:ok, run()} | {:error, Ecto.Changeset.t()}

  @doc "Terminal write: `:success` + `completed_at`, merging `metadata`. Refuses a non-owning handle."
  @callback complete_run(run(), metadata :: map()) ::
              {:ok, run()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}

  @doc "Terminal write: `:failed` + `completed_at`, recording `error`. Refuses a non-owning handle."
  @callback fail_run(run(), error :: term()) ::
              {:ok, run()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}

  @doc """
  Terminal write: `:cancelled` + `completed_at`. Refuses a non-owning handle.

  Present with no framework caller, unlike everything else here, because
  complete/fail/cancel are a documented SET — all three write `completed_at`
  plus a terminal status, so splitting them across two modules is the
  "one rule enforced in more than one shape" trap root `CLAUDE.md` names.
  """
  @callback cancel_run(run()) ::
              {:ok, run()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}

  @doc "Load a run by id. The result is **never** an owner — a re-loaded handle carries no token."
  @callback get_run(id :: Ecto.UUID.t()) :: run() | nil

  # ── Steps ──────────────────────────────────────────────────────────────────

  @doc "Insert a `:running` step under `run_id`, capturing its input and lineage parent."
  @callback log_step_start(
              run_id :: Ecto.UUID.t(),
              step_module :: module(),
              input :: struct(),
              input_step_id :: Ecto.UUID.t() | nil
            ) :: {:ok, step()} | {:error, Ecto.Changeset.t()}

  @doc "Close a step `:success`, recording its output and any artifact/LLM columns."
  @callback log_step_success(step(), output :: struct(), artifact_info :: map()) ::
              {:ok, step()} | {:error, Ecto.Changeset.t()}

  @doc "Close a step `:failed`, recording the normalized error."
  @callback log_step_failure(step(), error :: term(), opts :: keyword()) ::
              {:ok, step()} | {:error, Ecto.Changeset.t()}

  @doc "Record a zero-duration `section` divider — visual grouping, excluded from stats."
  @callback log_section(
              run_id :: Ecto.UUID.t(),
              title :: String.t(),
              input_step_id :: Ecto.UUID.t() | nil
            ) :: {:ok, step()} | {:error, Ecto.Changeset.t()}

  @doc """
  Record a zero-duration `:skipped` step — the visible record of a gate decision
  that declined to process an item.

  A create-from-scratch path (`StepLog.create_skipped/4`), distinct from the
  update-an-existing-row `StepLog.log_skipped/2`: a `*ProcessingDecision` skip
  fires before any step log exists. `reason` is made jsonb-safe and stored;
  `input_step_id` is the lineage parent the processed step would have carried.
  """
  @callback log_skipped(
              run_id :: Ecto.UUID.t(),
              step_type :: String.t(),
              reason :: term(),
              input_step_id :: Ecto.UUID.t() | nil
            ) :: {:ok, step()} | {:error, Ecto.Changeset.t()}

  @doc "Record a zero-duration step carrying structured `output_data` (a decision audit)."
  @callback log_summary(
              run_id :: Ecto.UUID.t(),
              step_type :: String.t(),
              output_data :: map(),
              input_step_id :: Ecto.UUID.t() | nil
            ) :: {:ok, step()} | {:error, Ecto.Changeset.t()}

  @doc "Load a step by id."
  @callback get_step(id :: Ecto.UUID.t()) :: step() | nil

  @doc "Aggregate a run's non-`section` steps."
  @callback pipeline_stats(run_id :: Ecto.UUID.t()) :: stats()

  @doc """
  The currently-configured store adapter (default `ALLM.Pipeline.Store.Ecto`).

  Resolved at RUNTIME, like every config read in this package;
  `ALLM.Pipeline.Registry` is what fixes WHICH module at the host's compile
  time. `ALLM.Pipeline.Executor` dispatches every run/step write and read
  through it (batch 1.C), except `PipelineRun.borrow/1` and
  `assume_ownership/1` — see "Not callbacks" above.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:allm_pipeline, __MODULE__, [])
    |> Keyword.get(:impl, ALLM.Pipeline.Store.Ecto)
  end
end
