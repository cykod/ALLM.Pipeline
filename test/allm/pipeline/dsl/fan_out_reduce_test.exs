defmodule ALLM.Pipeline.FanOutReduceTest do
  @moduledoc """
  Behavioural pins for `ALLM.Pipeline.FanOut.reduce/5` — the function form of a
  `body:`-mode `fan_out` (Phase 4.5.1). A DISTINCT module from
  `ALLM.Pipeline.FanOutTest`, which machine-guards the `Task.async_stream` site
  set; `reduce/5` adds none (it is sequential-only) so that guard stays green.

  DB-backed, per `apps/allm_pipeline/CLAUDE.md` §3: the lineage assertions
  observe real `step_logs` rows, so an in-memory test of them would see nothing.

  Each test names the wrong implementation it rejects.
  """

  use ExUnit.Case, async: true

  alias ALLM.Pipeline.{Config, Context, Executor, StepLog}
  alias ALLM.Pipeline.Dsl.Item
  alias ALLM.Pipeline.FanOut

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  defp new_run(name) do
    {:ok, run} = Executor.create_pipeline_run(name, %{})
    run
  end

  describe "the fold" do
    test "runs items in order and threads the accumulator LEFT-to-RIGHT" do
      ctx = Context.new(new_run("reduce_fold"), nil, [])

      # A list acc that each body PREPENDS to: a left-to-right fold ends
      # reversed, so `[:c, :b, :a]` proves order AND that the acc round-trips.
      fun = fn _ctx, item, acc -> {{:ok, item}, [item | acc]} end

      {items, acc} = FanOut.reduce(ctx, [:a, :b, :c], [], fun, [])

      assert Enum.map(items, & &1.input) == [:a, :b, :c]
      assert Enum.map(items, & &1.result) == [ok: :a, ok: :b, ok: :c]
      # Rejects a reduce that folds right-to-left (`[:a, :b, :c]`) or drops the
      # acc (`[]`).
      assert acc == [:c, :b, :a]
    end

    test "a body returning a bare item result still threads its acc unchanged" do
      ctx = Context.new(new_run("reduce_keep"), nil, [])
      fun = fn _ctx, item, acc -> {{:ok, item}, acc} end

      {items, acc} = FanOut.reduce(ctx, [1, 2], :untouched, fun, [])

      assert Enum.map(items, & &1.result) == [ok: 1, ok: 2]
      assert acc == :untouched
    end
  end

  describe "link-safe catch (an exit is not an exception)" do
    for {kind, thrower, expected} <- [
          {:raise, quote(do: raise("kaboom")),
           quote(do: {:uncaught, :error, %RuntimeError{message: "kaboom"}})},
          {:exit, quote(do: exit(:deliberate)), quote(do: {:uncaught, :exit, :deliberate})},
          {:throw, quote(do: throw(:ball)), quote(do: {:uncaught, :throw, :ball})}
        ] do
      test "an uncaught #{kind} degrades only that item and preserves the acc" do
        ctx = Context.new(new_run("reduce_#{unquote(kind)}"), nil, [])

        fun = fn _ctx, item, acc ->
          case item do
            :boom -> unquote(thrower)
            _ -> {{:ok, item}, acc + 1}
          end
        end

        {[a, boom, c], acc} = FanOut.reduce(ctx, [:a, :boom, :c], 0, fun, [])

        assert a.result == {:ok, :a}
        assert c.result == {:ok, :c}
        # Rejects a wrapper that lets the failure kill the fold …
        assert {:error, unquote(expected)} = boom.result
        # … and one that folds the failing item's (absent) acc: only :a and :c
        # incremented the counter.
        assert acc == 2
      end
    end
  end

  describe "the producing step log" do
    test "a 3-tuple item result carries it onto the Item; a 2-tuple leaves it nil" do
      ctx = Context.new(new_run("reduce_steplog"), nil, [])

      fun = fn ictx, item, acc ->
        case item do
          :with_log ->
            {:ok, log} =
              Executor.log_summary(ictx.pipeline_run, "probe", %{}, Context.input_step_id(ictx))

            {{:ok, item, log}, acc}

          _ ->
            {{:ok, item}, acc}
        end
      end

      {[with_log, plain], _acc} = FanOut.reduce(ctx, [:with_log, :plain], nil, fun, [])

      # Rejects dropping step_log onto every item or none.
      assert %StepLog{} = with_log.step_log
      assert plain.step_log == nil
    end
  end

  describe "parent: :per_item" do
    test "re-parents each item's context to its OWN producing step log" do
      run = new_run("reduce_per_item")
      {:ok, log_a} = Executor.log_summary(run, "wave1_a", %{})
      {:ok, log_b} = Executor.log_summary(run, "wave1_b", %{})

      items_in = [
        %Item{input: :a, result: {:ok, :a}, step_log: log_a},
        %Item{input: :b, result: {:ok, :b}, step_log: log_b}
      ]

      # The source parent is deliberately DIFFERENT from either item's log, so a
      # :source_stage implementation would return that instead and fail.
      ctx = Context.new(run, nil, input_step_id: nil)

      fun = fn ictx, _item, acc ->
        {{:ok, Context.input_step_id(ictx)}, acc}
      end

      {items, _acc} = FanOut.reduce(ctx, items_in, nil, fun, parent: :per_item)

      # Rejects :source_stage behaviour under a :per_item declaration.
      assert Enum.map(items, & &1.result) == [ok: log_a.id, ok: log_b.id]
    end

    test "a non-%Item{} input raises the ok_items/1 message" do
      ctx = Context.new(new_run("reduce_bad_per_item"), nil, [])
      fun = fn _ctx, item, acc -> {{:ok, item}, acc} end

      assert_raise ArgumentError, ~r/ok_items/, fn ->
        FanOut.reduce(ctx, [:not_an_item], nil, fun, parent: :per_item)
      end
    end
  end

  describe "parent: :source_stage (the default)" do
    test "hangs every item's steps off Context.input_step_id" do
      run = new_run("reduce_source_stage")
      {:ok, root} = Executor.log_summary(run, "root", %{})
      ctx = Context.new(run, nil, input_step_id: root.id)

      # Each body runs a real step under the parent it was handed, and reports
      # back the input_step_id the row actually persisted.
      fun = fn ictx, item, acc ->
        {:ok, log} =
          Executor.log_summary(
            ictx.pipeline_run,
            "child_#{item}",
            %{},
            Context.input_step_id(ictx)
          )

        {{:ok, log.input_step_id}, acc}
      end

      {items, _acc} = FanOut.reduce(ctx, [1, 2, 3], nil, fun, parent: :source_stage)

      # Rejects per-item re-parenting under the default: all three share the one
      # source parent.
      assert Enum.map(items, & &1.result) == [ok: root.id, ok: root.id, ok: root.id]
    end
  end
end
