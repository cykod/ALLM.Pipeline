defmodule ALLM.Pipeline.ExecutorTest do
  @moduledoc """
  Pins `ALLM.Pipeline.Executor`.

  ## The sandbox setup, and why it is not a `DataCase`

  Moved here from `apps/amesbury_scraper/test/` in batch 1.D. The package tree
  deliberately depends on no host app, so it cannot see
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

  # A Step whose schemas are built with `ALLM.Pipeline.Schema`, so validation
  # runs through `cast/1` (subphase 2.3). Every OTHER fixture in this file uses
  # an Ecto embedded schema, which exports no `cast/1` — that is not an
  # oversight, it is what drives `validate_against/3`'s fallback clause, and
  # three real Step schemas are in the same position today
  # (`CastusListingScraper.Input`/`.Output`, `VideoMatchStep.Input`).
  defmodule CastStep do
    @behaviour ALLM.Pipeline.Step

    defmodule Input do
      use ALLM.Pipeline.Schema

      schema do
        field(:value, String.t(), required: true)
        field(:api_key, String.t(), redact: true)
      end
    end

    defmodule Output do
      use ALLM.Pipeline.Schema

      schema do
        field(:result, String.t(), required: true)
      end
    end

    @impl true
    def step_type, do: :cast_step

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def artifact_content_type, do: "text/plain"

    @impl true
    def artifact_content(%Output{result: result}), do: result

    @impl true
    def execute(_context, %Input{value: value}) do
      {:ok, %Output{result: "processed: #{value}"}}
    end
  end

  # Same schemas as `CastStep`, but `execute/2` returns a bare MAP where the
  # behaviour promises the `output_schema()` struct. `cast/1` accepts it, and
  # everything downstream must receive the CAST STRUCT rather than the map.
  defmodule MapOutputCastStep do
    @behaviour ALLM.Pipeline.Step

    @impl true
    def step_type, do: :cast_step

    @impl true
    def input_schema, do: CastStep.Input

    @impl true
    def output_schema, do: CastStep.Output

    @impl true
    def artifact_content_type, do: "text/plain"

    @impl true
    def artifact_content(%CastStep.Output{result: result}), do: result

    @impl true
    def execute(_context, %CastStep.Input{value: value}) do
      {:ok, %{result: "processed: #{value}"}}
    end
  end

  # Returns a struct of the WRONG module where the behaviour promises
  # `output_schema()`'s — the output twin of the wrong-module input case.
  defmodule WrongOutputCastStep do
    @behaviour ALLM.Pipeline.Step

    @impl true
    def step_type, do: :cast_step

    @impl true
    def input_schema, do: CastStep.Input

    @impl true
    def output_schema, do: CastStep.Output

    @impl true
    def execute(_context, _input), do: {:ok, %TestStep.Output{result: "wrong module"}}
  end

  # Returns a map that `CastStep.Output.cast/1` REJECTS (unknown key, and the
  # required `:result` missing), so the output half of the rejection message is
  # exercised on a value-bearing map — the shape the redaction assertion needs.
  defmodule BadMapOutputCastStep do
    @behaviour ALLM.Pipeline.Step

    @impl true
    def step_type, do: :cast_step

    @impl true
    def input_schema, do: CastStep.Input

    @impl true
    def output_schema, do: CastStep.Output

    @impl true
    def execute(_context, _input), do: {:ok, %{secret_note: "SUPERSECRETVALUE"}}
  end

  # A schema module that exports a `cast/1` which is NOT the DSL's — the exact
  # shape of `Ecto.Type.cast/1`, whose contract is
  # `{:ok, term} | :error | {:error, keyword}`. It is a plain `defstruct`, so
  # `Executor` must route it through the module-comparison fallback; keying the
  # branch on the generic name `cast/1` (which 2.3 originally did) would send it
  # to the DSL branch, where a bare `:error` matches neither `case` arm and
  # raises `CaseClauseError` — before `execute_step`'s try/rescue, inside a
  # linking `Task.async_stream`.
  defmodule EctoTypeishStep do
    @behaviour ALLM.Pipeline.Step

    defmodule Input do
      defstruct [:value]

      # Deliberately `Ecto.Type`-shaped, and deliberately never called. The
      # `Process.put/2` is the test's observable: `Executor.run_step/5` runs
      # `validate_input/2` in the CALLING process, so the flag is visible to the
      # test, and "was `cast/1` reached at all?" is the property that actually
      # distinguishes the two predicates. Asserting on the error message cannot:
      # `validate_against/3`'s catch-all arm turns the bare `:error` below into a
      # tuple too, so both branches return `{:error, nil, "Input must be …"}`.
      def cast(%__MODULE__{} = value) do
        Process.put(:ecto_typeish_cast_called, true)
        {:ok, value}
      end

      def cast(_other) do
        Process.put(:ecto_typeish_cast_called, true)
        :error
      end
    end

    defmodule Output do
      defstruct [:result]
    end

    @impl true
    def step_type, do: :ecto_typeish_step

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_context, %Input{value: value}), do: {:ok, %Output{result: "processed: #{value}"}}
  end

  # Passes `dsl_schema?/1` (it exports `__allm_schema__/1`) but returns a shape
  # neither `case` arm matches. Unconstructible from the DSL macro, and that is
  # the point: it is the only way to exercise `validate_against/3`'s catch-all,
  # which exists so that a future `cast/1` contract change degrades to an error
  # tuple instead of a `CaseClauseError` on the un-rescued input path.
  defmodule RogueCastStep do
    @behaviour ALLM.Pipeline.Step

    defmodule Input do
      defstruct [:value]

      def __allm_schema__(:fields), do: [:value]
      def __allm_schema__(_other), do: []

      # An `Ecto.Type`-style bare `:error`, from a module that otherwise looks
      # like a DSL schema.
      def cast(_input), do: :error
    end

    @impl true
    def step_type, do: :rogue_cast_step

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: CastStep.Output

    @impl true
    def execute(_context, _input), do: {:ok, %CastStep.Output{result: "unreachable"}}
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
          # Subphase 2.3: the message renders the term's SHAPE — its type and
          # its key names — never its values. `"a bare map"` is the VALUE.
          assert reason =~ "a map with keys [:value]"
          refute reason =~ "a bare map"
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

  # Subphase 2.3. `validate_input/2` / `validate_output/2` route through the
  # schema's `cast/1` when it has one, and keep the `mod ==` comparison when it
  # does not. Both halves return the CAST STRUCT, and both callers use it.
  describe "run_step/5 validating through cast/1" do
    setup do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test_pipeline")
      %{pipeline_run: pipeline_run}
    end

    test "a valid struct input still runs the step", %{pipeline_run: pipeline_run} do
      input = %CastStep.Input{value: "test", api_key: "k"}

      assert {:ok, step_log, output} = Executor.run_step(pipeline_run, CastStep, input)
      assert step_log.status == :success
      assert output == %CastStep.Output{result: "processed: test"}
    end

    test "a struct of the wrong module keeps the message prefix", %{pipeline_run: pipeline_run} do
      log =
        capture_log(fn ->
          assert {:error, nil, reason} =
                   Executor.run_step(pipeline_run, CastStep, %TestStep.Input{value: "x"})

          # The existing assertions in this file pin the PREFIX; `cast/1`'s issue
          # list is appended, so they survive and the detail is additive.
          assert reason =~ "Input must be "
          assert reason =~ "wrong_struct"
        end)

      assert log =~ "Input validation failed"
    end

    test "a map input matching the schema runs, and its input_data matches the struct path's",
         %{pipeline_run: pipeline_run} do
      {:ok, from_struct, _} =
        Executor.run_step(pipeline_run, CastStep, %CastStep.Input{value: "test", api_key: "k"})

      {:ok, from_map, output} =
        Executor.run_step(pipeline_run, CastStep, %{value: "test", api_key: "k"})

      # The widening: `run_step/5` accepted only a struct before 2.3.
      assert output == %CastStep.Output{result: "processed: test"}
      assert from_map.input_data == from_struct.input_data
      assert from_map.input_schema == from_struct.input_schema
      # Guard against a vacuous comparison of two empty maps: the row must
      # actually carry the field, and `redact:` must still have applied.
      assert from_map.input_data["value"] == "test"
      assert from_map.input_data["api_key"] == "[REDACTED]"
    end

    test "a string-keyed map input is accepted too", %{pipeline_run: pipeline_run} do
      assert {:ok, step_log, _output} =
               Executor.run_step(pipeline_run, CastStep, %{"value" => "test"})

      assert step_log.input_data["value"] == "test"
    end

    test "a map missing a required field is rejected, naming the field", %{
      pipeline_run: pipeline_run
    } do
      capture_log(fn ->
        assert {:error, nil, reason} =
                 Executor.run_step(pipeline_run, CastStep, %{api_key: "k"})

        assert reason =~ "Input must be "
        assert reason =~ "value"
        assert reason =~ "missing"
      end)
    end

    test "a non-castable input returns a tuple and does not raise", %{pipeline_run: pipeline_run} do
      # ⚠️ This case was ALREADY correct at HEAD, through `validate_input/2`'s
      # catch-all clause — the test is a pin against `cast/1` regressing it, not
      # a fix. `validate_input/2` runs BEFORE `execute_step`'s try/rescue, and
      # callers fan `run_step/5` out through `Task.async_stream`, which links its
      # children: a raise here kills the calling process, not one item.
      capture_log(fn ->
        for term <- [42, nil, "a string", ["not", "a", "keyword"]] do
          assert {:error, nil, reason} = Executor.run_step(pipeline_run, CastStep, term)
          assert reason =~ "Input must be "
        end
      end)
    end

    test "a process-y term is NAMED in the rejection, not called an unrenderable term", %{
      pipeline_run: pipeline_run
    } do
      # `render_shape/1`'s catch-all used to swallow pids, references and ports —
      # the three BEAM types with no clause of their own — into "an unrenderable
      # term", which tells an operator reading `step_logs.error` nothing about
      # what a caller actually handed `run_step/5`. Naming the type leaks no
      # value, which is the property the whole function exists for.
      capture_log(fn ->
        for {term, expected} <- [{self(), "a pid"}, {make_ref(), "a reference"}] do
          assert {:error, nil, reason} = Executor.run_step(pipeline_run, CastStep, term)
          assert reason =~ "got #{expected}:"
          refute reason =~ "unrenderable"
        end
      end)
    end

    test "a non-DSL schema module still validates by module comparison", %{
      pipeline_run: pipeline_run
    } do
      # ⚠️ Both halves in one test on purpose — that is what makes the fallback
      # distinguishable from its absence. `TestStep.Input` is an Ecto embedded
      # schema and exports no `__allm_schema__/1`; `CastStep.Input` is a DSL
      # schema and does.
      #
      # If `dsl_schema?/1` were hardcoded TRUE, the `TestStep` half raises
      # `UndefinedFunctionError` out through `run_step/5` (the fan-out hazard).
      # If it were hardcoded FALSE, the `CastStep` half is rejected because a
      # bare map has no `__struct__` to compare. Neither half alone catches both.
      assert {:ok, _log, _out} =
               Executor.run_step(pipeline_run, TestStep, %TestStep.Input{value: "ok"})

      capture_log(fn ->
        assert {:error, nil, reason} =
                 Executor.run_step(pipeline_run, TestStep, %{value: "ok"})

        assert reason =~ "Input must be "
      end)

      assert {:ok, _log, _out} = Executor.run_step(pipeline_run, CastStep, %{value: "ok"})
    end

    test "a schema exporting a NON-DSL cast/1 takes the fallback and never raises", %{
      pipeline_run: pipeline_run
    } do
      # The discriminator for keying the branch on `__allm_schema__/1` rather
      # than on the generic name `cast/1`. `EctoTypeishStep.Input` is a plain
      # `defstruct` exporting an `Ecto.Type`-shaped `cast/1`
      # (`{:ok, term} | :error`), which is the collision the `__schema__/1`
      # argument in `ALLM.Pipeline.Schema`'s moduledoc predicts.
      #
      # ⚠️ The assertion that discriminates is `Process.get/1`, NOT the message:
      # `validate_against/3`'s catch-all arm degrades the bare `:error` to a
      # tuple as well, so a message assertion passes under BOTH predicates
      # (measured — a mutant flipping the predicate survived one). "Was
      # `cast/1` reached?" is the only observable the two branches differ on.
      Process.delete(:ecto_typeish_cast_called)

      assert {:ok, _log, out} =
               Executor.run_step(pipeline_run, EctoTypeishStep, %EctoTypeishStep.Input{
                 value: "ok"
               })

      assert out.result == "processed: ok"

      capture_log(fn ->
        assert {:error, nil, reason} =
                 Executor.run_step(pipeline_run, EctoTypeishStep, %{value: "ok"})

        # The fallback's non-struct clause: shape only, no appended issue list
        # and no "unrecognised result" (which is what the DSL branch's catch-all
        # would have produced from the bare `:error`).
        assert reason =~ "Input must be "
        assert reason =~ "a map with keys"
        refute reason =~ "unrecognised result"
      end)

      refute Process.get(:ecto_typeish_cast_called),
             "Executor called a non-DSL module's cast/1 — the branch is keying on the " <>
               "generic name `cast/1` rather than on `__allm_schema__/1`"
    end

    test "a cast/1 returning an unrecognised shape degrades to a tuple, not a CaseClauseError",
         %{pipeline_run: pipeline_run} do
      # Belt and braces on the un-rescued path. `dsl_schema?/1` makes this
      # unreachable in production today — only `ALLM.Pipeline.Schema` modules
      # export `__allm_schema__/1`, and their `cast/1` returns one of two arms —
      # so this fixture is the only thing that can price the catch-all. Deleting
      # the arm reddens this with `CaseClauseError` escaping `run_step/5`, which
      # is precisely the fan-out kill the subphase exists to prevent.
      capture_log(fn ->
        assert {:error, nil, reason} =
                 Executor.run_step(pipeline_run, RogueCastStep, %{value: "x"})

        assert reason =~ "Input must be "
        assert reason =~ "unrecognised result"
        # The rogue return value is rendered by shape, not inspected — the
        # leak rule applies to this arm too.
        assert reason =~ "(an atom)"
      end)
    end

    test "a step returning a struct of the wrong module names the contract it broke", %{
      pipeline_run: pipeline_run
    } do
      capture_log(fn ->
        assert {:error, step_log, {:output_validation_failed, reason}} =
                 Executor.run_step(pipeline_run, WrongOutputCastStep, %{value: "x"})

        assert reason =~ "Output must be "
        assert reason =~ "wrong_struct"
        assert step_log.status == :failed
        assert step_log.error["message"] =~ "Output must be "
      end)
    end

    test "a step returning a bare map gets the CAST STRUCT forwarded downstream", %{
      pipeline_run: pipeline_run
    } do
      {:ok, from_struct, _} = Executor.run_step(pipeline_run, CastStep, %{value: "test"})

      assert {:ok, from_map, output} =
               Executor.run_step(pipeline_run, MapOutputCastStep, %{value: "test"})

      # `run_step/5`'s third element is the STRUCT, not the step's raw map — the
      # property every caller that pattern-matches `{:ok, _, %Mod{}}` relies on.
      assert output == %CastStep.Output{result: "processed: test"}
      assert from_map.output_data == from_struct.output_data
      assert from_map.output_data["result"] == "processed: test"
    end

    @tag :dynamo
    test "the bare-map path's artifact is byte-identical to the struct path's", %{
      pipeline_run: pipeline_run
    } do
      # Discriminator: this is what fails an implementation that validates the
      # map but forwards it unconverted — `artifact_content/1` heads on
      # `%Output{}` and would `BadMapError` inside the try/rescue, producing a
      # failed step log with no artifact at all.
      {:ok, from_struct, _} = Executor.run_step(pipeline_run, CastStep, %{value: "test"})
      {:ok, from_map, _} = Executor.run_step(pipeline_run, MapOutputCastStep, %{value: "test"})

      # Non-nil first: two `nil` checksums would compare equal and prove nothing.
      assert from_struct.artifact_checksum != nil
      assert from_map.artifact_checksum == from_struct.artifact_checksum
      assert from_map.artifact_size_bytes == from_struct.artifact_size_bytes
    end

    test "a rejected term's VALUES reach neither the reason, the logs, nor step_logs.error",
         %{pipeline_run: pipeline_run} do
      # The security-lane target. `redact:` applies at serialization only
      # (`ALLM.Pipeline.Schema`, D3), and none of these three paths goes through
      # the serializer — so before 2.3 the `inspect(other)` in the rejection
      # message put a rejected map's whole contents into all three. Now that
      # `cast/1` makes a bare map a SUPPORTED input shape, a rejected map
      # carrying real field values is a realistic input rather than a malformed
      # one.
      secret = "SUPERSECRETVALUE"

      # Half 1 — the INPUT path. No step log exists yet (`{:error, nil, _}`), so
      # the exposure is the returned reason plus the log line, and host pipelines
      # persist that reason to `pipeline_runs.metadata.error` via `fail_run/2`.
      input_log =
        capture_log(fn ->
          assert {:error, nil, reason} =
                   Executor.run_step(pipeline_run, CastStep, %{api_key: secret, bogus: secret})

          assert reason =~ "Input must be "
          # The KEY names may appear — the design permits that, and they are
          # what makes the message diagnosable at all.
          assert reason =~ "api_key"
          refute reason =~ secret
        end)

      refute input_log =~ secret

      # Half 2 — the OUTPUT path, which DOES reach `step_logs.error` through
      # `handle_failure/3`. Nothing else in this file covers that column.
      output_log =
        capture_log(fn ->
          assert {:error, step_log, {:output_validation_failed, reason}} =
                   Executor.run_step(pipeline_run, BadMapOutputCastStep, %{value: "x"})

          refute reason =~ secret
          refute step_log.error["message"] =~ secret
          # Guard: the row must actually carry the rejection, or the `refute`
          # above passes against an empty column.
          assert step_log.error["message"] =~ "Output must be "
        end)

      refute output_log =~ secret
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

    test "scrubs a NUL byte out of the title instead of failing the insert with 22P05" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test_pipeline")

      # The title is the one field on this row that comes from OUTSIDE — the
      # DSL's `section:` hook derives it from a scraped or OCR'd item — and
      # Postgres rejects a NUL in a text column with `22P05`, which would abort
      # a fan-out mid-run for a value that is only ever displayed. The
      # round-trip is the assertion: `changeset.changes` would pass even if the
      # insert then died.
      assert {:ok, section} =
               Executor.log_section(pipeline_run, "Planning Board" <> <<0>> <> " - Agenda")

      reloaded = ALLM.Pipeline.StepLog.get(section.id)
      assert reloaded.input_data == %{"title" => "Planning Board - Agenda"}
    end

    test "drops an invalid UTF-8 sequence from the title" do
      {:ok, pipeline_run} = Executor.create_pipeline_run("test_pipeline")

      assert {:ok, section} = Executor.log_section(pipeline_run, <<"Zoning ", 0xFF, " Board">>)

      reloaded = ALLM.Pipeline.StepLog.get(section.id)
      assert reloaded.input_data == %{"title" => "Zoning  Board"}
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
      # Scans THIS repo's `lib/` only. The invariant still spans the repo split
      # — host pipelines must funnel through `borrowed_run/1` too — but the host
      # tree is a different repo now (Phase 8.1 narrowing). The host half lives
      # in its own twin: `AmesburyScraper.Pipeline.FrameworkBoundaryGuardsTest`,
      # "every borrowed-run read goes through borrowed_run/1"
      # (`apps/amesbury_scraper/test/amesbury_scraper/pipeline/framework_boundary_guards_test.exs`
      # in the Amesbury umbrella).
      # Glob + fail-open floor live in the shared scaffold (extracted in Phase
      # 8.4, Rule of 3 — see `ALLM.Pipeline.TestSupport.LibScan`'s moduledoc).
      offenders =
        ALLM.Pipeline.TestSupport.LibScan.lib_files!()
        # Only `ALLM.Pipeline.Executor` itself may read the opt directly —
        # matched by path suffix, not basename: it is the property that made
        # the exemption safe to begin with.
        |> Enum.reject(&String.ends_with?(&1, "pipeline/executor.ex"))
        |> Enum.filter(fn path ->
          # Every Keyword READ accessor (`pop` included), any binding name — several
          # pipelines thread a `meeting_opts` rather than a literal `opts` — and the
          # `opts[:pipeline_run]` Access form, which works on keyword lists.
          # `Keyword.put`/`put_new` are deliberately absent: those are the LEND
          # sites (host pipelines lending a run to an inner pipeline), which are
          # correct and must not be flagged. It is the receiving read that has to
          # be funnelled.
          File.read!(path) =~
            ~r/Keyword\.(fetch!?|get|get_lazy|pop!?|pop_lazy|take)\(\s*\w+,\s*:pipeline_run|\w+\[:pipeline_run\]/
        end)
        |> Enum.map(&Path.relative_to(&1, ALLM.Pipeline.TestSupport.LibScan.root()))

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
