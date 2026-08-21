defmodule ALLM.Pipeline.Dsl.RuntimeSkipDiagnosticsTest do
  @moduledoc """
  4.5.6 (§9.1) — the implicit-`prev` skip detector.

  A stage's subject is `state.prev`, threaded implicitly. Three paths return the
  state untouched (`skip_when` fired, a `{:skipped, _}` body, `on_error:
  :continue`), so the NEXT stage silently receives the output of the stage
  *before* the skipped one. This pins that each of the three skip log lines now
  names the struct `prev` is carrying, so a downstream `FunctionClauseError` is
  traceable to the stage that was skipped. The struct name is the discriminating
  observable — present after the fix, absent at HEAD.

  `async: false` on purpose: two of the three skip lines are `Logger.info`, and
  `config/test.exs` pins the primary Logger level to `:warning` (which filters
  BEFORE `capture_log`'s handler sees anything). Raising the level for the
  duration is safe only in an async-false module — the same reason
  `committee_pipeline_test.exs`'s `capture_info/1` lives in an async-false file.
  DB-backed per `apps/allm_pipeline/CLAUDE.md` §3.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ALLM.Pipeline.Config

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  # A trivial Step that echoes its input — the seed stage produces a
  # `Marker.Output` struct so a later skip has a named struct in `prev`.
  defmodule Marker do
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
    def step_type, do: :skipdiag_marker

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_ctx, %Input{value: value}), do: {:ok, %Output{value: value}}
  end

  defmodule Failing do
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
    def step_type, do: :skipdiag_failing

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_ctx, %Input{}), do: {:error, :deliberate}
  end

  defmodule SkipWhenPipeline do
    @moduledoc false
    use ALLM.Pipeline, name: "skipdiag_skip_when", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeSkipDiagnosticsTest.Marker

    stage(:seed, Marker, input: :seed_input)
    stage(:maybe, Marker, input: :seed_input, skip_when: {:opt, :skip_it, false})

    defp seed_input(_ctx, _prev), do: %Marker.Input{value: "x"}
  end

  defmodule SkippedBodyPipeline do
    @moduledoc false
    use ALLM.Pipeline, name: "skipdiag_skipped_body", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeSkipDiagnosticsTest.Marker

    stage(:seed, Marker, input: :seed_input)
    stage(:skipper, :skip_body)

    defp seed_input(_ctx, _prev), do: %Marker.Input{value: "x"}
    defp skip_body(_ctx, _prev), do: {:skipped, :not_needed}
  end

  defmodule ContinuePipeline do
    @moduledoc false
    use ALLM.Pipeline, name: "skipdiag_continue", returns: :run

    alias ALLM.Pipeline.Dsl.RuntimeSkipDiagnosticsTest.{Marker, Failing}

    stage(:seed, Marker, input: :seed_input)
    stage(:boom, Failing, input: :boom_input, on_error: :continue)

    defp seed_input(_ctx, _prev), do: %Marker.Input{value: "x"}
    defp boom_input(_ctx, _prev), do: %Failing.Input{value: "y"}
  end

  # `config/test.exs` pins the primary level to `:warning`; the two skip lines
  # under test are `Logger.info`. Raise it for the duration.
  defp capture_info(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  describe "the implicit-prev skip detector (§9.1)" do
    test "a skip_when skip names the struct prev carries" do
      log = capture_info(fn -> assert {:ok, _run} = SkipWhenPipeline.run(skip_it: true) end)

      # Stage, reason, AND the struct prev holds — asserting only the first two
      # (as HEAD's line does) is what this rejects.
      assert log =~ "[maybe] skipped (skip_when)"
      assert log =~ "Marker.Output"
    end

    test "a {:skipped, _} body names the struct prev carries" do
      log = capture_info(fn -> assert {:ok, _run} = SkippedBodyPipeline.run() end)

      assert log =~ "[skipper] skipped:"
      assert log =~ ":not_needed"
      assert log =~ "Marker.Output"
    end

    test "an on_error: :continue error names the struct prev carries" do
      log = capture_info(fn -> assert {:ok, _run} = ContinuePipeline.run() end)

      assert log =~ "[boom] failed, continuing (on_error: :continue)"
      assert log =~ "Marker.Output"
    end
  end
end
