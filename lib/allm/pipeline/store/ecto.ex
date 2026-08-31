defmodule ALLM.Pipeline.Store.Ecto do
  @moduledoc """
  PostgreSQL implementation of `ALLM.Pipeline.Store`, and the adapter that
  ships the package's run/step schemas.

  Every callback is a `defdelegate` onto `ALLM.Pipeline.PipelineRun` or
  `ALLM.Pipeline.StepLog`, which hold the Ecto schemas, the changesets, the
  serialization rules and the ownership guard. This module is a naming layer:
  it gives the two schemas one behaviour-shaped front door so a future adapter
  has a contract to satisfy, without moving a single line of persistence logic
  out of the modules that own it.

  ## Why delegation, and not a re-implementation

  `%PipelineRun{}` carries a virtual `:completion_token` minted inside
  `PipelineRun.create/3`. `defdelegate` returns the callee's value untouched,
  so the owning handle reaches the caller by construction — there is no
  intermediate struct for it to be dropped from, and no third mint point. An
  adapter that rebuilt the run from row data instead would return a
  permanently non-owning handle and break every `complete/2` in the system,
  invisibly to the migration gate. See `ALLM.Pipeline.Store`'s warning.

  ## The repo

  Comes from `ALLM.Pipeline.Config.repo/0`, reached through each schema
  module's own private `repo/0` — this module needs none of its own. `Store`
  does not subsume `ALLM.Pipeline.Config.repo/0`: `Metrics` and `Lock.Advisory` read the same
  handle and sit outside this behaviour entirely.

  ## Tables are contract, not configuration

  `step_logs` and `pipeline_runs` are inlined in `StepLog.build_lineage_tree/1`
  raw SQL, queried by string from `Amesbury.Government` (an app that cannot see
  this package's config), and `committees.last_step_log_id` is a real Postgres
  FK. There is no `table_prefix` option, and the four migrations that own these
  tables stay in the host.
  """

  @behaviour ALLM.Pipeline.Store

  alias ALLM.Pipeline.{PipelineRun, StepLog, Store}

  # ── Runs ───────────────────────────────────────────────────────────────────

  @impl true
  @spec create_run(String.t(), map(), keyword()) ::
          {:ok, PipelineRun.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_run(name, metadata, attrs), to: PipelineRun, as: :create

  @impl true
  @spec start_run(PipelineRun.t()) :: {:ok, PipelineRun.t()} | {:error, Ecto.Changeset.t()}
  defdelegate start_run(run), to: PipelineRun, as: :start

  @impl true
  @spec complete_run(PipelineRun.t(), map()) ::
          {:ok, PipelineRun.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}
  defdelegate complete_run(run, metadata), to: PipelineRun, as: :complete

  @impl true
  @spec fail_run(PipelineRun.t(), term()) ::
          {:ok, PipelineRun.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}
  defdelegate fail_run(run, error), to: PipelineRun, as: :fail

  @impl true
  @spec cancel_run(PipelineRun.t()) ::
          {:ok, PipelineRun.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}
  defdelegate cancel_run(run), to: PipelineRun, as: :cancel

  @impl true
  @spec get_run(Ecto.UUID.t()) :: PipelineRun.t() | nil
  defdelegate get_run(id), to: PipelineRun, as: :get

  # ── Steps ──────────────────────────────────────────────────────────────────

  @impl true
  @spec log_step_start(Ecto.UUID.t(), module(), struct(), Ecto.UUID.t() | nil) ::
          {:ok, StepLog.t()} | {:error, Ecto.Changeset.t()}
  defdelegate log_step_start(run_id, step_module, input, input_step_id),
    to: StepLog,
    as: :log_start

  @impl true
  @spec log_step_success(StepLog.t(), struct(), map()) ::
          {:ok, StepLog.t()} | {:error, Ecto.Changeset.t()}
  defdelegate log_step_success(step, output, artifact_info), to: StepLog, as: :log_success

  @impl true
  @spec log_step_failure(StepLog.t(), term(), keyword()) ::
          {:ok, StepLog.t()} | {:error, Ecto.Changeset.t()}
  defdelegate log_step_failure(step, error, opts), to: StepLog, as: :log_failure

  @impl true
  @spec log_section(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) ::
          {:ok, StepLog.t()} | {:error, Ecto.Changeset.t()}
  defdelegate log_section(run_id, title, input_step_id), to: StepLog

  @impl true
  @spec log_skipped(Ecto.UUID.t(), String.t(), term(), Ecto.UUID.t() | nil) ::
          {:ok, StepLog.t()} | {:error, Ecto.Changeset.t()}
  defdelegate log_skipped(run_id, step_type, reason, input_step_id),
    to: StepLog,
    as: :create_skipped

  @impl true
  @spec log_summary(Ecto.UUID.t(), String.t(), map(), Ecto.UUID.t() | nil) ::
          {:ok, StepLog.t()} | {:error, Ecto.Changeset.t()}
  defdelegate log_summary(run_id, step_type, output_data, input_step_id), to: StepLog

  @impl true
  @spec get_step(Ecto.UUID.t()) :: StepLog.t() | nil
  defdelegate get_step(id), to: StepLog, as: :get

  @impl true
  @spec pipeline_stats(Ecto.UUID.t()) :: Store.stats()
  defdelegate pipeline_stats(run_id), to: StepLog, as: :get_pipeline_stats
end
