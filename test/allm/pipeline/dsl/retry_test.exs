defmodule ALLM.Pipeline.Dsl.RetryTest do
  @moduledoc """
  Pins `retry:` (Phase 4 D11): it RE-INVOKES the target, producing one step log
  per attempt, and marks attempts from the second with `is_retry: true`.

  Two properties are load-bearing and easy to get wrong in opposite directions.
  **One step log per attempt** is what makes the framework safe against the
  standing "`post_process/2` is not idempotent on two ported steps" hazard
  (`.work/HANDOFF.md`): a retry that reused one step log would re-apply a step's
  hooks to an already-post-processed output. And **`max:` counts attempts**, so
  `max: 3` on a target that fails twice then succeeds writes exactly three rows.

  No Phase 4 port declares `retry:` — both ports would otherwise have a
  step-log tree that changes shape whenever a transient failure occurs, which
  the identity gate cannot absorb. This file is its only exercise.
  """

  use ExUnit.Case, async: true

  import Ecto.Query

  alias ALLM.Pipeline.{Config, Context, PipelineRun, StepLog}

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  # A Step that fails its first N invocations and then succeeds. N rides in the
  # process dictionary rather than an Agent: the retry path is sequential by
  # construction, so the step runs in the test's own process.
  defmodule FlakyStep do
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
    def step_type, do: :retry_flaky

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_context, %Input{value: value}) do
      attempt = (Process.get(:retry_attempts) || 0) + 1
      Process.put(:retry_attempts, attempt)

      if attempt <= (Process.get(:retry_fail_until) || 0) do
        {:error, Process.get(:retry_reason) || :rate_limited}
      else
        {:ok, %Output{value: "#{value}-#{attempt}"}}
      end
    end
  end

  defmodule Retrying do
    @moduledoc false
    use ALLM.Pipeline, name: "retry_retrying", returns: :run

    alias ALLM.Pipeline.Dsl.RetryTest.FlakyStep

    stage(:flaky, FlakyStep, input: :flaky_input, retry: [max: 3])

    defp flaky_input(_ctx, _prev), do: %FlakyStep.Input{value: "v"}
  end

  defmodule RetryingOnList do
    @moduledoc false
    use ALLM.Pipeline, name: "retry_on_list", returns: :run

    alias ALLM.Pipeline.Dsl.RetryTest.FlakyStep

    stage(:flaky, FlakyStep,
      input: :flaky_input,
      retry: [max: 3, on: [:rate_limited, :timeout]],
      on_error: :continue
    )

    defp flaky_input(_ctx, _prev), do: %FlakyStep.Input{value: "v"}
  end

  defmodule RetryingBody do
    @moduledoc false
    use ALLM.Pipeline, name: "retry_body", init: :zero

    stage(:flaky, :flaky_body, retry: [max: 4], on_error: :continue)
    summarize(:passthrough)

    defp zero, do: 0

    defp flaky_body(ctx, _prev) do
      n = (Process.get(:retry_body_attempts) || 0) + 1
      Process.put(:retry_body_attempts, n)

      if n < 3,
        do: {{:error, :not_yet}, Context.accumulator(ctx) + 100},
        else: {{:ok, n}, Context.accumulator(ctx) + 1}
    end

    defp passthrough(acc, _ctx), do: acc
  end

  defmodule RetryingFanOut do
    @moduledoc false
    use ALLM.Pipeline, name: "retry_fan_out", init: :empty

    alias ALLM.Pipeline.Dsl.RetryTest.FlakyStep

    fan_out(:items, FlakyStep, over: :one, input: :flaky_input, retry: [max: 2])
    summarize(:passthrough)

    defp empty, do: []
    defp one(_prev), do: ["only"]
    defp flaky_input(_ctx, item), do: %FlakyStep.Input{value: item}
    defp passthrough(acc, _ctx), do: acc
  end

  defp only_run(name), do: from(r in PipelineRun, where: r.name == ^name) |> Config.repo().one!()

  defp steps(run_id) do
    from(s in StepLog, where: s.pipeline_run_id == ^run_id, order_by: [asc: s.started_at])
    |> Config.repo().all()
  end

  describe "re-invocation" do
    test "a stage failing twice then succeeding writes THREE step logs" do
      Process.put(:retry_fail_until, 2)

      assert {:ok, run} = Retrying.run()
      assert run.status == :success

      logs = steps(run.id)
      assert length(logs) == 3
      assert Enum.map(logs, & &1.status) == [:failed, :failed, :success]

      # One log per attempt is what keeps a step's hooks applied exactly once
      # per invocation: nothing is re-applied to an existing row.
      assert List.last(logs).output_data["value"] == "v-3"
    end

    test "attempts from the second are marked is_retry, so retry_count is 1 on the failed ones" do
      Process.put(:retry_fail_until, 2)

      {:ok, run} = Retrying.run()
      [first, second, third] = steps(run.id)

      assert first.retry_count == 0
      assert second.retry_count == 1

      # The THIRD attempt succeeded, and the success writer takes no opts —
      # `StepLog.log_success/3`'s third argument is an attrs MAP filtered to
      # five LLM keys — so `retry_count` stays 0 there. Widening it is a public
      # signature change Phase 4 forbids; Phase 7 owns `retry_count` as a true
      # cumulative counter (D11). Asserted rather than left implicit, because
      # this is the design's one unachievable assertion.
      assert third.retry_count == 0
      assert third.status == :success
    end

    test "exhausting max: leaves the LAST attempt's failure as the stage result" do
      Process.put(:retry_fail_until, 99)

      assert {:error, :rate_limited} = Retrying.run()

      run = only_run("retry_retrying")
      assert run.status == :failed
      assert Enum.map(steps(run.id), & &1.status) == [:failed, :failed, :failed]
      assert Enum.map(steps(run.id), & &1.retry_count) == [0, 1, 1]
    end

    test "a stage that succeeds first time is invoked ONCE" do
      Process.put(:retry_fail_until, 0)

      {:ok, run} = Retrying.run()

      assert length(steps(run.id)) == 1
      assert Process.get(:retry_attempts) == 1
    end
  end

  describe "on:" do
    test "retries a reason in the list" do
      Process.put(:retry_fail_until, 1)
      Process.put(:retry_reason, :timeout)

      {:ok, run} = RetryingOnList.run()
      assert length(steps(run.id)) == 2
    end

    test "does NOT retry a reason outside the list" do
      Process.put(:retry_fail_until, 99)
      Process.put(:retry_reason, :permission_denied)

      {:ok, run} = RetryingOnList.run()

      # One attempt, not three: `on:` is a filter, and a reason nobody declared
      # is not transient. `on_error: :continue` keeps the run alive so the step
      # count is the observable rather than the run's status.
      assert length(steps(run.id)) == 1
      assert Process.get(:retry_attempts) == 1
    end

    test "retries a TAGGED tuple reason by its first element" do
      Process.put(:retry_fail_until, 1)
      Process.put(:retry_reason, {:timeout, 5_000})

      {:ok, run} = RetryingOnList.run()
      assert length(steps(run.id)) == 2
    end
  end

  describe "escape-hatch bodies and fan-out items" do
    test "an escape-hatch body is re-invoked, and the LAST attempt's accumulator wins" do
      assert {:ok, acc} = RetryingBody.run()

      assert Process.get(:retry_body_attempts) == 3

      # Attempts 1 and 2 each returned `acc + 100`; only attempt 3's `acc + 1`
      # survives, because a retried attempt is a fresh invocation against the
      # SAME context. Documented on `Runtime.attempt_target/6`; if this ever
      # needs to be cumulative it is a design change, not a bug fix.
      assert acc == 1
    end

    test "retry: applies per fan-out ITEM" do
      Process.put(:retry_fail_until, 1)

      assert {:ok, _acc} = RetryingFanOut.run()

      run = only_run("retry_fan_out")
      assert Enum.map(steps(run.id), & &1.status) == [:failed, :success]
    end
  end

  describe "backoff" do
    test ":none does not sleep" do
      Process.put(:retry_fail_until, 2)

      {elapsed_us, {:ok, _run}} = :timer.tc(fn -> Retrying.run() end)

      # Two retries at the default `base_ms: 1000` under :linear or
      # :exponential would be >= 2000ms. `:none` is the default precisely so a
      # declaration cannot accidentally sleep.
      assert elapsed_us < 1_000_000
    end

    test ":linear sleeps base_ms * attempt" do
      defmodule Linear do
        @moduledoc false
        use ALLM.Pipeline, name: "retry_linear"

        stage(:flaky, :body, retry: [max: 3, backoff: :linear, base_ms: 20], on_error: :continue)

        defp body(_ctx, _prev), do: {:error, :always}
      end

      {elapsed_us, {:ok, _}} = :timer.tc(fn -> Linear.run() end)

      # Attempt 1 fails -> sleep 20; attempt 2 fails -> sleep 40; attempt 3
      # fails and is not retried. Sleep is a lower bound, so assert the floor.
      assert elapsed_us >= 60_000
    end

    test ":exponential sleeps base_ms * 2^(attempt-1)" do
      defmodule Exponential do
        @moduledoc false
        use ALLM.Pipeline, name: "retry_exponential"

        stage(:flaky, :body,
          retry: [max: 5, backoff: :exponential, base_ms: 10],
          on_error: :continue
        )

        defp body(_ctx, _prev), do: {:error, :always}
      end

      {elapsed_us, {:ok, _}} = :timer.tc(fn -> Exponential.run() end)

      # The declaration is `max: 5, base_ms: 10` and the floor is 150ms rather
      # than the sibling's 60ms because at `max: 3` the two formulas COINCIDE —
      # linear gives 20 + 40 and exponential gives 20 + 40, both 60ms — so a
      # 60ms floor is satisfied by `backoff/2`'s `:linear` clause verbatim and
      # this test could not fail for the reason it exists.
      #
      # Four sleeps separate them: linear totals 10 + 20 + 30 + 40 = 100ms,
      # exponential 10 + 20 + 40 + 80 = 150ms. `Process.sleep/1` is a lower
      # bound, so the real implementation is >= 150ms by construction and this
      # cannot false-red; the mutant `:exponential -> base * attempt` measured
      # 107.6ms (100ms of sleep + harness overhead), leaving ~42ms of margin.
      # `max: 4, base_ms: 20` — the arithmetically obvious choice — was measured
      # first and rejected: it separates 120ms from 140ms, and the same mutant
      # came in at 138.2ms, i.e. 1.8ms under the floor.
      assert elapsed_us >= 150_000
    end
  end

  describe "compile-time validation" do
    test "max: must be greater than 1" do
      assert_raise ArgumentError, ~r/counts total ATTEMPTS and must/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"
                    stage :s, fn _c, _p -> {:ok, 1} end, retry: [max: 1]|)
      end
    end

    test "retry: requires max:" do
      assert_raise ArgumentError, ~r/`retry:` must be a keyword list carrying `max:`/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"
                    stage :s, fn _c, _p -> {:ok, 1} end, retry: [backoff: :linear]|)
      end
    end

    test "an unknown backoff is rejected by name" do
      assert_raise ArgumentError, ~r/must be `:none`, `:linear` or `:exponential`/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"
                    stage :s, fn _c, _p -> {:ok, 1} end, retry: [max: 2, backoff: :fibonacci]|)
      end
    end

    test "on: must be :any or a non-empty list of atoms" do
      assert_raise ArgumentError, ~r/must be `:any` or a non-empty/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"
                    stage :s, fn _c, _p -> {:ok, 1} end, retry: [max: 2, on: []]|)
      end
    end

    test "an unknown retry option is rejected by name" do
      assert_raise ArgumentError, ~r/unknown `stage :s's retry:` option\(s\) \[:jitter\]/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"
                    stage :s, fn _c, _p -> {:ok, 1} end, retry: [max: 2, jitter: true]|)
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
