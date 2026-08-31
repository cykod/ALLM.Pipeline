defmodule ALLM.Pipeline.TestRepo.Migrations.CreatePipelineTables do
  @moduledoc """
  Test-harness DDL for the three framework tables, transcribed from the host's
  frozen migrations (Amesbury umbrella, `apps/amesbury/priv/repo/migrations/`):

    * `20260126000001_create_pipeline_tables.exs` — `pipeline_runs` +
      `step_logs` (including `queue_time_ms` / `retry_count`)
    * `20260626120000_add_llm_artifact_to_step_logs.exs` — the five `llm_*`
      columns
    * `20260626130000_add_trigger_and_parent_to_pipeline_runs.exs` — `trigger`
      + `parent_run_id`
    * `20260716000000_create_pipeline_metrics.exs` — `pipeline_metrics`

  (The fifth migration touching these names, `20260130203243_create_committees`,
  only points a host-side FK INTO `step_logs` and is deliberately NOT
  transcribed — the package DB has no `committees`.)

  The package ships NO production migrations — table names are contract and the
  host's migrations never move. This file is therefore also the canonical DDL
  reference a NEW consumer copies into its own `priv/repo/migrations/` when
  onboarding (adoption mechanics are in `guides/host_wiring.md`, not here). This
  file is a hand-mirrored copy per the
  membership-guard rule; its drift guard is the executed column/index/constraint
  parity check against the host's test DB (Phase 8.1 success criterion 6), and
  the source migrations are frozen, so drift is one-directional (edits here
  only). Column ORDER differs from the host (the host added columns by ALTER);
  the parity comparison sorts by column name, and nothing reads ordinal
  position.

  After ANY edit to this file, re-run the schema-parity queries (Phase 8.1
  criterion 6) — the standing re-run site is the host twin,
  `AmesburyScraper.Pipeline.FrameworkBoundaryGuardsTest`
  (`apps/amesbury_scraper/test/amesbury_scraper/pipeline/framework_boundary_guards_test.exs`
  in the Amesbury umbrella).
  """

  use Ecto.Migration

  def change do
    create table(:pipeline_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :metadata, :map, default: %{}
      add :trigger, :string

      add :parent_run_id,
          references(:pipeline_runs, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:pipeline_runs, [:status])
    create index(:pipeline_runs, [:name])
    create index(:pipeline_runs, [:inserted_at])
    create index(:pipeline_runs, [:trigger])
    create index(:pipeline_runs, [:parent_run_id])

    create table(:step_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Direct pipeline reference for efficient querying
      add :pipeline_run_id,
          references(:pipeline_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      # Lineage tracking - reference to the step that produced this step's input
      add :input_step_id, references(:step_logs, type: :binary_id, on_delete: :nilify_all)

      # Step identification
      add :step_type, :string, null: false
      add :status, :string, null: false, default: "pending"

      # Timing data
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :queue_time_ms, :integer

      # Typed I/O tracking - stores the module name and serialized data
      add :input_schema, :string
      add :input_data, :map
      add :output_schema, :string
      add :output_data, :map

      # Artifact reference - URL to DynamoDB or S3 stored artifact
      add :artifact_url, :string
      add :artifact_size_bytes, :integer
      add :artifact_checksum, :string

      # LLM-call artifact capture
      add :llm_artifact_url, :string
      add :llm_artifact_size_bytes, :integer
      add :llm_artifact_checksum, :string
      add :llm_call_count, :integer
      add :llm_total_tokens, :integer

      # Error tracking
      add :error, :map
      add :retry_count, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:step_logs, [:pipeline_run_id])
    create index(:step_logs, [:input_step_id])
    create index(:step_logs, [:step_type])
    create index(:step_logs, [:status])
    create index(:step_logs, [:pipeline_run_id, :started_at])
    create index(:step_logs, [:step_type, :duration_ms])

    create table(:pipeline_metrics, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :pipeline_run_id, references(:pipeline_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      # Denormalized run name so history queries can scope by pipeline join-free.
      add :pipeline_name, :string, null: false
      add :entity_type, :string, null: false
      add :found, :integer, null: false, default: 0
      add :mapped, :integer, null: false, default: 0
      add :processed, :integer, null: false, default: 0
      add :skipped, :integer, null: false, default: 0
      add :failed, :integer, null: false, default: 0
      # `:bigint` because a large run can exceed int4's ceiling; counts stay int4.
      add :tokens, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:pipeline_metrics, [:pipeline_run_id])
    create index(:pipeline_metrics, [:pipeline_name, :inserted_at])
  end
end
