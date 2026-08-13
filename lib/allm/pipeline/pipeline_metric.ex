defmodule ALLM.Pipeline.PipelineMetric do
  @moduledoc """
  One normalized metrics row for a pipeline run: the found → mapped → processed
  funnel (plus skipped/failed) for a single entity type. See the "Metric semantics"
  section of steering/PIPELINE_METRICS_DASHBOARD.md.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ALLM.Pipeline.PipelineRun

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          pipeline_run_id: Ecto.UUID.t() | nil,
          pipeline_name: String.t() | nil,
          entity_type: String.t() | nil,
          found: non_neg_integer(),
          mapped: non_neg_integer(),
          processed: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          tokens: non_neg_integer(),
          pipeline_run: PipelineRun.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pipeline_metrics" do
    field(:pipeline_name, :string)
    field(:entity_type, :string)
    field(:found, :integer, default: 0)
    field(:mapped, :integer, default: 0)
    field(:processed, :integer, default: 0)
    field(:skipped, :integer, default: 0)
    field(:failed, :integer, default: 0)
    field(:tokens, :integer, default: 0)

    belongs_to(:pipeline_run, PipelineRun)

    timestamps(type: :utc_datetime_usec)
  end

  # Every non-negative integer count the changeset casts + validates. The first five are
  # the funnel; `:tokens` is the run's total LLM spend (independent of the funnel ordering).
  @counts [:found, :mapped, :processed, :skipped, :failed, :tokens]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(metric, attrs) do
    changeset =
      metric
      |> cast(attrs, [:pipeline_run_id, :pipeline_name, :entity_type | @counts])
      |> validate_required([:pipeline_run_id, :pipeline_name, :entity_type])
      |> foreign_key_constraint(:pipeline_run_id)

    # Reduce OVER @counts with the changeset as the accumulator. This CANNOT be a
    # pipe off `changeset` — `Enum.reduce/3` is `reduce(enumerable, acc, fun)`, so
    # `changeset |> Enum.reduce(@counts, ...)` would pass the changeset as the
    # enumerable (a struct with no Enumerable impl) and crash. Keep it un-piped.
    Enum.reduce(@counts, changeset, fn field, cs ->
      validate_number(cs, field, greater_than_or_equal_to: 0)
    end)
  end
end
