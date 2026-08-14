defmodule ALLM.Pipeline.ExecutorTest do
  @moduledoc """
  Pins `ALLM.Pipeline.Executor`.

  ## The sandbox setup, and why it is not a `DataCase`

  Moved here from `apps/amesbury_scraper/test/` in batch 1.D. The package tree
  deliberately depends on no umbrella app, so it cannot see
  `AmesburyScraper.DataCase` — the four lines below are a faithful port of that
  template's `setup_sandbox/1`, including its `shared: not tags[:async]`, so an
  `async: true` file keeps behaving exactly as it did before the move. The repo
  is named the way all package code names it, through `Config.repo/0`.

  `Sandbox.checkout/1` (the shorter form `store_test.exs` uses) needs the repo
  in `:manual` mode; so does `start_owner!/2`. This package's own
  `test/test_helper.exs` is what puts it there.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ALLM.Pipeline.Config
  alias ALLM.Pipeline.PipelineRun
  alias ALLM.Pipeline.Executor

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  # Test step implementation for testing the runner
  defmodule TestStep do
    @behaviour ALLM.Pipeline.Step

    defmodule Input do
      use Ecto.Schema

      @primary_key false
      embedded_schema do
        field(:value, :string)
      end
    end

    defmodule Output do
      use Ecto.Schema

      @primary_key false
      embedded_schema do
        field(:result, :string)
        field(:processed_at, :utc_datetime_usec)
      end
    end

    @impl true
    def step_type, do: :test_step

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_context, %Input{value: value}) do
      {:ok, %Output{result: "processed: #{value}", processed_at: DateTime.utc_now()}}
    end
  end

  # Test step that produces artifacts
  defmodule ArtifactStep do
    @behaviour ALLM.Pipeline.Step

    defmodule Input do
      use Ecto.Schema

      @primary_key false
      embedded_schema do
        field(:data, :string)
      end
    end

    defmodule Output do
      use Ecto.Schema

      @primary_key false
      embedded_schema do
        field(:content, :string)
      end
    end

    @impl true
    def step_type, do: :artifact_step

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def artifact_content_type, do: "text/plain"

    @impl true
    def artifact_content(%Output{content: content}), do: content

    @impl true
    def execute(_context, %Input{data: data}) do
      {:ok, %Output{content: "Artifact: #{data}"}}
    end
  end

  # Test step that fails
  defmodule FailingStep do
    @behaviour ALLM.Pipeline.Step

    defmodule Input do
      use Ecto.Schema

      @primary_key false
      embedded_schema do
        field(:should_fail, :boolean)
      end
    end

    defmodule Output do
      use Ecto.Schema

      @primary_key false
      embedded_schema do
        field(:never, :string)
      end
    end

    @impl true
    def step_type, do: :failing_step

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_context, %Input{should_fail: true}) do
      {:error, "Step failed as expected"}
    end

    def execute(_context, %Input{should_fail: false}) do
      {:ok, %Output{never: "success"}}
    end
  end

  # A step whose `step_type/0` is nil, so `StepLog.log_start/4` casts
  # `step_type: ""` — an empty value to Ecto, which `validate_required/2` then
  # rejects. That is the cheapest way to drive the `step_logs` insert to
  # `{:error, changeset}`; in production the same arm is reached by an
  # `input_data` jsonb Postgres refuses (22P05) or a `pipeline_run_id` FK
  # violation.
  defmodule UnloggableStep do
    @behaviour ALLM.Pipeline.Step

    @impl true
    def step_type, do: nil

    @impl true
    def input_schema, do: TestStep.Input

    @impl true
    def output_schema, do: TestStep.Output

    @impl true
    def execute(_context, _input), do: {:ok, %TestStep.Output{result: "never reached"}}
  end

  # Returns a plain map where the behaviour promises an `output_schema()` struct.
  defmodule NonStructOutputStep do
    @behaviour ALLM.Pipeline.Step

    @impl true
    def step_type, do: :non_struct_output_step

    @impl true
    def input_schema, do: TestStep.Input

    @impl true
    def output_schema, do: TestStep.Output

    @impl true
    def execute(_context, _input), do: {:ok, %{result: "a bare map"}}
  end

  describe "create_pipeline_run/2" do
    test "creates pipeline run record" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test_pipeline")

      assert pipeline_run.name == "test_pipeline"
      assert pipeline_run.status == :running
      assert pipeline_run.started_at != nil
    end

    test "creates pipeline run with metadata" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test", %{source: "test"})

      assert pipeline_run.metadata["source"] == "test"
    end

    test "normalizes a Date in metadata to an ISO-8601 string (does not crash)" do
      {:ok, pipeline_run} =
        Executor.create_pipeline_run("test", %{options: %{today: ~D[2026-06-16]}})

      assert pipeline_run.metadata["options"]["today"] == "2026-06-16"
    end

    test "normalizes DateTime / NaiveDateTime / Time structs in metadata" do
      {:ok, pipeline_run} =
        Executor.create_pipeline_run("test", %{
          dt: ~U[2026-06-16 13:30:00Z],
          ndt: ~N[2026-06-16 13:30:00],
          t: ~T[13:30:00]
        })

      assert pipeline_run.metadata["dt"] == "2026-06-16T13:30:00Z"
      assert pipeline_run.metadata["ndt"] == "2026-06-16T13:30:00"
      assert pipeline_run.metadata["t"] == "13:30:00"
    end

    test "normalizes an arbitrary (non-Calendar) struct in metadata" do
      {:ok, pipeline_run} =
        Executor.create_pipeline_run("test", %{range: %Range{first: 1, last: 3, step: 1}})

      assert pipeline_run.metadata["range"]["first"] == 1
      assert pipeline_run.metadata["range"]["last"] == 3
    end
  end

  describe "run_step/5" do
    setup do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test_pipeline")
      %{pipeline_run: pipeline_run}
    end

    test "validates input against step's input_schema", %{pipeline_run: pipeline_run} do
      input = %TestStep.Input{value: "test"}

      {:ok, step_log, output} = Executor.run_step(pipeline_run, TestStep, input)

      assert step_log.status == :success
      assert output.result == "processed: test"
    end

    test "rejects mismatched input schema", %{pipeline_run: pipeline_run} do
      # Try to use wrong input type
      wrong_input = %FailingStep.Input{should_fail: false}

      {:error, nil, reason} = Executor.run_step(pipeline_run, TestStep, wrong_input)

      assert reason =~ "Input must be"
    end

    test "logs step with pipeline_run_id", %{pipeline_run: pipeline_run} do
      input = %TestStep.Input{value: "test"}

      {:ok, step_log, _output} = Executor.run_step(pipeline_run, TestStep, input)

      assert step_log.pipeline_run_id == pipeline_run.id
    end

    test "records timing data (started_at, completed_at, duration_ms)", %{
      pipeline_run: pipeline_run
    } do
      input = %TestStep.Input{value: "test"}

      {:ok, step_log, _output} = Executor.run_step(pipeline_run, TestStep, input)

      assert step_log.started_at != nil
      assert step_log.completed_at != nil
      assert step_log.duration_ms >= 0
    end

    test "marks failed steps with error details", %{pipeline_run: pipeline_run} do
      input = %FailingStep.Input{should_fail: true}

      {:error, step_log, reason} = Executor.run_step(pipeline_run, FailingStep, input)

      assert step_log.status == :failed
      assert step_log.error != nil
      assert reason == "Step failed as expected"
    end

    # The three unrescued sites below all sit OUTSIDE `execute_step`'s try/rescue,
    # so before this change each raised out through `run_step/5`. Callers fan
    # `run_step/5` out through `Task.async_stream`, which links its children — so
    # the raise did not surface as a `FunctionClauseError` at the unpack, it
    # killed the calling process outright and lost every sibling item's result.
    test "a failing step_logs insert returns an error tuple instead of raising", %{
      pipeline_run: pipeline_run
    } do
      input = %TestStep.Input{value: "test"}

      log =
        capture_log(fn ->
          assert {:error, nil, {:step_log_start_failed, %Ecto.Changeset{}}} =
                   Executor.run_step(pipeline_run, UnloggableStep, input)
        end)

      assert log =~ "Failed to log step start"
    end

    test "a non-struct input is rejected rather than raising BadMapError", %{
      pipeline_run: pipeline_run
    } do
      log =
        capture_log(fn ->
          assert {:error, nil, reason} =
                   Executor.run_step(pipeline_run, TestStep, %{value: "a bare map"})

          assert reason =~ "Input must be"
          assert reason =~ "a bare map"
        end)

      assert log =~ "Input validation failed"
    end

    test "a step returning a non-struct output names the contract it broke", %{
      pipeline_run: pipeline_run
    } do
      input = %TestStep.Input{value: "test"}

      capture_log(fn ->
        assert {:error, step_log, {:output_validation_failed, reason}} =
                 Executor.run_step(pipeline_run, NonStructOutputStep, input)

        assert reason =~ "Output must be"
        assert step_log.status == :failed
        # Not a `%BadMapError{}` — the recorded error says what the Step did wrong.
        assert step_log.error["message"] =~ "Output must be"
      end)
    end

    test "creates lineage links via input_step_id", %{pipeline_run: pipeline_run} do
      input1 = %TestStep.Input{value: "first"}
      {:ok, step1, _output1} = Executor.run_step(pipeline_run, TestStep, input1)

      input2 = %TestStep.Input{value: "second"}
      {:ok, step2, _output2} = Executor.run_step(pipeline_run, TestStep, input2, step1.id)

      assert step2.input_step_id == step1.id
    end
  end

  describe "log_section/3" do
    test "delegates to StepLog.log_section and returns section step_log" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test_pipeline")

      {:ok, section} = Executor.log_section(pipeline_run, "My Section")

      assert section.step_type == "section"
      assert section.status == :success
      assert section.input_data == %{"title" => "My Section"}
      assert section.pipeline_run_id == pipeline_run.id
    end

    test "accepts optional parent step id" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test_pipeline")
      input = %TestStep.Input{value: "test"}
      {:ok, parent_step, _output} = Executor.run_step(pipeline_run, TestStep, input)

      {:ok, section} = Executor.log_section(pipeline_run, "Child Section", parent_step.id)

      assert section.input_step_id == parent_step.id
    end
  end

  describe "complete_pipeline_run/3" do
    test "marks pipeline run as completed" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test")

      {:ok, completed} = Executor.complete_pipeline_run(pipeline_run, [], [])

      assert completed.status == :success
      assert completed.completed_at != nil
    end

    test "includes statistics in metadata" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test")
      input = %TestStep.Input{value: "test"}
      {:ok, step, output} = Executor.run_step(pipeline_run, TestStep, input)

      {:ok, completed} =
        Executor.complete_pipeline_run(pipeline_run, [{:ok, step, output}], [])

      assert completed.metadata["stats"]["total_steps"] == 1
      assert completed.metadata["detail_count"] == 1
    end

    test "refuses a borrowed run" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test")

      assert {:error, :not_run_owner} =
               Executor.complete_pipeline_run(PipelineRun.borrow(pipeline_run), [], [])
    end
  end

  describe "borrowed_run/1" do
    test "returns a NON-owning handle on the lent run" do
      {:ok, umbrella} = Executor.create_pipeline_run("umbrella")

      assert {:ok, borrowed} = Executor.borrowed_run(pipeline_run: umbrella)
      assert borrowed.id == umbrella.id
      refute PipelineRun.owner?(borrowed)
      assert PipelineRun.owner?(umbrella)
    end

    test "returns :error when no run was lent (the self-owned branch)" do
      assert Executor.borrowed_run([]) == :error
      assert Executor.borrowed_run(force: true) == :error
      assert Executor.borrowed_run(pipeline_run: nil) == :error
    end

    # Membership guard (root CLAUDE.md). The borrowed-run boundary is enforced by
    # stripping the token on RECEIPT, so every module that reads a lent run out of
    # `opts` must go through `Executor.borrowed_run/1`. A hand-inlined
    # `Keyword.fetch(opts, :pipeline_run)` would hand the inner pipeline an OWNING
    # handle and silently restore the pre-fix clobber.
    test "every borrowed-run read goes through borrowed_run/1" do
      # Scans BOTH trees. The invariant spans the app split: `borrowed_run/1`
      # lives in `allm_pipeline`, but the modules that must funnel through it
      # are host pipelines, and a future framework module could read the opt too.
      apps = Path.join([__DIR__, "..", "..", "..", ".."])

      trees = [
        {"allm_pipeline (the framework)", Path.join([apps, "allm_pipeline", "lib"]), 10},
        {"amesbury_scraper (the host)", Path.join([apps, "amesbury_scraper", "lib"]), 100}
      ]

      # A grep guard whose success signal is "found nothing" fails OPEN: a
      # zero-file glob makes every filter below yield `[]`, and the test reports
      # green while guarding nothing (root CLAUDE.md: "whenever a procedure's
      # success signal is 'nothing changed', add a step confirming something
      # did"). Each tree carries its OWN floor so moving one cannot be masked by
      # the other still matching. Floors sit well under the counts re-measured
      # 2026-08-14 (24 and 210) — `find apps/<app>/lib -name '*.ex' | wc -l`.
      # The 2026-08-13 figures this comment used to carry (18 and 209) predated
      # the framework move and disagreed with §5.5 two files away.
      files =
        Enum.flat_map(trees, fn {label, lib, floor} ->
          matched = lib |> Path.join("**/*.ex") |> Path.wildcard()

          assert length(matched) > floor,
                 "the guard glob matched only #{length(matched)} files under #{lib} " <>
                   "(#{label}) — that tree moved and this test is no longer scanning " <>
                   "it. Re-point the guard."

          matched
        end)

      offenders =
        files
        # Only `ALLM.Pipeline.Executor` itself may read the opt directly —
        # matched by path suffix, not basename. `amesbury_scraper/runner.ex`
        # (the cron dispatcher, a DIFFERENT module that keeps its name) is now
        # in a different tree AND has a different basename, but keep the suffix
        # match: it is the property that made the exemption safe to begin with.
        |> Enum.reject(&String.ends_with?(&1, "pipeline/executor.ex"))
        |> Enum.filter(fn path ->
          # Every Keyword READ accessor (`pop` included), any binding name — several
          # pipelines thread a `meeting_opts` rather than a literal `opts` — and the
          # `opts[:pipeline_run]` Access form, which works on keyword lists.
          # `Keyword.put`/`put_new` are deliberately absent: those are the LEND
          # sites (`video_summary_pipeline.ex:194,433`), which are correct and must
          # not be flagged. It is the receiving read that has to be funnelled.
          File.read!(path) =~
            ~r/Keyword\.(fetch!?|get|get_lazy|pop!?|pop_lazy|take)\(\s*\w+,\s*:pipeline_run|\w+\[:pipeline_run\]/
        end)
        |> Enum.map(&Path.relative_to(&1, apps))

      assert offenders == [],
             "these modules read a borrowed run directly instead of via " <>
               "Executor.borrowed_run/1, so they receive an OWNING handle: #{inspect(offenders)}"
    end
  end

  describe "fail_pipeline_run/2" do
    test "marks pipeline run as failed" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test")

      {:ok, failed} = Executor.fail_pipeline_run(pipeline_run, "Something went wrong")

      assert failed.status == :failed
      assert failed.metadata["error"]["message"] == "Something went wrong"
    end
  end

  describe "get_status/1" do
    test "returns pipeline status and statistics" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test")
      input = %TestStep.Input{value: "test"}
      Executor.run_step(pipeline_run, TestStep, input)

      {:ok, status} = Executor.get_status(pipeline_run.id)

      assert status.pipeline_run.id == pipeline_run.id
      assert status.stats.total_steps == 1
    end

    test "returns error for non-existent pipeline" do
      assert {:error, :not_found} = Executor.get_status(Ecto.UUID.generate())
    end
  end

  describe "resume/2" do
    test "can resume a pipeline from a specific step" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test")
      input = %TestStep.Input{value: "test"}
      {:ok, step, _output} = Executor.run_step(pipeline_run, TestStep, input)

      # Fail the pipeline
      {:ok, failed_run} = Executor.fail_pipeline_run(pipeline_run, "Test failure")

      # Resume
      {:ok, resumed} = Executor.resume(failed_run.id, step.id)

      assert resumed.status == :running
    end

    test "returns error for non-existent pipeline" do
      assert {:error, :pipeline_not_found} =
               Executor.resume(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "returns error for non-existent step" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test")

      assert {:error, :step_not_found} = Executor.resume(pipeline_run.id, Ecto.UUID.generate())
    end

    test "returns error if step is not in the pipeline" do
      {:ok, pipeline_run1} = Executor.create_pipeline_run("test1")
      {:ok, pipeline_run2} = Executor.create_pipeline_run("test2")
      input = %TestStep.Input{value: "test"}
      {:ok, step, _output} = Executor.run_step(pipeline_run1, TestStep, input)

      assert {:error, :step_not_in_pipeline} = Executor.resume(pipeline_run2.id, step.id)
    end
  end
end
