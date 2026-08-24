defmodule ALLM.Pipeline.TelemetryTest do
  @moduledoc """
  Pins the Phase 7.3 telemetry contract: the `[:allm_pipeline, :step, …]` events
  fire with the documented measurement/metadata keys, `queue_time_ms` is
  populated on a fan-out's later items (the real backlog wait, NOT
  `started_at - inserted_at`), `Logger.metadata` is set before a step runs, and
  a raising handler does not fail the run.

  DB-backed, per `apps/allm_pipeline/CLAUDE.md` §3. `async: false` because it
  attaches/detaches VM-global `:telemetry` handlers.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias ALLM.Pipeline.{Config, Context, Executor, Metrics, PipelineRun, StepLog}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  # ── Telemetry forwarders (module functions, not anon closures) ──────────────

  defmodule Forwarder do
    @moduledoc false
    @spec handle([atom()], map(), map(), pid()) :: :ok
    def handle(event, measurements, metadata, pid) do
      send(pid, {:telemetry, event, measurements, metadata})
      :ok
    end
  end

  defmodule RaisingHandler do
    @moduledoc false
    @spec boom([atom()], map(), map(), term()) :: no_return()
    def boom(_event, _measurements, _metadata, _config), do: raise("handler boom")
  end

  # ── Stub steps ──────────────────────────────────────────────────────────────

  defmodule ReportStep do
    @moduledoc false
    @behaviour ALLM.Pipeline.Step
    require Logger

    defmodule Input do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema(do: field(:value, :string))
    end

    defmodule Output do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema(do: field(:value, :string))
    end

    @impl true
    def step_type, do: :tele_report
    @impl true
    def input_schema, do: Input
    @impl true
    def output_schema, do: Output

    @impl true
    def execute(ctx, %Input{value: value}) do
      # Report the Logger.metadata VISIBLE INSIDE the step body — a mutant that
      # sets it after the step runs leaves this uncorrelated.
      case Context.get_opt(ctx, :reporter) do
        pid when is_pid(pid) -> send(pid, {:step_metadata, Logger.metadata()})
        _ -> :ok
      end

      {:ok, %Output{value: value}}
    end
  end

  defmodule SleepStep do
    @moduledoc false
    @behaviour ALLM.Pipeline.Step

    @sleep_ms 80

    defmodule Input do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema(do: field(:value, :string))
    end

    defmodule Output do
      @moduledoc false
      use Ecto.Schema
      @primary_key false
      embedded_schema(do: field(:value, :string))
    end

    @impl true
    def step_type, do: :tele_sleep
    @impl true
    def input_schema, do: Input
    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_ctx, %Input{value: value}) do
      Process.sleep(@sleep_ms)
      {:ok, %Output{value: value}}
    end

    def sleep_ms, do: @sleep_ms
  end

  # ── Pipeline fixtures ────────────────────────────────────────────────────────

  defmodule SinglePipeline do
    @moduledoc false
    use ALLM.Pipeline, name: "tele_single", returns: :run

    alias ALLM.Pipeline.TelemetryTest.ReportStep

    stage(:only, ReportStep, input: :inp)

    defp inp(_ctx, _prev), do: %ReportStep.Input{value: "x"}
  end

  defmodule QueueFanOut do
    @moduledoc false
    use ALLM.Pipeline, name: "tele_queue_fan_out", returns: :run

    alias ALLM.Pipeline.TelemetryTest.SleepStep

    # Two items at concurrency 1: item 2 waits behind item 1's ~80ms sleep.
    fan_out(:items, SleepStep, over: :two, input: :item_input, concurrency: 1)

    defp two(_prev), do: ["a", "b"]
    defp item_input(_ctx, item), do: %SleepStep.Input{value: item}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp attach_forwarder(events) do
    id = "tele-fwd-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(id, events, &Forwarder.handle/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  # Guarantee exactly one queue_time handler is attached, regardless of whether
  # app boot already attached it (same handler id).
  defp ensure_queue_handler do
    _ = Metrics.detach_step_handler()
    :ok = Metrics.attach_step_handler()
  end

  defp steps_of_type(run_id, type) do
    from(s in StepLog,
      where: s.pipeline_run_id == ^run_id and s.step_type == ^type,
      order_by: [asc: s.inserted_at, asc: s.id]
    )
    |> Config.repo().all()
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "step events" do
    test "fire on start and stop with the documented measurement/metadata keys" do
      {:ok, run} = Executor.create_pipeline_run("tele_report_run", %{})
      attach_forwarder([[:allm_pipeline, :step, :start], [:allm_pipeline, :step, :stop]])

      assert {:ok, _log, %ReportStep.Output{}} =
               Executor.run_step(run, ReportStep, %ReportStep.Input{value: "x"}, nil,
                 reporter: self()
               )

      assert_receive {:telemetry, [:allm_pipeline, :step, :start], start_meas, start_meta}
      assert start_meas == %{}
      assert %{step_type: "tele_report", run_id: run_id, step_id: step_id} = start_meta
      assert run_id == run.id
      assert is_binary(step_id)

      assert_receive {:telemetry, [:allm_pipeline, :step, :stop], stop_meas, stop_meta}
      # Guard: a mutant emitting :stop without queue_time fails these.
      assert Map.has_key?(stop_meas, :duration)
      assert Map.has_key?(stop_meas, :queue_time)
      assert stop_meta.status == :ok
      assert stop_meta.step_id == step_id
    end

    test "Logger.metadata is set BEFORE the step runs (correlatable in-step)" do
      {:ok, run} = Executor.create_pipeline_run("tele_report_run", %{})

      assert {:ok, _log, _out} =
               Executor.run_step(run, ReportStep, %ReportStep.Input{value: "x"}, nil,
                 reporter: self()
               )

      assert_receive {:step_metadata, md}
      assert md[:run_id] == run.id
      assert is_binary(md[:step_id])
      assert md[:step_type] == "tele_report"
      assert md[:pipeline_name] == "tele_report_run"
    end
  end

  describe "queue_time_ms" do
    test "reflects the real backlog wait on a fan-out's later items" do
      ensure_queue_handler()

      assert {:ok, %PipelineRun{} = run} = QueueFanOut.run()

      assert [first, second] = steps_of_type(run.id, "tele_sleep")

      # Item 2 waited behind item 1's ~80ms sleep. This value discriminates
      # against BOTH a hardcoded-0 mutant AND a `started_at - inserted_at` (~0)
      # mutant — neither can produce a queue_time reflecting the sleep.
      assert second.queue_time_ms >= 50
      assert first.queue_time_ms < second.queue_time_ms
    end
  end

  describe "fire-and-forget" do
    test "a raising :step,:stop handler does not fail the run" do
      id = "tele-raising-#{System.unique_integer([:positive])}"
      :ok = :telemetry.attach(id, [:allm_pipeline, :step, :stop], &RaisingHandler.boom/4, nil)
      on_exit(fn -> :telemetry.detach(id) end)

      # `:telemetry` isolates a crashing handler (logs + detaches it); the run
      # still completes. Without that isolation the emit would propagate.
      log =
        capture_log(fn ->
          assert {:ok, %PipelineRun{status: :success}} = SinglePipeline.run()
        end)

      assert log =~ "boom" or log =~ "Handler"
    end
  end
end
