defmodule ALLM.Pipeline.Dsl.RuntimeTest do
  @moduledoc """
  Pins the RUNTIME half of `use ALLM.Pipeline`: the generated lifecycle, lineage
  threading, fan-out, the accumulator channel, skips, delays, metrics and the
  terminal write.

  DB-backed, per `apps/allm_pipeline/CLAUDE.md` §3 — the DSL's whole job is to
  write `pipeline_runs` and `step_logs` rows, so an in-memory test of it would
  observe nothing.

  Pipelines are declared as module fixtures at the top of the file rather than
  inline: `use ALLM.Pipeline` runs at compile time, and a declaration inside a
  `test` block would be re-evaluated per run.
  """

  use ExUnit.Case, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias ALLM.Pipeline.{Config, Context, FanOut, Metrics, PipelineMetric, PipelineRun, StepLog}
  alias ALLM.Pipeline.Dsl.Item

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  # ── Stub steps ────────────────────────────────────────────────────────────

  defmodule EchoStep do
    @moduledoc false
    @behaviour ALLM.Pipeline.Step

    defmodule Input do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema do
        field(:value, :string)
      end
    end

    defmodule Output do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema do
        field(:value, :string)
      end
    end

    @impl true
    def step_type, do: :dsl_echo

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_context, %Input{value: value}) do
      # A counter so "the DSL applies a step's hooks exactly once per item"
      # is observable (`.work/HANDOFF.md`, Phase 3 3.4: `post_process/2` is not
      # idempotent on two ported steps, so a re-application is a live hazard).
      case Process.get(:dsl_echo_counter) do
        nil -> :ok
        agent -> Agent.update(agent, &(&1 + 1))
      end

      {:ok, %Output{value: value}}
    end
  end

  defmodule SecondStep do
    @moduledoc false
    @behaviour ALLM.Pipeline.Step

    defmodule Input do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema do
        field(:value, :string)
      end
    end

    defmodule Output do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema do
        field(:value, :string)
      end
    end

    @impl true
    def step_type, do: :dsl_second

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_context, %Input{value: value}), do: {:ok, %Output{value: value}}
  end

  defmodule FailingStep do
    @moduledoc false
    @behaviour ALLM.Pipeline.Step

    defmodule Input do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema do
        field(:value, :string)
      end
    end

    defmodule Output do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema do
        field(:value, :string)
      end
    end

    @impl true
    def step_type, do: :dsl_failing

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_context, %Input{}), do: {:error, :deliberate}
  end

  defmodule ExitingStep do
    @moduledoc false
    @behaviour ALLM.Pipeline.Step

    defmodule Input do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema do
        field(:value, :string)
      end
    end

    defmodule Output do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema do
        field(:value, :string)
      end
    end

    @impl true
    def step_type, do: :dsl_exiting

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    # An EXIT, not an exception: `Executor.run_step/5`'s `try/rescue` does NOT
    # catch it, so it propagates to the concurrent fan-out's always-on
    # `FanOut.guard`, which is the link-safety this step exercises.
    @impl true
    def execute(_context, %Input{value: "boom"}), do: exit(:deliberate)
    def execute(_context, %Input{value: value}), do: {:ok, %Output{value: value}}
  end

  # ── Pipeline fixtures ─────────────────────────────────────────────────────

  defmodule TwoStages do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_two_stages", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeTest.{EchoStep, SecondStep}

    stage(:first, EchoStep, input: :first_input)
    stage(:second, SecondStep, input: :second_input)

    defp first_input(_ctx, _prev), do: %EchoStep.Input{value: "one"}
    defp second_input(_ctx, prev), do: %SecondStep.Input{value: prev.value <> "-two"}
  end

  defmodule SourceStageFanOut do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_source_stage_fan_out", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeTest.{EchoStep, SecondStep}

    stage(:root, EchoStep, input: :root_input)
    fan_out(:items, SecondStep, over: :three, input: :item_input)

    defp root_input(_ctx, _prev), do: %EchoStep.Input{value: "root"}
    defp three(_prev), do: ["a", "b", "c"]
    defp item_input(_ctx, item), do: %SecondStep.Input{value: item}
  end

  defmodule PerItemFanOut do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_per_item_fan_out", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeTest.{EchoStep, SecondStep}

    stage(:root, EchoStep, input: :root_input)
    fan_out(:first, SecondStep, over: :three, input: :item_input)

    fan_out(:second, SecondStep,
      over: :ok_items,
      input: :second_input,
      parent: :per_item
    )

    defp root_input(_ctx, _prev), do: %EchoStep.Input{value: "root"}
    defp three(_prev), do: ["a", "b", "c"]
    defp item_input(_ctx, item), do: %SecondStep.Input{value: item}
    defp ok_items(items), do: ALLM.Pipeline.Dsl.Item.ok_items(items)

    defp second_input(_ctx, %ALLM.Pipeline.Dsl.Item{result: {:ok, out}}),
      do: %SecondStep.Input{value: out.value <> "!"}
  end

  defmodule Counting do
    @moduledoc false
    use ALLM.Pipeline,
      name: "dsl_counting",
      init: :zero,
      complete_metadata: :as_metadata

    # An escape-hatch `stage` body folds the accumulator through
    # `FanOut.reduce/5` — the function form that replaced body-mode `fan_out`
    # (Phase 4.5.1). The accumulator's ONLY write channel is the body's
    # `{item_result, acc}` return, and this pins that it reaches metrics AND
    # `complete/2`.
    stage(:items, :count_all)
    metrics("things", from: :funnel)
    summarize(:passthrough)

    defp zero, do: 0

    defp count_all(ctx, _prev) do
      {items, acc} =
        FanOut.reduce(ctx, [:a, :b, :c], Context.accumulator(ctx), fn _ctx, item, acc ->
          {{:ok, item}, acc + 1}
        end)

      {{:ok, items}, acc}
    end

    defp funnel(summary), do: %{found: 3, processed: summary}
    defp passthrough(acc, _ctx), do: acc
    defp as_metadata(acc), do: %{counted: acc}
  end

  defmodule SkippingStages do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_skipping", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeTest.{EchoStep, SecondStep}

    stage(:first, EchoStep, input: :first_input, carry: [:value])
    stage(:middle, SecondStep, input: :middle_input, skip_when: {:opt, :skip_middle, false})
    stage(:last, SecondStep, input: :last_input)

    defp first_input(_ctx, _prev), do: %EchoStep.Input{value: "carried"}
    defp middle_input(_ctx, prev), do: %SecondStep.Input{value: prev.value}

    # Reads the CARRIED value, not `prev` — that is the assertion the skipped
    # middle stage would break if `carry` lived on a step log.
    defp last_input(ctx, _prev),
      do: %SecondStep.Input{value: Context.carried(ctx, :value) <> "-last"}
  end

  # A `carry:` key the captured subject does not have. `Dsl.validate_carry!/3`
  # accepts it — a literal list of atoms is all it can check — so the miss is a
  # RUNTIME fact, and until 2026-08-21 it was a silent one.
  defmodule CarryMiss do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_carry_miss", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeTest.{EchoStep, SecondStep}

    stage(:root, EchoStep, input: :root_input, carry: [:value, :detail_url])
    stage(:reader, SecondStep, input: :reader_input)

    defp root_input(_ctx, _prev), do: %EchoStep.Input{value: "kept"}

    defp reader_input(ctx, _prev),
      do: %SecondStep.Input{
        value: "#{Context.carried(ctx, :value)}/#{inspect(Context.carried(ctx, :detail_url))}"
      }
  end

  defmodule ContinuingStage do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_continuing", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeTest.{EchoStep, FailingStep, SecondStep}

    stage(:root, EchoStep, input: :root_input)
    stage(:boom, FailingStep, input: :boom_input, on_error: :continue)
    stage(:after_boom, SecondStep, input: :after_input)

    defp root_input(_ctx, _prev), do: %EchoStep.Input{value: "root"}
    defp boom_input(_ctx, _prev), do: %FailingStep.Input{value: "x"}

    # Reads `prev`, so it also proves the failed stage left `prev` alone rather
    # than overwriting it with the error.
    defp after_input(_ctx, prev), do: %SecondStep.Input{value: prev.value <> "-after"}
  end

  defmodule EscapeHatchLineage do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_escape_hatch", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeTest.{EchoStep, SecondStep}

    stage(:root, EchoStep, input: :root_input)
    stage(:transparent, :stay)
    stage(:after_transparent, SecondStep, input: :passthrough)
    stage(:nominating, :nominate)
    stage(:after_nominating, SecondStep, input: :passthrough)

    defp root_input(_ctx, _prev), do: %EchoStep.Input{value: "root"}
    defp passthrough(_ctx, _prev), do: %SecondStep.Input{value: "x"}
    defp stay(_ctx, prev), do: {:ok, prev}

    defp nominate(ctx, _prev) do
      {:ok, log} =
        ALLM.Pipeline.Executor.log_summary(
          ctx.pipeline_run,
          "hand_written",
          %{},
          Context.input_step_id(ctx)
        )

      {:ok, :nominated, log}
    end
  end

  defmodule FailingStage do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_failing_stage"

    alias ALLM.Pipeline.Dsl.RuntimeTest.{FailingStep, SecondStep}

    stage(:boom, FailingStep, input: :boom_input)
    stage(:never, SecondStep, input: :boom_input)

    defp boom_input(_ctx, _prev), do: %FailingStep.Input{value: "x"}
  end

  defmodule NoMetrics do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_no_metrics"

    stage(:only, fn _ctx, _prev -> {:ok, :done} end)
  end

  defmodule OwnershipProbe do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_ownership"

    stage(:observe, fn ctx, _prev ->
      owner? = PipelineRun.owner?(ctx.pipeline_run)
      {{:ok, owner?}, owner?}
    end)

    summarize(:passthrough)

    defp passthrough(acc, _ctx), do: acc
  end

  defmodule ConcurrentExiting do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_concurrent_exit"

    alias ALLM.Pipeline.Dsl.RuntimeTest.ExitingStep

    # A concurrent STEP-target fan_out (body-mode was removed in 4.5.2): an item
    # whose Step EXITS must fail only itself, because `Task.async_stream` links
    # its children and the concurrent path wraps each item in the always-on
    # `FanOut.guard` (`guarded_item/7` passes `true`).
    fan_out(:items, ExitingStep, over: :three, input: :item_input, concurrency: 2)

    # A `fan_out`'s output is its `[Dsl.Item.t()]`, which `summarize` (taking
    # `(acc, ctx)`) cannot see — so a following sequential escape hatch moves it
    # onto the accumulator.
    stage(:collect, fn _ctx, items -> {{:ok, items}, items} end)

    summarize(:passthrough)

    defp three(_prev), do: ["a", "boom", "c"]
    defp item_input(_ctx, item), do: %ExitingStep.Input{value: item}
    defp passthrough(acc, _ctx), do: acc
  end

  # The surviving construct that can raise UNCAUGHT is an escape-hatch `stage`
  # body — a `fan_out`'s Step raise is rescued by `Executor`, and body-mode
  # `fan_out` was removed. Proves the generated `run/1` still writes a terminal
  # status on a raise (the orphan-run defect Phase 4 closed).
  defmodule RaisingBody do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_raising_uncaught"

    stage(:boom, fn _ctx, _prev -> raise("deliberate") end)
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp steps(run_id) do
    from(s in StepLog,
      where: s.pipeline_run_id == ^run_id,
      order_by: [asc: s.inserted_at, asc: s.id]
    )
    |> Config.repo().all()
  end

  defp steps_of_type(run_id, type), do: Enum.filter(steps(run_id), &(&1.step_type == type))

  defp only_run(name) do
    from(r in PipelineRun, where: r.name == ^name) |> Config.repo().one!()
  end

  defp metric_rows(run_id) do
    from(m in PipelineMetric, where: m.pipeline_run_id == ^run_id) |> Config.repo().all()
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "the generated lifecycle" do
    test "creates one run, one step log per stage, and completes the run" do
      assert {:ok, %PipelineRun{} = run} = TwoStages.run()

      assert run.status == :success
      assert run.name == "dsl_two_stages"
      assert run.completed_at

      assert Enum.map(steps(run.id), & &1.step_type) == ["dsl_echo", "dsl_second"]
    end

    test "lineage threads: stage 2's input_step_id EQUALS stage 1's step log id" do
      {:ok, run} = TwoStages.run()
      [first, second] = steps(run.id)

      # Not merely non-nil: an implementation passing the RUN id would satisfy
      # that, and would look correct in the pipeline-review UI's flat list.
      assert second.input_step_id == first.id
      refute second.input_step_id == run.id
      assert is_nil(first.input_step_id)
    end

    test "`run_name:` overrides the declared name for a mode variant" do
      {:ok, run} = TwoStages.run(run_name: "dsl_two_stages_variant")
      assert run.name == "dsl_two_stages_variant"
    end

    test "a stage failing with the default on_error: :fail_run fails the run and halts" do
      assert {:error, :deliberate} = FailingStage.run()

      run = only_run("dsl_failing_stage")
      assert run.status == :failed
      assert run.metadata["error"]

      # The second stage never ran.
      assert steps_of_type(run.id, "dsl_second") == []
    end

    test "on_error: :continue leaves prev and parent alone and the run completes" do
      assert {:ok, run} = ContinuingStage.run()
      assert run.status == :success

      [root, boom, after_boom] = steps(run.id)
      assert boom.status == :failed

      # `prev` untouched: the reader saw the ROOT's output, not the error.
      assert after_boom.input_data["value"] == "root-after"

      # `parent` untouched: lineage skips the failed stage exactly as a
      # `skip_when` skip does, rather than chaining onto it or resetting to nil.
      assert after_boom.input_step_id == root.id
    end

    test "an uncaught raise inside a stage body still writes a terminal status" do
      # The orphan-run defect this phase exists to close: two orchestrators in
      # the tree have no `rescue` at all and strand their run at `:running`.
      assert_raise RuntimeError, "deliberate", fn -> RaisingBody.run() end

      run = only_run("dsl_raising_uncaught")
      assert run.status == :failed
      assert run.completed_at
    end
  end

  describe "ownership" do
    test "a stage body observes a NON-owning handle" do
      assert {:ok, false} = OwnershipProbe.run()
    end

    test "under returns: :run the handed-back run carries NO completion token" do
      assert {:ok, run} = TwoStages.run()
      assert run.status == :success

      # `Repo.update` carries virtual fields through, so `PipelineRun.complete/2`
      # returns a struct that is still OWNING. Handing that to the caller lets it
      # re-terminate an already-terminal run, which `PipelineRun.fail/2` would
      # accept. `run/1` is where ownership ends.
      refute PipelineRun.owner?(run)
      assert {:error, :not_run_owner} = PipelineRun.fail(run, :caller_clobber)
      assert Config.repo().get!(PipelineRun, run.id).status == :success
    end

    test "the run is nevertheless completed by the generated run/1" do
      {:ok, _} = OwnershipProbe.run()
      assert only_run("dsl_ownership").status == :success
    end
  end

  describe "fan_out with parent: :source_stage (the flat tree)" do
    test "runs the items in order, each parented to the source stage's step log" do
      {:ok, run} = SourceStageFanOut.run()

      [root] = steps_of_type(run.id, "dsl_echo")
      items = steps_of_type(run.id, "dsl_second")

      # EVERY item runs — Phase 4.5.3 removed `gate:` and its skip path, so a
      # fan-out item can no longer be skipped. All three produce a step log
      # (a leftover gate branch would drop one). Rejects a skip-by-gate path.
      assert Enum.map(items, & &1.output_data["value"]) == ["a", "b", "c"]
      assert Enum.map(items, & &1.input_step_id) == [root.id, root.id, root.id]
    end

    test "the step is executed exactly once per item — hooks are never re-applied" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      Process.put(:dsl_echo_counter, counter)
      on_exit(fn -> Process.delete(:dsl_echo_counter) end)

      {:ok, _run} = SourceStageFanOut.run()

      # One root EchoStep. `post_process/2` is not idempotent on two ported
      # steps, so a DSL that re-invoked a step would corrupt their output.
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "fan_out with parent: :per_item (the chain)" do
    test "each item parents to ITS OWN producing step log, and the parents are distinct" do
      {:ok, run} = PerItemFanOut.run()

      all = steps_of_type(run.id, "dsl_second")
      {first_wave, second_wave} = Enum.split(all, 3)

      assert Enum.map(second_wave, & &1.output_data["value"]) == ["a!", "b!", "c!"]

      parents = Enum.map(second_wave, & &1.input_step_id)

      # THE discriminator: under `:source_stage` all three would share one
      # parent, which the `:source_stage` test above cannot tell apart.
      assert Enum.uniq(parents) == parents
      assert parents == Enum.map(first_wave, & &1.id)
    end

    test "`over:` returning unwrapped values under :per_item raises with the fix named" do
      assert_raise ArgumentError, ~r/must carry its own producing step log/, fn ->
        defmodule BadPerItem do
          @moduledoc false
          use ALLM.Pipeline, name: "dsl_bad_per_item"

          alias ALLM.Pipeline.Dsl.RuntimeTest.SecondStep

          fan_out(:one, SecondStep, over: :three, input: :inp)
          fan_out(:two, SecondStep, over: :unwrapped, input: :inp, parent: :per_item)

          defp three(_prev), do: [:a, :b]
          defp unwrapped(items), do: ALLM.Pipeline.Dsl.Item.ok_values(items)
          defp inp(_ctx, _item), do: %SecondStep.Input{value: "x"}
        end

        BadPerItem.run()
      end
    end
  end

  describe "the accumulator" do
    test "round-trips through the body and reaches both metrics and complete/2" do
      # A counter incremented ONLY inside the body and read back from the
      # persisted row. An implementation folding `item_result()` alone reports
      # 0 while every other test in this file still passes.
      assert {:ok, 3} = Counting.run()

      run = only_run("dsl_counting")
      assert run.metadata["counted"] == 3

      [metric] = metric_rows(run.id)
      assert metric.processed == 3
      assert metric.found == 3
      assert metric.entity_type == "things"
    end
  end

  describe "skips" do
    test "a firing skip_when writes NO step log for that stage (D8)" do
      {:ok, run} = SkippingStages.run(skip_middle: true)

      types = Enum.map(steps(run.id), & &1.step_type)
      assert types == ["dsl_echo", "dsl_second"]
    end

    test "a skip is lineage-transparent: the next stage parents to the last EXECUTED step" do
      {:ok, run} = SkippingStages.run(skip_middle: true)
      [first, last] = steps(run.id)

      # A wrong implementation writes `nil` here, or invents a skip row to
      # parent to.
      assert last.input_step_id == first.id
    end

    test "carry survives the skipped stage" do
      {:ok, run} = SkippingStages.run(skip_middle: true)
      [_first, last] = steps(run.id)

      assert last.input_data["value"] == "carried-last"
    end

    test "without the skip, all three stages run" do
      {:ok, run} = SkippingStages.run()
      assert length(steps(run.id)) == 3
    end
  end

  describe "carry" do
    # The fail-open this closes: a declared key the subject does not have was
    # dropped with no error, no log line and no observable difference, so a
    # mistyped `carry:` was indistinguishable from a working one at every later
    # read. User decision 2026-08-21: warn, do not raise — raising would change
    # framework behaviour nothing currently gates.
    test "a carry: key the subject does not have is dropped LOUDLY" do
      log = capture_log(fn -> assert {:ok, _run} = CarryMiss.run() end)

      # All three of the things the caller needs: the key, the stage, the
      # subject's struct. Asserting "some warning was logged" would pass against
      # a message naming none of them.
      assert log =~ "`carry:` declares `:detail_url`"
      assert log =~ "[root]"
      assert log =~ "ALLM.Pipeline.Dsl.RuntimeTest.EchoStep.Output"

      # The present key was still captured, and the absent one still reads as
      # its default — one miss does not abort the fold or fail the run.
      refute log =~ "declares `:value`"
      run = only_run("dsl_carry_miss")
      [_root, reader] = steps(run.id)
      assert reader.input_data["value"] == "kept/nil"
    end
  end

  describe "the escape hatch" do
    test "{:ok, v} is lineage-transparent; {:ok, v, log} moves the parent" do
      {:ok, run} = EscapeHatchLineage.run()

      [root] = steps_of_type(run.id, "dsl_echo")
      [hand_written] = steps_of_type(run.id, "hand_written")
      [after_transparent, after_nominating] = steps_of_type(run.id, "dsl_second")

      # The transparent body left the parent at :root.
      assert after_transparent.input_step_id == root.id

      # The body's own hand-written log received the CURRENT parent — which by
      # then is `:after_transparent`, NOT `:root`, because the transparent stage
      # left the parent where the last EXECUTED step put it. Lineage in is free.
      assert hand_written.input_step_id == after_transparent.id
      assert after_nominating.input_step_id == hand_written.id
    end
  end

  describe "concurrency" do
    test "at concurrency 2, an item whose Step EXITS fails only itself" do
      # `Task.async_stream` links its children, so a `rescue`-only
      # implementation dies with the child and never returns here. An exit is
      # not an exception, so `Executor.run_step/5`'s `rescue` passes it through
      # to the fan-out's always-on `FanOut.guard`.
      assert {:ok, items} = ConcurrentExiting.run()

      assert Enum.map(items, & &1.input) == ["a", "boom", "c"]

      assert [
               {:ok, %{value: "a"}},
               {:error, {:uncaught, :exit, :deliberate}},
               {:ok, %{value: "c"}}
             ] =
               Enum.map(items, & &1.result)

      assert only_run("dsl_concurrent_exit").status == :success
    end
  end

  describe "metrics" do
    test "a pipeline with no `metrics` declaration writes no row" do
      {:ok, _} = NoMetrics.run()
      assert metric_rows(only_run("dsl_no_metrics").id) == []
    end

    test "expects_data?/1 is unaffected — the DSL writes through Metrics.record/3" do
      {:ok, _} = Counting.run()
      [metric] = metric_rows(only_run("dsl_counting").id)
      assert metric.pipeline_name == "dsl_counting"
      assert Metrics.status(metric) == :ok
    end
  end

  describe "Context's widened surface" do
    setup do
      {:ok, run} =
        ALLM.Pipeline.Executor.create_pipeline_run("dsl_context_probe", %{})

      %{run: run}
    end

    test "resource/2 reads the struct field and does NOT fall back to opts", %{run: run} do
      # An implementation taking the shortcut (`Keyword.get(opts, name)`)
      # returns `:sentinel` here and fails the first half.
      empty = Context.new(run, nil, browser: :sentinel)
      assert Context.resource(empty, :browser) == nil

      populated = Context.new(run, nil, resources: %{browser: :handle}, browser: :sentinel)
      assert Context.resource(populated, :browser) == :handle

      # …and the popped keys never reach `get_opt/3`.
      assert Context.get_opt(populated, :resources) == nil
    end

    test "carried/2 returns the captured value", %{run: run} do
      ctx = Context.new(run, nil, carry: %{detail_url: "https://example.test/x"})

      assert Context.carried(ctx, :detail_url) == "https://example.test/x"
      assert Context.carried(ctx, :missing) == nil
      assert Context.carried(ctx, :missing, :fallback) == :fallback
    end

    test "input_step_id/1 returns the explicit parent, else the step log's", %{run: run} do
      {:ok, parent} = ALLM.Pipeline.Executor.log_summary(run, "probe_parent", %{})
      {:ok, child} = ALLM.Pipeline.Executor.log_summary(run, "probe_child", %{}, parent.id)

      explicit = Context.new(run, nil, input_step_id: parent.id)
      assert Context.input_step_id(explicit) == parent.id
      assert Context.step_log_id(explicit) == nil

      from_step = Context.new(run, child, [])
      assert Context.input_step_id(from_step) == parent.id
      assert Context.step_log_id(from_step) == child.id
    end
  end

  describe "Dsl.Item" do
    test "ok_values/1 unwraps and ok_items/1 keeps the wrapper" do
      items = [
        %Item{input: :a, result: {:ok, 1}, step_log: nil},
        %Item{input: :b, result: {:error, :nope}},
        %Item{input: :c, result: {:ok, 3}}
      ]

      assert Item.ok_values(items) == [1, 3]
      assert Enum.map(Item.ok_items(items), & &1.input) == [:a, :c]
    end
  end
end
