defmodule ALLM.Pipeline.Dsl.ResourceTest do
  @moduledoc """
  Pins the `resource` construct: acquisition once per run, the handle reaching
  bodies through `Context.resource/2` rather than `opts`, and — the half the
  construct exists for — teardown running on **every** exit path, catching all
  three kinds, and BEFORE the terminal write (Phase 4 D3).

  DB-backed per `apps/allm_pipeline/CLAUDE.md` §3: D3's ordering discriminator
  is what `PipelineRun.complete/2` actually wrote to the row, which an in-memory
  test cannot observe.

  Counters ride in the process dictionary rather than an `Agent`: every fixture
  here is sequential, so the hooks run in the test's own process, and a
  dictionary counter cannot outlive the test the way a globally-named process
  can (`.work/HANDOFF.md`'s standing flake family).
  """

  use ExUnit.Case, async: true

  import Ecto.Query

  alias ALLM.Pipeline.{Config, Context, FanOut, PipelineRun, StepLog}
  alias ALLM.Pipeline.Dsl.Resource

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  # ── Shared hook bodies ────────────────────────────────────────────────────

  @doc false
  def bump(key) do
    Process.put(key, (Process.get(key) || 0) + 1)
    :ok
  end

  @doc false
  def note(event),
    do: Process.put(:resource_events, (Process.get(:resource_events) || []) ++ [event])

  @doc false
  def events, do: Process.get(:resource_events) || []

  # ── Stub step ─────────────────────────────────────────────────────────────

  # A real Step, not an escape-hatch body: the checklist item is "resources
  # reach STEPS as `Context.resource/2`", and a step's context is built by
  # `Executor.run_step/5` from the opts `Runtime.step_opts/2` hands it — a
  # different path from the one a body takes.
  defmodule HandleStep do
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
    def step_type, do: :resource_handle

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(context, %Input{}) do
      {:ok, %Output{value: inspect(ALLM.Pipeline.Context.resource(context, :handle))}}
    end
  end

  # ── Pipeline fixtures ─────────────────────────────────────────────────────

  defmodule Counting do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_counting", init: :empty

    alias ALLM.Pipeline.Dsl.ResourceTest

    resource(:handle, start: :open, stop: :close)

    # An escape-hatch `stage` body folds three items through `FanOut.reduce/5`
    # (body-mode `fan_out` was removed in 4.5.2). The resource is acquired ONCE
    # per run, and each item's body reads the handle off its own context.
    stage(:items, :see_all)
    summarize(:passthrough)

    defp empty, do: []

    defp see_all(ctx, _prev) do
      {items, _acc} =
        FanOut.reduce(ctx, [:a, :b, :c], [], fn ictx, item, acc ->
          {{:ok, {item, Context.resource(ictx, :handle)}}, acc}
        end)

      {{:ok, items}, items}
    end

    defp open(_ctx) do
      ResourceTest.bump(:resource_starts)
      :the_handle
    end

    defp close(handle) do
      ResourceTest.bump(:resource_stops)
      ResourceTest.note({:closed, handle})
      :ok
    end

    defp passthrough(acc, _ctx), do: acc
  end

  defmodule StepReading do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_step_reading", returns: :run

    alias ALLM.Pipeline.Dsl.ResourceTest.HandleStep

    resource(:handle, start: :open, stop: :close)
    stage(:read, HandleStep, input: :step_input)

    defp open(_ctx), do: :the_handle
    defp close(_h), do: :ok
    defp step_input(_ctx, _prev), do: %HandleStep.Input{value: "x"}
  end

  defmodule Ordered do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_ordered"

    alias ALLM.Pipeline.Dsl.ResourceTest

    resource(:outer, start: :open_outer, stop: :close_outer)
    resource(:inner, start: :open_inner, stop: :close_inner)

    stage(:only, fn ctx, _prev ->
      {:ok, {Context.resource(ctx, :outer), Context.resource(ctx, :inner)}}
    end)

    summarize(:passthrough)

    defp open_outer(_ctx) do
      ResourceTest.note({:start, :outer})
      :outer_handle
    end

    defp open_inner(_ctx) do
      ResourceTest.note({:start, :inner})
      :inner_handle
    end

    defp close_outer(_h), do: ResourceTest.note({:stop, :outer})
    defp close_inner(_h), do: ResourceTest.note({:stop, :inner})
    defp passthrough(acc, ctx), do: {acc, Context.resource(ctx, :outer)}
  end

  defmodule Raising do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_raising"

    alias ALLM.Pipeline.Dsl.ResourceTest

    resource(:handle, start: :open, stop: :close)
    stage(:boom, fn _ctx, _prev -> raise "deliberate" end)

    defp open(_ctx), do: :the_handle
    defp close(_h), do: ResourceTest.bump(:resource_stops)
  end

  defmodule Exiting do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_exiting"

    alias ALLM.Pipeline.Dsl.ResourceTest

    resource(:handle, start: :open, stop: :close)
    stage(:boom, fn _ctx, _prev -> exit(:deliberate) end)

    defp open(_ctx), do: :the_handle
    defp close(_h), do: ResourceTest.bump(:resource_stops)
  end

  defmodule Throwing do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_throwing"

    alias ALLM.Pipeline.Dsl.ResourceTest

    resource(:handle, start: :open, stop: :close)
    stage(:boom, fn _ctx, _prev -> throw(:deliberate) end)

    defp open(_ctx), do: :the_handle
    defp close(_h), do: ResourceTest.bump(:resource_stops)
  end

  defmodule FailingStage do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_failing_stage"

    alias ALLM.Pipeline.Dsl.ResourceTest

    resource(:handle, start: :open, stop: :close)
    stage(:nope, fn _ctx, _prev -> {:error, :deliberate} end)

    defp open(_ctx), do: :the_handle
    defp close(_h), do: ResourceTest.bump(:resource_stops)
  end

  # The D3 pipeline: teardown FAILS, and it fails on the SUCCESS path. Both
  # halves are load-bearing — a wrong implementation either marks the run
  # `:failed` or loses the record entirely.
  defmodule FailingTeardown do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_failing_teardown", complete_metadata: :as_metadata

    resource(:browser, start: :open, stop: :close)
    stage(:work, fn _ctx, _prev -> {{:ok, :done}, :worked} end)
    summarize(:passthrough)

    defp open(_ctx), do: :the_handle
    defp close(_handle), do: raise("teardown blew up")
    defp passthrough(acc, _ctx), do: acc
    defp as_metadata(acc), do: %{"acc" => to_string(acc)}
  end

  defmodule ExitingTeardown do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_exiting_teardown"

    resource(:browser, start: :open, stop: :close)
    stage(:work, fn _ctx, _prev -> {:ok, :done} end)

    defp open(_ctx), do: :the_handle
    # A Playwright / GenServer teardown surfaces as an EXIT, not an exception —
    # the reason D3 requires `catch kind, reason` rather than `rescue`.
    defp close(_handle), do: exit(:browser_gone)
  end

  # Teardown fails on the FAILING path. The two terminal writers offer different
  # metadata channels (`complete/2` takes an argument, `fail_pipeline_run/2`
  # does not), so this direction is a genuinely separate code path from the
  # success one above — not a second spelling of it.
  defmodule FailingBoth do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_failing_both"

    resource(:browser, start: :open, stop: :close)
    stage(:nope, fn _ctx, _prev -> {:error, :stage_failed} end)

    defp open(_ctx), do: :the_handle
    defp close(_handle), do: raise("teardown blew up too")
  end

  defmodule FailingStart do
    @moduledoc false
    use ALLM.Pipeline, name: "resource_failing_start"

    alias ALLM.Pipeline.Dsl.ResourceTest

    resource(:first, start: :open_first, stop: :close_first)
    resource(:second, start: :open_second, stop: :close_second)
    stage(:never, fn _ctx, _prev -> {:ok, ResourceTest.bump(:resource_stage_ran)} end)

    defp open_first(_ctx) do
      ResourceTest.note({:start, :first})
      :first_handle
    end

    defp open_second(_ctx), do: raise("cannot open")
    defp close_first(_h), do: ResourceTest.note({:stop, :first})
    defp close_second(_h), do: ResourceTest.note({:stop, :second})
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp only_run(name), do: from(r in PipelineRun, where: r.name == ^name) |> Config.repo().one!()

  defp steps(run_id) do
    from(s in StepLog, where: s.pipeline_run_id == ^run_id) |> Config.repo().all()
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "acquisition" do
    test "starts ONCE per run, not once per fan-out item" do
      assert {:ok, items} = Counting.run()
      assert length(items) == 3

      # A per-item implementation reports 3 here and every other assertion in
      # this file still passes.
      assert Process.get(:resource_starts) == 1
      assert Process.get(:resource_stops) == 1
    end

    test "the handle a body sees is the one `start` returned" do
      {:ok, items} = Counting.run()

      assert Enum.map(items, & &1.result) == [
               ok: {:a, :the_handle},
               ok: {:b, :the_handle},
               ok: {:c, :the_handle}
             ]
    end

    test "a STEP reads the handle off its own context, not out of opts" do
      assert {:ok, run} = StepReading.run()

      # A step's context is built by `Executor.run_step/5` from the opts
      # `Runtime.step_opts/2` supplies, then popped onto the struct field by
      # `Context.new/3` — a different path from the one a body takes, and the
      # one the checklist item names.
      assert [step] = steps(run.id)
      assert step.output_data["value"] == ":the_handle"
      refute step.input_data["resources"]
    end

    test "several resources start in declaration order and stop in REVERSE" do
      assert {:ok, {_acc, :outer_handle}} = Ordered.run()

      assert events() == [
               {:start, :outer},
               {:start, :inner},
               {:stop, :inner},
               {:stop, :outer}
             ]
    end

    test "a `start` that raises releases what was already acquired, and no stage runs" do
      assert_raise RuntimeError, "cannot open", fn -> FailingStart.run() end

      # `:second` never started, so it is never stopped — and `:first` did, so
      # it is. An implementation that lost the partial map leaks exactly the
      # handles the construct exists to manage.
      assert events() == [{:start, :first}, {:stop, :first}]
      assert is_nil(Process.get(:resource_stage_ran))

      run = only_run("resource_failing_start")
      assert run.status == :failed
      assert run.completed_at
    end
  end

  describe "Context.resource/2 reads the struct field, not opts (criterion 2)" do
    test "an `opts` key of the same name is NOT a resource" do
      ctx = Context.new(nil, nil, browser: :sentinel)

      # The grep that looks like this criterion cannot fire: a framework taking
      # the shortcut would write `Keyword.get(opts, name)`, and `:browser` is a
      # host-side name the package can never write literally. So assert it.
      assert Context.resource(ctx, :browser) == nil
      assert Context.get_opt(ctx, :browser) == :sentinel
    end

    test "a populated resources map answers with the handle" do
      ctx = Context.new(nil, nil, browser: :sentinel, resources: %{browser: :real_handle})

      assert Context.resource(ctx, :browser) == :real_handle
    end
  end

  describe "teardown runs on every exit path" do
    test "on the success path" do
      {:ok, _items} = Counting.run()
      assert Process.get(:resource_stops) == 1
    end

    test "when a stage RAISES" do
      assert_raise RuntimeError, "deliberate", fn -> Raising.run() end

      assert Process.get(:resource_stops) == 1
      assert only_run("resource_raising").status == :failed
    end

    test "when a stage EXITS" do
      # `try/after` catches all three, but a `rescue`-based implementation
      # catches only the first — and a Playwright teardown is an exit.
      assert catch_exit(Exiting.run()) == :deliberate

      assert Process.get(:resource_stops) == 1
      assert only_run("resource_exiting").status == :failed
    end

    test "when a stage THROWS" do
      assert catch_throw(Throwing.run()) == :deliberate

      assert Process.get(:resource_stops) == 1
      assert only_run("resource_throwing").status == :failed
    end

    test "when a stage fails with on_error: :fail_run" do
      assert {:error, :deliberate} = FailingStage.run()

      assert Process.get(:resource_stops) == 1
      assert only_run("resource_failing_stage").status == :failed
    end
  end

  describe "teardown ordering and failure recording (D3)" do
    test "a `stop` that RAISES leaves the run :success and records the resource by name" do
      assert {:ok, :worked} = FailingTeardown.run()

      run = only_run("resource_failing_teardown")

      # The status is about the WORK. A leaked handle is an operational fault
      # recorded beside it — a wrong implementation marks this `:failed`.
      assert run.status == :success
      assert run.metadata["acc"] == "worked"

      assert [%{"resource" => "browser", "kind" => "error", "reason" => reason}] =
               run.metadata["resource_teardown_errors"]

      assert reason =~ "teardown blew up"
    end

    test "a `stop` that EXITS is recorded the same way" do
      # No `summarize`, so `run/1` returns the accumulator — the default `%{}`.
      assert {:ok, %{}} = ExitingTeardown.run()

      run = only_run("resource_exiting_teardown")
      assert run.status == :success

      assert [%{"resource" => "browser", "kind" => "exit", "reason" => ":browser_gone"}] =
               run.metadata["resource_teardown_errors"]
    end

    test "the record is in the metadata `complete/2` WROTE, which is only possible before it" do
      {:ok, :worked} = FailingTeardown.run()

      # The ordering discriminator. Teardown after the terminal write could not
      # put anything in this row: it is already terminal, and the owning handle
      # has been spent. Read back from the DATABASE, not from the returned
      # struct, so an in-memory merge that never reached Postgres fails here.
      run = only_run("resource_failing_teardown")
      assert run.completed_at
      assert run.metadata["resource_teardown_errors"]
    end

    test "a teardown failure on the FAILING path is recorded beside the error" do
      assert {:error, :stage_failed} = FailingBoth.run()

      run = only_run("resource_failing_both")

      # Status still reflects the WORK's failure, and both records survive.
      assert run.status == :failed
      assert run.metadata["error"]

      assert [%{"resource" => "browser", "kind" => "error"}] =
               run.metadata["resource_teardown_errors"]
    end

    test "a clean teardown writes NO resource_teardown_errors key" do
      {:ok, _items} = Counting.run()

      run = only_run("resource_counting")
      refute Map.has_key?(run.metadata, "resource_teardown_errors")
    end
  end

  describe "a pipeline that declares no resource is unaffected" do
    test "no resources, no teardown key, and the run still completes" do
      defmodule Bare do
        @moduledoc false
        use ALLM.Pipeline, name: "resource_bare"
        stage(:only, fn _ctx, _prev -> {:ok, :done} end)
      end

      # No `summarize`: the return is the accumulator, not the stage's value.
      assert {:ok, %{}} = Bare.run()
      assert Bare.__pipeline__(:resources) == []

      run = only_run("resource_bare")
      assert run.status == :success
      refute Map.has_key?(run.metadata, "resource_teardown_errors")
      assert steps(run.id) == []
    end
  end

  describe "ALLM.Pipeline.Dsl.Resource directly" do
    test "release/2 skips a declaration whose start never ran" do
      declared = [
        %Resource{name: :a, start: fn _ctx -> :a end, stop: fn _h -> note({:stop, :a}) end},
        %Resource{name: :b, start: fn _ctx -> :b end, stop: fn _h -> note({:stop, :b}) end}
      ]

      assert Resource.release(declared, %{a: :a}) == []
      assert events() == [{:stop, :a}]
    end

    test "acquire/2 on an empty declaration list does nothing at all" do
      assert Resource.acquire([], Context.detached()) == {%{}, :ok}
      assert Resource.release([], %{}) == []
    end

    test "acquire/2 reports the kind so the caller can re-raise it unchanged" do
      declared = [%Resource{name: :a, start: fn _ctx -> exit(:nope) end, stop: fn _h -> :ok end}]

      assert {%{}, {:raised, :exit, :nope, _stack}} =
               Resource.acquire(declared, Context.detached())
    end
  end

  describe "compile-time validation" do
    test "both start: and stop: are required" do
      assert_raise ArgumentError, ~r/requires `stop:`/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"
                    resource :h, start: :open
                    stage :s, fn _c, _p -> {:ok, 1} end
                    defp open(_ctx), do: :h|)
      end

      assert_raise ArgumentError, ~r/requires `start:`/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"
                    resource :h, stop: :close
                    stage :s, fn _c, _p -> {:ok, 1} end
                    defp close(_h), do: :ok|)
      end
    end

    test "an unknown resource option is rejected by name" do
      assert_raise ArgumentError, ~r/unknown `resource :h` option\(s\) \[:timeout\]/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"
                    resource :h, start: :open, stop: :close, timeout: 1
                    stage :s, fn _c, _p -> {:ok, 1} end
                    defp open(_ctx), do: :h
                    defp close(_h), do: :ok|)
      end
    end

    test "a duplicate resource name is a compile error" do
      assert_raise ArgumentError, ~r/duplicate resource name\(s\) \[:h\]/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"
                    resource :h, start: :open, stop: :close
                    resource :h, start: :open, stop: :close
                    stage :s, fn _c, _p -> {:ok, 1} end
                    defp open(_ctx), do: :h
                    defp close(_h), do: :ok|)
      end
    end

    test "a start: hook the module does not define is a compile error" do
      assert_raise ArgumentError, ~r/names open\/1, which this module does not define/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"
                    resource :h, start: :open, stop: :close
                    stage :s, fn _c, _p -> {:ok, 1} end
                    defp close(_h), do: :ok|)
      end
    end
  end

  # Throwaway modules under unique names: a reused name is a redefinition, and
  # the second run would observe the FIRST module.
  defp compile!(body) do
    Code.eval_string("""
    defmodule Probe#{System.unique_integer([:positive])} do
    #{body}
    end
    """)
  end
end
