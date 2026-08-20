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

  alias ALLM.Pipeline.{Config, Context, Metrics, PipelineMetric, PipelineRun, StepLog}
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
    fan_out(:items, SecondStep, over: :three, input: :item_input, section: :title)

    defp root_input(_ctx, _prev), do: %EchoStep.Input{value: "root"}
    defp three(_prev), do: ["a", "b", "c"]
    defp item_input(_ctx, item), do: %SecondStep.Input{value: item}
    defp title(item), do: "section #{item}"
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

    fan_out(:items, over: :three, body: :count_one)
    metrics("things", from: :funnel)
    summarize(:passthrough)

    defp zero, do: 0
    defp three(_prev), do: [:a, :b, :c]

    # The accumulator's ONLY write channel is this second element. The value it
    # increments is read back off the context, which is what makes the channel
    # a round trip rather than a write-only sink.
    defp count_one(ctx, item), do: {{:ok, item}, Context.accumulator(ctx) + 1}

    defp funnel(summary), do: %{found: 3, processed: summary}
    defp passthrough(acc, _ctx), do: acc
    defp as_metadata(acc), do: %{counted: acc}
  end

  defmodule SkippingStages do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_skipping", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeTest.{EchoStep, SecondStep}

    stage(:first, EchoStep, input: :first_input, carry: [:value])
    stage(:middle, SecondStep, input: :middle_input, skip_when: {:opt, :skip_middle})
    stage(:last, SecondStep, input: :last_input)

    defp first_input(_ctx, _prev), do: %EchoStep.Input{value: "carried"}
    defp middle_input(_ctx, prev), do: %SecondStep.Input{value: prev.value}

    # Reads the CARRIED value, not `prev` — that is the assertion the skipped
    # middle stage would break if `carry` lived on a step log.
    defp last_input(ctx, _prev),
      do: %SecondStep.Input{value: Context.carried(ctx, :value) <> "-last"}
  end

  # `carry:` has DIFFERENT scope on the two kinds, and both directions are
  # declared here so one fixture pins both: `:root`'s capture (a `stage`) must
  # reach `:reader` three stages later, and `:items`' capture (a `fan_out`) must
  # reach its own item and NOT `:reader`.
  defmodule CarryScopes do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_carry_scopes", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeTest.{EchoStep, SecondStep}

    stage(:root, EchoStep, input: :root_input, carry: [:value])
    fan_out(:items, SecondStep, over: :two, input: :item_input, carry: [:token])
    stage(:reader, SecondStep, input: :reader_input)

    defp root_input(_ctx, _prev), do: %EchoStep.Input{value: "from-stage"}
    defp two(_prev), do: [%{token: "T1"}, %{token: "T2"}]

    # Reads the ITEM's own carry, never the item — a body that read `item.token`
    # would pass whether or not the fan-out captured anything.
    defp item_input(ctx, _item), do: %SecondStep.Input{value: Context.carried(ctx, :token)}

    defp reader_input(ctx, _prev),
      do: %SecondStep.Input{
        value: "#{Context.carried(ctx, :value)}/#{inspect(Context.carried(ctx, :token))}"
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

    fan_out(:items, over: :three, body: :maybe_exit, concurrency: 2)

    # A `fan_out`'s output is its `[Dsl.Item.t()]`, which `summarize` (taking
    # `(acc, ctx)`) cannot see — so a following sequential escape hatch moves it
    # onto the accumulator. Sequential, so the fold order is defined.
    stage(:collect, fn _ctx, items -> {{:ok, items}, items} end)

    summarize(:passthrough)

    defp three(_prev), do: [:a, :boom, :c]
    defp maybe_exit(_ctx, :boom), do: exit(:deliberate)
    defp maybe_exit(_ctx, item), do: {:ok, item}
    defp passthrough(acc, _ctx), do: acc
  end

  defmodule ConcurrentFolding do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_concurrent_folding", init: :zero

    fan_out(:items, over: :three, body: :fold, concurrency: 2)

    defp zero, do: 0
    defp three(_prev), do: [:a, :b, :c]
    defp fold(_ctx, item), do: {{:ok, item}, 1}
  end

  defmodule RaisingUncaught do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_raising_uncaught"

    fan_out(:items, over: :three, body: :maybe_raise)

    defp three(_prev), do: [:a, :boom, :c]
    defp maybe_raise(_ctx, :boom), do: raise("deliberate")
    defp maybe_raise(_ctx, item), do: {:ok, item}
  end

  defmodule RaisingCaught do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_raising_caught", init: :empty

    fan_out(:items, over: :three, body: :maybe_raise, catch_item_failures: true)
    stage(:collect, fn _ctx, items -> {{:ok, items}, items} end)
    summarize(:passthrough)

    defp empty, do: []
    defp three(_prev), do: [:a, :boom, :c]
    defp maybe_raise(_ctx, :boom), do: raise("deliberate")
    defp maybe_raise(_ctx, item), do: {:ok, item}

    defp passthrough(acc, _ctx), do: acc
  end

  defmodule GatedFanOut do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_gated", init: :empty

    fan_out(:items, over: :three, gate: :decide, body: :record)
    summarize(:passthrough)

    defp empty, do: []
    defp three(_prev), do: [:a, :b, :c]
    defp decide(:b, _opts), do: %{should_process: false, reason: :not_due}
    defp decide(_item, _opts), do: %{should_process: true, reason: nil, actions: [:full]}

    defp record(ctx, item),
      do: {{:ok, item}, [Context.carried(ctx, :gate).actions | Context.accumulator(ctx)]}

    defp passthrough(acc, _ctx), do: acc
  end

  defmodule Delaying do
    @moduledoc false
    use ALLM.Pipeline, name: "dsl_delaying", init: :empty

    fan_out(:items,
      over: :three,
      body: :maybe_ok,
      delay: [ms: {:opt, :delay_ms, 0}, when: :processed]
    )

    summarize(:passthrough)

    defp empty, do: []
    defp three(_prev), do: [:ok_one, :skip_me, :ok_two]
    defp maybe_ok(_ctx, :skip_me), do: {:skipped, :not_due}
    defp maybe_ok(_ctx, item), do: {:ok, item}
    defp passthrough(acc, _ctx), do: acc
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

    test "an uncaught raise inside a fan-out body still writes a terminal status" do
      # The orphan-run defect this phase exists to close: two orchestrators in
      # the tree have no `rescue` at all and strand their run at `:running`.
      assert_raise RuntimeError, "deliberate", fn -> RaisingUncaught.run() end

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

      assert Enum.map(items, & &1.output_data["value"]) == ["a", "b", "c"]
      assert Enum.map(items, & &1.input_step_id) == [root.id, root.id, root.id]
    end

    test "section: is a SIBLING of the items, never their ancestor" do
      {:ok, run} = SourceStageFanOut.run()

      [root] = steps_of_type(run.id, "dsl_echo")
      sections = steps_of_type(run.id, "section")
      items = steps_of_type(run.id, "dsl_second")

      assert length(sections) == 3
      assert Enum.map(sections, & &1.input_step_id) == [root.id, root.id, root.id]

      section_ids = MapSet.new(sections, & &1.id)

      for item <- items do
        refute MapSet.member?(section_ids, item.input_step_id),
               "an item's steps parented to the SECTION row; every edge under the fan-out " <>
                 "would move and the identity gate would fail."
      end
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

          fan_out(:one, over: :three, body: :pass)
          fan_out(:two, over: :unwrapped, body: :pass, parent: :per_item)

          defp three(_prev), do: [:a, :b]
          defp unwrapped(items), do: ALLM.Pipeline.Dsl.Item.ok_values(items)
          defp pass(_ctx, item), do: {:ok, item}
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

    test "a body returning a bare item result leaves it untouched" do
      assert {:ok, []} = Delaying.run()
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
    # Both directions in one run, because the two are only distinguishable
    # together: an implementation that never captures a fan-out's carry passes
    # the second assertion, and one that writes it back into the pipeline state
    # passes the first.
    test "a fan_out's carry reaches its OWN item and is not propagated past the stage" do
      {:ok, run} = CarryScopes.run()
      [_root, item_a, item_b, reader] = steps(run.id)

      # Item-scoped capture DID reach the item's own `input:`.
      assert item_a.input_data["value"] == "T1"
      assert item_b.input_data["value"] == "T2"

      # …and did NOT survive the stage, while the plain stage's carry did.
      assert reader.input_data["value"] == "from-stage/nil"
    end
  end

  describe "gate" do
    test "a failing gate skips the item silently and binds the decision for the rest" do
      assert {:ok, actions} = GatedFanOut.run()

      # `:b` was gated out; `:a` and `:c` each pushed their decision's actions.
      assert actions == [[:full], [:full]]
      run = only_run("dsl_gated")
      assert steps_of_type(run.id, "section") == []
      assert run.status == :success
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
    test "at concurrency 2, an item that EXITS fails only itself" do
      # `Task.async_stream` links its children, so a `rescue`-only
      # implementation dies with the child and never returns here.
      assert {:ok, items} = ConcurrentExiting.run()

      assert Enum.map(items, & &1.input) == [:a, :boom, :c]

      assert [{:ok, :a}, {:error, {:uncaught, :exit, :deliberate}}, {:ok, :c}] =
               Enum.map(items, & &1.result)

      assert only_run("dsl_concurrent_exit").status == :success
    end

    test "a concurrent fan_out whose body folds the accumulator raises, naming the fix" do
      assert_raise ArgumentError, ~r/do not compose — the fold order is undefined/, fn ->
        ConcurrentFolding.run()
      end
    end
  end

  describe "per-item failures" do
    test "are NOT caught by default — the raise fails the whole run" do
      assert_raise RuntimeError, "deliberate", fn -> RaisingUncaught.run() end
      assert only_run("dsl_raising_uncaught").status == :failed
    end

    test "with catch_item_failures: true, only that item fails and the run completes" do
      assert {:ok, items} = RaisingCaught.run()

      assert Enum.map(items, & &1.input) == [:a, :boom, :c]

      assert [{:ok, :a}, {:error, {:uncaught, :error, %RuntimeError{}}}, {:ok, :c}] =
               Enum.map(items, & &1.result)

      assert only_run("dsl_raising_caught").status == :success
    end
  end

  describe "delay" do
    test "when: :processed sleeps only after a successful item" do
      started = System.monotonic_time(:millisecond)
      assert {:ok, _} = Delaying.run(delay_ms: 100)
      elapsed = System.monotonic_time(:millisecond) - started

      # Three items, two of them `{:ok, _}` — so TWO sleeps, not three. Both
      # bounds are load-bearing: the floor rejects `when: :never`, and the
      # ceiling (one sleep below three, with a 90ms margin) rejects
      # `when: :always`, which is `meeting_summary`'s divergent fifth rule.
      assert elapsed >= 190, "expected two 100ms sleeps, saw #{elapsed}ms"
      assert elapsed < 290, "expected two 100ms sleeps, not three; saw #{elapsed}ms"
    end

    test "ms resolves from opts, and 0 means no sleep" do
      started = System.monotonic_time(:millisecond)
      assert {:ok, _} = Delaying.run()
      assert System.monotonic_time(:millisecond) - started < 100
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
