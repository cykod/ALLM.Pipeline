defmodule ALLM.Pipeline.Dsl.RunModesTest do
  @moduledoc """
  Pins the two constructs that change WHICH run a declaration executes under, or
  whether it executes at all: `borrowed_run:` and the framework's `--dry-run`.

  (Phase 5.10 removed `child_pipeline`, which this file also covered — its
  parent_run_id lift is now regression-covered directly by
  `runtime_test.exs`'s "self-owned parent_run_id lift".)
  """

  use ExUnit.Case, async: true

  import Ecto.Query

  alias ALLM.Pipeline.{Config, Context, Executor, PipelineMetric, PipelineRun, StepLog}

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  # ── Stub step ─────────────────────────────────────────────────────────────

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
    def step_type, do: :run_modes_echo

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_context, %Input{value: value}), do: {:ok, %Output{value: value}}
  end

  # ── borrowed_run ──────────────────────────────────────────────────────────

  defmodule Inner do
    @moduledoc false
    use ALLM.Pipeline,
      name: "run_modes_inner",
      borrowed_run: true,
      init: :zero,
      complete_metadata: :as_metadata

    alias ALLM.Pipeline.Dsl.RunModesTest.EchoStep

    stage(:echo, EchoStep, input: :echo_input)

    # The assertion that actually fails before the ownership guard: a body able
    # to complete its own parent run would stamp the umbrella `:success`
    # mid-loop. Here it must be refused, and the refusal recorded.
    #
    # `Process.put/2` is how the test OBSERVES the refusal value. `:probe` is the
    # last stage, so its `prev` reaches no later stage and the accumulator is an
    # integer four other tests assert on — there is no return channel out. This
    # pipeline runs at the default concurrency 1 and a plain `stage` runs inline,
    # so this is the test's own process dictionary. Before this existed the
    # comment above claimed the return value was the refusal and nothing read it
    # (code review 4.3 F10).
    stage(:probe, fn ctx, _prev ->
      refusal = PipelineRun.complete(ctx.pipeline_run, %{clobbered: true})
      Process.put(:run_modes_probe_refusal, refusal)
      {{:ok, refusal}, Context.accumulator(ctx) + 1}
    end)

    metrics("inner_things", from: :funnel)
    summarize(:passthrough)

    defp zero, do: 0
    defp echo_input(ctx, _prev), do: %EchoStep.Input{value: Context.get_opt(ctx, :label, "x")}
    defp funnel(acc), do: %{found: acc, processed: acc}
    defp passthrough(acc, _ctx), do: acc
    defp as_metadata(acc), do: %{"counted" => acc}
  end

  # ── dry_run ───────────────────────────────────────────────────────────────

  defmodule Dryable do
    @moduledoc false
    use ALLM.Pipeline, name: "run_modes_dryable", dry_run: :plan

    alias ALLM.Pipeline.Dsl.RunModesTest.EchoStep

    stage(:external, EchoStep, input: :echo_input)
    summarize(:passthrough)

    # Resolving the working set is the plan hook's job — it runs BEFORE the
    # first stage, so nothing external has happened yet.
    defp plan(ctx), do: %{"would_process" => Context.get_opt(ctx, :count, 7)}
    defp echo_input(_ctx, _prev), do: %EchoStep.Input{value: "external call"}
    defp passthrough(acc, _ctx), do: acc
  end

  defmodule NotDryable do
    @moduledoc false
    use ALLM.Pipeline, name: "run_modes_not_dryable"

    alias ALLM.Pipeline.Dsl.RunModesTest.EchoStep

    stage(:external, EchoStep, input: :echo_input)

    defp echo_input(_ctx, _prev), do: %EchoStep.Input{value: "ran anyway"}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp only_run(name), do: from(r in PipelineRun, where: r.name == ^name) |> Config.repo().one!()

  defp steps(run_id) do
    from(s in StepLog, where: s.pipeline_run_id == ^run_id, order_by: [asc: s.started_at])
    |> Config.repo().all()
  end

  defp metric_rows(run_id) do
    from(m in PipelineMetric, where: m.pipeline_run_id == ^run_id) |> Config.repo().all()
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "borrowed_run" do
    test "runs under the umbrella's run, writes its step logs there, and completes nothing" do
      {:ok, umbrella} = Executor.create_pipeline_run("run_modes_umbrella")

      assert {:ok, 1} = Inner.run(pipeline_run: umbrella, label: "first")

      # THE assertion — asserted BETWEEN inner invocations, because the
      # umbrella's own later `complete/2` overwrites the end state and makes
      # the same assertion non-falsifying afterwards.
      mid = Config.repo().get!(PipelineRun, umbrella.id)
      assert mid.status == :running
      assert is_nil(mid.completed_at)

      assert {:ok, 1} = Inner.run(pipeline_run: umbrella, label: "second")

      mid2 = Config.repo().get!(PipelineRun, umbrella.id)
      assert mid2.status == :running
      assert is_nil(mid2.completed_at)

      # Both invocations' steps landed on the UMBRELLA run.
      assert Enum.map(steps(umbrella.id), & &1.input_data["value"]) == ["first", "second"]

      # And no inner run was ever created.
      assert Config.repo().all(from(r in PipelineRun, where: r.name == "run_modes_inner")) == []
    end

    test "a body's attempt to complete the borrowed run is refused, not silently honoured" do
      {:ok, umbrella} = Executor.create_pipeline_run("run_modes_umbrella")

      {:ok, _acc} = Inner.run(pipeline_run: umbrella)

      # The REFUSAL VALUE, not merely its absence of effect. `complete/2` on a
      # borrowed handle must return `{:error, :not_run_owner}` — a silent
      # no-op would satisfy both assertions below just as well.
      assert Process.get(:run_modes_probe_refusal) == {:error, :not_run_owner}

      [_echo] = steps(umbrella.id)
      assert Config.repo().get!(PipelineRun, umbrella.id).status == :running
    end

    test "records NO pipeline_metrics row under a borrowed run" do
      {:ok, umbrella} = Executor.create_pipeline_run("run_modes_umbrella")
      {:ok, _acc} = Inner.run(pipeline_run: umbrella)

      # The funnel would otherwise be attributed to the umbrella's run and
      # double-count against whatever the umbrella records itself.
      assert metric_rows(umbrella.id) == []
    end

    test "without a lent run the same pipeline is self-owned and completes normally" do
      assert {:ok, 1} = Inner.run(label: "solo")

      run = only_run("run_modes_inner")
      assert run.status == :success
      assert run.completed_at
      # Self-owned, so the metrics row IS written.
      assert [%PipelineMetric{}] = metric_rows(run.id)
    end

    test "a pipeline that does NOT declare borrowed_run ignores a lent run entirely" do
      {:ok, umbrella} = Executor.create_pipeline_run("run_modes_umbrella")

      # Consulting `Executor.borrowed_run/1` unconditionally would make a stray
      # `:pipeline_run` opt silently change every pipeline's lifecycle.
      assert {:ok, _} = NotDryable.run(pipeline_run: umbrella)

      own = only_run("run_modes_not_dryable")
      assert own.status == :success
      assert steps(umbrella.id) == []
    end
  end

  describe "--dry-run" do
    test "completes the run and makes ZERO run_step calls" do
      assert {:ok, %{"would_process" => 7}} = Dryable.run(dry_run: true)

      run = only_run("run_modes_dryable")
      assert run.status == :success
      assert run.completed_at

      # Only the summary row. The stage's Step never ran, so its step type is
      # absent — which is what "before the first external call" means here.
      assert [summary] = steps(run.id)
      assert summary.step_type == "dry_run"
      assert summary.output_data["would_process"] == 7
      refute Enum.any?(steps(run.id), &(&1.step_type == "run_modes_echo"))
    end

    test "the plan reaches the run's metadata, flagged" do
      {:ok, _plan} = Dryable.run(dry_run: true)

      run = only_run("run_modes_dryable")
      assert run.metadata["dry_run"] == true
      assert run.metadata["would_process"] == 7
    end

    test "without --dry-run the same pipeline runs its stages" do
      assert {:ok, _} = Dryable.run(count: 99)

      run = only_run("run_modes_dryable")
      assert Enum.map(steps(run.id), & &1.step_type) == ["run_modes_echo"]
    end

    test "a pipeline declaring no dry_run: hook ignores the flag" do
      # The flag is inert rather than a silent no-op run: a pipeline with no
      # declared plan has nothing to report, and skipping its work on a flag it
      # never opted into would be the behaviour change D12 forbids hiding.
      assert {:ok, _} = NotDryable.run(dry_run: true)

      run = only_run("run_modes_not_dryable")
      assert Enum.map(steps(run.id), & &1.step_type) == ["run_modes_echo"]
    end
  end

  describe "compile-time validation" do
    test "summary_type: and returns: :run cannot both be declared" do
      assert_raise ArgumentError, ~r/cannot both be\s+declared/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x", returns: :run, summary_type: :stats
                    stage :s, fn _c, _p -> {:ok, 1} end|)
      end
    end

    test "summary_type: must be an atom naming a zero-arity type" do
      assert_raise ArgumentError, ~r/must be an atom naming a zero-arity type/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x", summary_type: "stats"
                    stage :s, fn _c, _p -> {:ok, 1} end|)
      end
    end

    # The `borrowed_run:`/`dry_run:` pair is rejected here and NOWHERE else —
    # there is no runtime branch for it, so this test is the only thing standing
    # between the declaration and a lent run that executes every stage for real
    # with `--dry-run` silently dropped. `ALLM.Pipeline`'s `## --dry-run` states
    # the rule; if it is ever relaxed, that section and this test change together.
    #
    # The control — "it rejects the PAIR, not either half" — needs NO test of its
    # own, and one was written and removed as vacuous: this file's `Inner`
    # (`borrowed_run: true`, no `dry_run:`) and `Dryable` (`dry_run:`, no
    # `borrowed_run:`) are real declarations compiled by this very module, so a
    # validator keyed on the wrong conjunct cannot reach ExUnit at all. Measured:
    # the `not is_nil(dry_run)` conjunct dropped fails the whole file to compile,
    # naming `RunModesTest.Inner`.
    test "borrowed_run: true and dry_run: cannot both be declared" do
      assert_raise ArgumentError, ~r/cannot both be\s+declared/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x", borrowed_run: true, dry_run: :plan
                    stage :s, fn _c, _p -> {:ok, 1} end
                    defp plan(_ctx), do: %{}|)
      end
    end

    test "borrowed_run: must be a boolean" do
      assert_raise ArgumentError, ~r/`borrowed_run:` must be `true` or `false`/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x", borrowed_run: :yes
                    stage :s, fn _c, _p -> {:ok, 1} end|)
      end
    end
  end

  defp compile!(body) do
    Code.eval_string("""
    defmodule Probe#{System.unique_integer([:positive])} do
    #{body}
    end
    """)
  end
end
