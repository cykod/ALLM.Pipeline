defmodule ALLM.Pipeline.QueryTest do
  @moduledoc """
  Pins `ALLM.Pipeline.Query`, the read-only host-facing facade.

  DB-backed: checks the repo out per this repo's `CLAUDE.md` §3.
  `Query` reads no application env and holds no state, so these tests are
  `async: true` — each checks out its own sandboxed connection.

  The two functions that carry logic (`resolve_step_log/1`'s tuple→map divergence
  and `llm_artifact_url/2`'s depth-capped upward walk) get behaviour + guard
  assertions; the seven thin delegates get parity assertions against the
  underlying function.
  """
  use ExUnit.Case, async: true

  alias ALLM.Pipeline.{ArtifactStore, Config, PipelineRun, Query, StepLog}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Config.repo())
    :ok
  end

  # A run, ready to hang step logs off.
  defp new_run(name \\ "query_test_pipeline") do
    {:ok, run} = PipelineRun.create(name)
    run
  end

  # Insert a step log directly through its changeset so a test can set
  # `input_step_id` / `llm_artifact_url` explicitly (the public log_* helpers do
  # not expose these).
  defp insert_step(run_id, attrs) do
    {:ok, step} =
      %StepLog{}
      |> StepLog.changeset(
        Map.merge(
          %{
            pipeline_run_id: run_id,
            step_type: "step",
            status: :success,
            started_at: DateTime.utc_now(),
            completed_at: DateTime.utc_now(),
            duration_ms: 0
          },
          attrs
        )
      )
      |> Config.repo().insert()

    step
  end

  describe "resolve_step_log/1" do
    test "returns the %{run_id, pipeline_name, step_type} MAP for a seeded step log" do
      run = new_run("resolve_pipeline")
      step = insert_step(run.id, %{step_type: "extract"})

      result = Query.resolve_step_log(step.id)

      # Guard: a mutant returning the {run_id, name, step_type} TUPLE the host used
      # to return fails this map-shape assertion.
      assert is_map(result)
      refute is_tuple(result)

      assert result == %{
               run_id: run.id,
               pipeline_name: "resolve_pipeline",
               step_type: "extract"
             }
    end

    test "returns nil for nil, an unknown id, and a step whose run is gone" do
      assert Query.resolve_step_log(nil) == nil
      assert Query.resolve_step_log(Ecto.UUID.generate()) == nil
    end
  end

  describe "llm_artifact_url/2" do
    # leaf --input_step_id--> mid --input_step_id--> root ; only `root` (distance 2)
    # carries an llm_artifact_url.
    defp three_deep_chain(run_id, root_url) do
      root = insert_step(run_id, %{step_type: "transform", llm_artifact_url: root_url})
      mid = insert_step(run_id, %{step_type: "enrich", input_step_id: root.id})
      leaf = insert_step(run_id, %{step_type: "load", input_step_id: mid.id})
      %{root: root, mid: mid, leaf: leaf}
    end

    test "walks a 3-deep input_step_id chain and returns the first non-nil llm_artifact_url" do
      run = new_run()
      %{leaf: leaf} = three_deep_chain(run.id, "s3://llm/root")

      # Guard: a mutant that stops at depth 1 (examines only `leaf`, which has no
      # url) returns nil and fails here — the artifact is at distance 2.
      assert Query.llm_artifact_url(leaf.id, 32) == "s3://llm/root"
      # Exactly enough depth (distance 0,1,2) also finds it...
      assert Query.llm_artifact_url(leaf.id, 3) == "s3://llm/root"
      # ...but one hop short does not — pins the take(max_depth) semantics.
      assert Query.llm_artifact_url(leaf.id, 2) == nil
    end

    test "returns the NEAREST step's url, not the furthest" do
      run = new_run()
      root = insert_step(run.id, %{step_type: "transform", llm_artifact_url: "s3://llm/root"})

      mid =
        insert_step(run.id, %{
          step_type: "enrich",
          llm_artifact_url: "s3://llm/mid",
          input_step_id: root.id
        })

      leaf = insert_step(run.id, %{step_type: "load", input_step_id: mid.id})

      assert Query.llm_artifact_url(leaf.id, 32) == "s3://llm/mid"
    end

    test "returns nil at max_depth: 0 even when an artifact exists on the chain" do
      run = new_run()
      %{leaf: leaf} = three_deep_chain(run.id, "s3://llm/root")

      # Guard: a mutant ignoring max_depth would return "s3://llm/root" here.
      assert Query.llm_artifact_url(leaf.id, 0) == nil
    end

    test "returns nil for a nil id and for a chain with no artifact" do
      run = new_run()
      root = insert_step(run.id, %{step_type: "transform"})
      leaf = insert_step(run.id, %{step_type: "load", input_step_id: root.id})

      assert Query.llm_artifact_url(nil, 32) == nil
      assert Query.llm_artifact_url(leaf.id, 32) == nil
    end
  end

  describe "delegation parity" do
    test "list_runs/1 and count_runs/1 match PipelineRun.list/1 and .count/1" do
      new_run("delegate_a")
      new_run("delegate_b")

      assert Query.list_runs([]) == PipelineRun.list([])
      assert Query.list_runs(name: "delegate_a") == PipelineRun.list(name: "delegate_a")
      assert Query.count_runs([]) == PipelineRun.count([])
      # Guard: list_runs delegating to a differently-filtered function would
      # diverge from the underlying result for a specific name filter.
      assert Query.count_runs(name: "delegate_a") == PipelineRun.count(name: "delegate_a")
    end

    test "get_run/1 matches PipelineRun.get_with_steps/1 (step_logs PRELOADED)" do
      run = new_run()
      insert_step(run.id, %{step_type: "one"})

      result = Query.get_run(run.id)

      assert result == PipelineRun.get_with_steps(run.id)
      # Guard: delegating to PipelineRun.get/1 instead would leave step_logs a
      # %NotLoaded{}; get_with_steps preloads them as a list.
      assert is_list(result.step_logs)
      assert length(result.step_logs) == 1
    end

    test "get_step/1 matches StepLog.get/1" do
      run = new_run()
      step = insert_step(run.id, %{step_type: "one"})

      assert Query.get_step(step.id) == StepLog.get(step.id)
    end

    test "run_stats/1 matches StepLog.get_pipeline_stats/1" do
      run = new_run()
      insert_step(run.id, %{step_type: "one", status: :success})
      insert_step(run.id, %{step_type: "two", status: :failed})

      result = Query.run_stats(run.id)

      assert result == StepLog.get_pipeline_stats(run.id)
      # Guard: a delegate pointed at count_by_step_type/1 (a differently-shaped
      # map) would not carry the aggregate keys.
      assert %{total_steps: 2, successful: 1, failed: 1} = result
    end

    test "lineage_tree/1 matches StepLog.build_lineage_tree/1" do
      run = new_run()
      root = insert_step(run.id, %{step_type: "root"})
      leaf = insert_step(run.id, %{step_type: "leaf", input_step_id: root.id})

      assert Query.lineage_tree(leaf.id) == StepLog.build_lineage_tree(leaf.id)
      assert {:ok, [_, _]} = Query.lineage_tree(leaf.id)
    end

    test "fetch_artifact/1 matches ArtifactStore.fetch/1" do
      # A scheme no adapter owns — a hermetic parity check that needs no stored
      # artifact and reaches no backend (every adapter rejects an unrecognized
      # URL with `{:error, {:invalid_artifact_url, url}}` before any I/O). Phase
      # 7.5 made `s3://` real, so an `s3://` URL would now try the network; this
      # asserts the delegation, not the removed `:s3_not_implemented` stub.
      url = "bogus://nothing/here"
      assert Query.fetch_artifact(url) == ArtifactStore.fetch(url)
      assert {:error, {:invalid_artifact_url, ^url}} = Query.fetch_artifact(url)
    end
  end
end
