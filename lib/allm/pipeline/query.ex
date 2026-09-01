defmodule ALLM.Pipeline.Query do
  @moduledoc """
  The package-owned, **read-only** query facade for host UIs and host contexts.

  Every function here delegates to an existing implementation on `PipelineRun`,
  `StepLog` or `ArtifactStore`. The value is a single, `@spec`'d, host-facing
  module instead of hosts reaching into three schemas directly: a host app
  routes its provenance/lineage reads through this module rather than
  hand-writing raw `"step_logs"` / `"pipeline_runs"` queries, which keeps the
  host depending on the package and never the reverse.

  ## Read-only by contract

  `Query` exposes **no write path** — no create/update/delete, no run
  termination. Terminating a run is an ownership capability that lives on
  `PipelineRun` behind the completion token (see its moduledoc); a read facade
  must not offer a door around it. Adding a write function here is a design
  error, not a convenience.

  ## No new `Store` callback

  `Query` lives inside the package, so it calls the schema query functions
  directly. It is NOT a framework seam and needs no `Store` behaviour callback —
  those exist for the WRITE path the Executor drives (`store.ex`). A read that a
  host wants goes here as a delegating function, not onto the `Store` behaviour.
  """

  alias ALLM.Pipeline.{ArtifactStore, PipelineRun, StepLog}

  @doc """
  Resolve a step log's identity to `%{run_id, pipeline_name, step_type}`, or
  `nil` when the id is `nil`, unknown, or its run is missing.

  Returns a **map**, deliberately not a `{run_id, name, step_type}` tuple: a map
  lets a future field be added without breaking callers. This is the host
  provenance-attribution read path — a host resolves a step log's identity
  through here rather than joining the two schemas itself.
  """
  @spec resolve_step_log(Ecto.UUID.t() | nil) ::
          %{run_id: Ecto.UUID.t(), pipeline_name: String.t(), step_type: String.t()} | nil
  def resolve_step_log(nil), do: nil

  def resolve_step_log(step_log_id) do
    with %StepLog{pipeline_run_id: run_id, step_type: step_type} when is_binary(run_id) <-
           StepLog.get(step_log_id),
         %PipelineRun{name: name} <- PipelineRun.get(run_id) do
      %{run_id: run_id, pipeline_name: name, step_type: step_type}
    else
      _ -> nil
    end
  end

  @doc """
  Walk the `input_step_id` lineage upward from `step_log_id` and return the first
  (nearest) step's `llm_artifact_url`, or `nil` when none is found within
  `max_depth` hops.

  The depth cap is a **parameter**, not a package constant — how deep to walk is
  host policy and is passed in. `max_depth`
  of `0` returns `nil` without examining any step; `max_depth` of `n` examines
  the steps at distance `0..n-1` from `step_log_id`.

  The upward traversal reuses `StepLog.build_lineage_tree/1`'s recursive CTE
  rather than carrying a second `input_step_id` walker in the package (one
  traversal, one place).
  """
  @spec llm_artifact_url(Ecto.UUID.t() | nil, non_neg_integer()) :: String.t() | nil
  def llm_artifact_url(nil, _max_depth), do: nil
  def llm_artifact_url(_step_log_id, max_depth) when max_depth <= 0, do: nil

  def llm_artifact_url(step_log_id, max_depth) do
    case StepLog.build_lineage_tree(step_log_id) do
      {:ok, chain} ->
        chain
        |> Enum.sort_by(& &1.depth)
        |> Enum.take(max_depth)
        |> Enum.find_value(&step_llm_artifact_url(&1.id))

      {:error, _reason} ->
        nil
    end
  end

  @doc "List pipeline runs (delegates to `PipelineRun.list/1`)."
  @spec list_runs(keyword()) :: [PipelineRun.t()]
  def list_runs(opts \\ []), do: PipelineRun.list(opts)

  @doc "Count pipeline runs matching `list_runs/1`'s filters (delegates to `PipelineRun.count/1`)."
  @spec count_runs(keyword()) :: non_neg_integer()
  def count_runs(opts \\ []), do: PipelineRun.count(opts)

  @doc "Get a run with its step logs preloaded (delegates to `PipelineRun.get_with_steps/1`)."
  @spec get_run(Ecto.UUID.t()) :: PipelineRun.t() | nil
  def get_run(id), do: PipelineRun.get_with_steps(id)

  @doc "Get a single step log (delegates to `StepLog.get/1`)."
  @spec get_step(Ecto.UUID.t()) :: StepLog.t() | nil
  def get_step(id), do: StepLog.get(id)

  @doc "Aggregate step statistics for a run (delegates to `StepLog.get_pipeline_stats/1`)."
  @spec run_stats(Ecto.UUID.t()) :: map()
  def run_stats(run_id), do: StepLog.get_pipeline_stats(run_id)

  @doc """
  Build the lineage tree upward from a step log (delegates to
  `StepLog.build_lineage_tree/1`, which takes a **step** id).
  """
  @spec lineage_tree(Ecto.UUID.t()) :: {:ok, [map()]} | {:error, term()}
  def lineage_tree(step_log_id), do: StepLog.build_lineage_tree(step_log_id)

  @doc "Fetch a stored artifact's decompressed bytes (delegates to `ArtifactStore.fetch/1`)."
  @spec fetch_artifact(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_artifact(url), do: ArtifactStore.fetch(url)

  # One point-get per examined hop: the shared `build_lineage_tree/1` CTE does not
  # SELECT `llm_artifact_url`, so this re-fetches each candidate step to read it.
  # A deliberate tradeoff — widening the shared CTE's SELECT would change
  # `lineage_tree/1`'s output shape. `Enum.find_value` short-circuits on the first
  # hit and lineage chains are short, so the walk is bounded and this debug path
  # is rare.
  @spec step_llm_artifact_url(Ecto.UUID.t()) :: String.t() | nil
  defp step_llm_artifact_url(step_id) do
    case StepLog.get(step_id) do
      %StepLog{llm_artifact_url: url} when is_binary(url) -> url
      _ -> nil
    end
  end
end
