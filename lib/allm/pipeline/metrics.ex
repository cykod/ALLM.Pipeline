defmodule ALLM.Pipeline.Metrics do
  @moduledoc """
  Record and query normalized pipeline metrics (the found → mapped → processed funnel).
  Emission point: a pipeline calls `record/3` at the SAME place it calls
  `PipelineRun.complete/2` (the sole completer for umbrella/borrowed runs).
  """
  import Ecto.Query
  require Logger

  alias ALLM.Pipeline.{Config, PipelineMetric, PipelineRun}

  @type funnel :: %{
          optional(:found) => non_neg_integer(),
          optional(:mapped) => non_neg_integer(),
          optional(:processed) => non_neg_integer(),
          optional(:skipped) => non_neg_integer(),
          optional(:failed) => non_neg_integer(),
          optional(:tokens) => non_neg_integer()
        }

  @doc """
  Whether `found == 0` should alert for this pipeline (a full-listing scraper).

  The SET is host domain knowledge, not framework knowledge: which pipelines
  re-scrape a complete source listing every run — and which are legitimately
  empty — is a fact about the host's sources. It is declared as
  `alert_on_empty:` on the host's `ALLM.Pipeline.Registry` (batch 1.C moved it
  off a hardcoded `@expects_data_pipelines` here) and resolved at runtime by
  `ALLM.Pipeline.Config.alert_on_empty/0`. The reasons for each inclusion and
  the one deliberate exclusion travel WITH the values, on the declaration.

  Keyed by the run `name` (= `pipeline_metrics.pipeline_name`), a string —
  not a cron atom; the two namespaces do not line up (extraction plan §3.8a).
  Default is OFF for anything undeclared.
  """
  @spec expects_data?(String.t() | nil) :: boolean()
  def expects_data?(pipeline_name), do: pipeline_name in Config.alert_on_empty()

  @doc """
  Record one normalized metrics row for `run` and `entity_type`. `funnel` is a map of any
  subset of `:found/:mapped/:processed/:skipped/:failed/:tokens` (absent keys default to 0).
  Best-effort: a metrics-write failure must never fail the pipeline run — logs and
  returns `{:error, changeset}` rather than raising.
  """
  @spec record(PipelineRun.t(), String.t(), funnel()) ::
          {:ok, PipelineMetric.t()} | {:error, Ecto.Changeset.t() | Exception.t()}
  def record(%PipelineRun{id: run_id, name: name}, entity_type, funnel) do
    attrs =
      funnel
      |> Map.take([:found, :mapped, :processed, :skipped, :failed, :tokens])
      |> Map.merge(%{pipeline_run_id: run_id, pipeline_name: name, entity_type: entity_type})

    %PipelineMetric{}
    |> PipelineMetric.changeset(attrs)
    |> repo().insert()
  rescue
    # Best-effort: a metrics-write failure (transport error, undeclared constraint)
    # must never abort a pipeline run that already did its work. The changeset
    # declares `foreign_key_constraint(:pipeline_run_id)`, so a bad FK returns
    # `{:error, changeset}` above; this rescue is the backstop for everything else.
    e ->
      Logger.warning("Metrics.record failed for #{name}/#{entity_type}: #{Exception.message(e)}")

      {:error, e}
  end

  @doc """
  The most recent metrics row per `pipeline_name` — the dashboard's primary query.
  Uses Postgres DISTINCT ON (pipeline_name) with a matching ORDER BY.
  """
  @spec latest_per_pipeline() :: [PipelineMetric.t()]
  def latest_per_pipeline do
    from(m in PipelineMetric,
      distinct: [asc: m.pipeline_name],
      order_by: [asc: m.pipeline_name, desc: m.inserted_at, desc: m.id]
    )
    |> repo().all()
  end

  @doc """
  The most recent `PipelineRun` per run `name`, as a `%{name => run}` map — the stale-green
  guard's data source. The dashboard joins each metric row to this by `pipeline_name`: a
  hard scrape failure never reaches `PipelineRun.complete/2` (so it writes no metric row),
  but it DOES leave a `:failed` run, which this surfaces even though the newest metric is an
  old green one. Uses the same Postgres DISTINCT ON idiom as `latest_per_pipeline/0`, on
  `pipeline_runs.name`. (`pipeline_runs` is small — one row per run — so the DISTINCT ON
  sort is cheap; no new index is required for this query.)
  """
  @spec latest_run_per_pipeline() :: %{String.t() => PipelineRun.t()}
  def latest_run_per_pipeline do
    from(r in PipelineRun,
      distinct: [asc: r.name],
      order_by: [asc: r.name, desc: r.inserted_at, desc: r.id]
    )
    |> repo().all()
    |> Map.new(fn run -> {run.name, run} end)
  end

  @doc "Recent metrics rows for one pipeline, newest first (for a future trend view)."
  @spec history(String.t(), pos_integer()) :: [PipelineMetric.t()]
  def history(pipeline_name, limit \\ 30) do
    from(m in PipelineMetric,
      where: m.pipeline_name == ^pipeline_name,
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^limit
    )
    |> repo().all()
  end

  @doc """
  **Metric-intrinsic** health of one row: `:alert` iff `failed > 0` (processing trouble)
  OR `found == 0` for a full-listing scraper (empty scrape — see `expects_data?/1`).

  This is the helper the per-pipeline Subphase-2 tests use (they hold a metric but no run).
  Note `unmapped` (`found - mapped`) is deliberately NOT an alert condition — a nonzero
  unmapped baseline is normal (e.g. `meeting_agenda` intentionally leaves non-Amesbury
  boards unmapped); it is tracked/displayed for a human to watch, never auto-alerted.
  """
  @spec status(PipelineMetric.t()) :: :ok | :alert
  def status(metric) do
    if metric_reasons(metric) == [], do: :ok, else: :alert
  end

  @doc """
  **Dashboard** health: the metric-intrinsic signals PLUS "the pipeline's latest run
  failed/cancelled" (the stale-green guard). `last_run` is the row from
  `latest_run_per_pipeline/0` for this pipeline (or `nil`).
  """
  @spec overall_status(PipelineMetric.t(), PipelineRun.t() | nil) :: :ok | :alert
  def overall_status(metric, last_run) do
    if alert_reasons(metric, last_run) == [], do: :ok, else: :alert
  end

  @doc """
  Short human-readable alert reasons for a dashboard row (empty list ⇒ healthy). Drives
  both `overall_status/2` and the badge label, so the operator sees *why* a row is red.
  """
  @spec alert_reasons(PipelineMetric.t(), PipelineRun.t() | nil) :: [String.t()]
  def alert_reasons(metric, last_run) do
    metric_reasons(metric) ++ run_reasons(last_run)
  end

  # failed>0 and empty-scrape are intrinsic to the metric row.
  @spec metric_reasons(PipelineMetric.t()) :: [String.t()]
  defp metric_reasons(%PipelineMetric{failed: failed, found: found, pipeline_name: name}) do
    []
    |> prepend_if(failed > 0, "#{failed} failed")
    |> prepend_if(found == 0 and expects_data?(name), "empty scrape")
  end

  @spec run_reasons(PipelineRun.t() | nil) :: [String.t()]
  defp run_reasons(%PipelineRun{status: status}) when status in [:failed, :cancelled],
    do: ["last run #{status}"]

  defp run_reasons(_), do: []

  defp prepend_if(list, true, item), do: [item | list]
  defp prepend_if(list, false, _item), do: list

  # The host's Ecto repo, resolved at RUNTIME. `allm_pipeline` deliberately
  # depends on no umbrella app (see `apps/allm_pipeline/mix.exs`), so this tree
  # cannot `alias Amesbury.Repo` — that is a compile error here, by design.
  @spec repo() :: module()
  defp repo, do: Config.repo()
end
