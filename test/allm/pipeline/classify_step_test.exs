defmodule ALLM.Pipeline.ClassifyStepTest do
  @moduledoc """
  `ALLM.Pipeline.ClassifyStep` — the generated `Step` callbacks, the
  classification call through the LLM seam, and the answers → Output coercion.

  **Not `async: true`.** Every call routes through `ALLM.Pipeline.LLM.impl/0`,
  which reads `:allm_pipeline` application env; per this repo's `CLAUDE.md` §5
  the value is established and restored here rather than observed.

  The stub adapter delegates to `ALLM.classify/3` over
  `ALLM.Providers.FakeClassification`, so the answers are ALLM 0.6.0's own
  structs, not hand-built ones.
  """

  use ExUnit.Case, async: false

  alias ALLM.{ClassificationAnswer, ClassificationQuestion, ClassificationResponse}
  alias ALLM.Pipeline.{Context, LLM}

  # ── The stub adapter ────────────────────────────────────────────────────────

  # Exports the context-taking `resolve_engine/2` and `classify/4`; the
  # mandatory `/1` + `/4` RAISE (unused here). Every call reports to the root
  # caller by `send/2`; the scripted answers come from the test process's
  # dictionary, read in `resolve_engine/2` (the calls below all run in it).
  defmodule ClassifyStub do
    @moduledoc false
    @behaviour ALLM.Pipeline.LLM

    @impl true
    def resolve_engine(_name), do: raise("resolve_engine/1 must not be called")

    @impl true
    def resolve_engine(name, ctx) do
      report({:resolve_engine, name, ctx})

      ALLM.Engine.new(
        classification_adapter: ALLM.Providers.FakeClassification,
        adapter_opts: [classification_script: Process.get(:classify_script, [])]
      )
    end

    @impl true
    def generate_structured(_prompt, _schema, _schema_name, _engine),
      do: raise("generate_structured/4 must not be called")

    @impl true
    def classify(state, questions, engine, ctx) do
      report({:classify, state, questions, ctx})

      case Process.get(:classify_override) do
        nil -> ALLM.classify(engine, state, questions: questions)
        override -> override
      end
    end

    defp report(event),
      do: send(List.last(Process.get(:"$callers", [])) || self(), {:stub, event})
  end

  setup do
    previous = Application.get_env(:allm_pipeline, LLM)
    Application.put_env(:allm_pipeline, LLM, impl: ClassifyStub)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:allm_pipeline, LLM)
        value -> Application.put_env(:allm_pipeline, LLM, value)
      end
    end)

    :ok
  end

  @spec script(map()) :: :ok
  defp script(answers) do
    Process.put(:classify_script, [{:answers, answers}])
    :ok
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defmodule Triage do
    @moduledoc false

    defmodule Input do
      @moduledoc false
      use ALLM.Pipeline.Schema

      schema do
        field(:text, String.t(), required: true)
        # When set, replaces the step's default questions (the validation tests).
        field(:questions, map())
      end
    end

    defmodule Output do
      @moduledoc false
      use ALLM.Pipeline.Schema

      schema do
        field(:department, atom(), values: [:billing, :technical, :other], default: :unassigned)
        field(:team_name, String.t())
        field(:frustration, float())
        field(:refund, float())
        field(:answers, map())
        field(:tokens_used, integer())
      end
    end

    @spec questions(Input.t()) :: %{(atom() | String.t()) => ClassificationQuestion.t()}
    def questions(%Input{questions: nil}) do
      %{
        # "x" is an option the model may pick but the vocabulary does not hold.
        :department =>
          ClassificationQuestion.choice("Which department?", ["billing", "technical", "x"]),
        "team_name" => ClassificationQuestion.choice("Which team?", ["payments", "platform"]),
        :frustration =>
          ClassificationQuestion.score("How frustrated?", ["calm", "annoyed", "furious"]),
        :refund => ClassificationQuestion.yes_no("Is a refund requested?")
      }
    end

    def questions(%Input{questions: questions}), do: questions
  end

  defmodule TriageStep do
    @moduledoc false
    alias ALLM.Pipeline.ClassifyStepTest.Triage

    use ALLM.Pipeline.ClassifyStep,
      type: :triage,
      engine: :classifier,
      input: Triage.Input,
      output: Triage.Output

    def state(%Triage.Input{text: text}), do: text
    def questions(input), do: Triage.questions(input)
  end

  # The same declaration, `execute/2` overridden wholesale over the public parts.
  defmodule OverridingTriageStep do
    @moduledoc false
    alias ALLM.Pipeline.ClassifyStepTest.Triage

    use ALLM.Pipeline.ClassifyStep,
      type: :triage_overridden,
      engine: :classifier,
      input: Triage.Input,
      output: Triage.Output

    def state(%Triage.Input{text: text}), do: text
    def questions(input), do: Triage.questions(input)

    @impl true
    def execute(context, input) do
      with {:ok, answers, tokens} <- call_classifier(context, input),
           {:ok, output} <- coerce(answers, tokens) do
        {:ok, output}
      end
    end
  end

  # No `:other` in the vocabulary, inline blocks instead of `input:`/`output:`.
  defmodule StrictTriageStep do
    @moduledoc false
    use ALLM.Pipeline.ClassifyStep, type: :strict_triage, engine: :classifier

    input_schema do
      field(:text, String.t(), required: true)
    end

    output_schema do
      field(:department, atom(), values: [:billing, :technical])
    end

    def state(%Input{text: text}), do: text

    def questions(_input),
      do: %{department: ClassificationQuestion.choice("Which?", ["billing", "technical", "x"])}
  end

  # Field types no answer type fits.
  defmodule MismatchStep do
    @moduledoc false
    use ALLM.Pipeline.ClassifyStep, type: :mismatch, engine: :classifier

    input_schema do
      field(:text, String.t(), required: true)
    end

    output_schema do
      field(:flag, boolean())
      field(:level, float())
      field(:count, integer())
    end

    def state(%Input{text: text}), do: text
    def questions(_input), do: %{}
  end

  defp input(opts \\ []), do: Triage.Input.new(Keyword.merge([text: "Charged twice!"], opts))

  defp question, do: ClassificationQuestion.choice("Which?", ["billing", "technical"])

  # ── The generated Step surface ──────────────────────────────────────────────

  describe "the generated Step surface" do
    test "carries the @behaviour attribute and exports the callbacks" do
      declared =
        for {:behaviour, behaviours} <- TriageStep.module_info(:attributes),
            behaviour <- behaviours,
            do: behaviour

      assert ALLM.Pipeline.Step in declared
      assert ALLM.Pipeline.Step.implements?(TriageStep)
    end

    test "the callbacks answer the `use` declaration" do
      assert {TriageStep.step_type(), TriageStep.input_schema(), TriageStep.output_schema()} ==
               {:triage, Triage.Input, Triage.Output}
    end

    test "omitted `input:`/`output:` default to the nested blocks" do
      assert StrictTriageStep.input_schema() == StrictTriageStep.Input
      assert StrictTriageStep.output_schema() == StrictTriageStep.Output
    end
  end

  # ── execute/2 ───────────────────────────────────────────────────────────────

  describe "execute/2" do
    test "turns the answers into a typed Output struct" do
      script(%{"department" => "billing", "frustration" => 1.25, "refund" => 0.9})

      assert {:ok, %Triage.Output{} = output} = TriageStep.execute(Context.detached(), input())

      assert {output.department, output.frustration, output.refund} == {:billing, 1.25, 0.9}
    end

    test "keeps every answer struct in an `answers` field" do
      script(%{"department" => "billing"})

      {:ok, output} = TriageStep.execute(Context.detached(), input())

      assert Enum.sort(Map.keys(output.answers)) ==
               ["department", "frustration", "refund", "team_name"]

      assert Enum.all?(Map.values(output.answers), &match?(%ClassificationAnswer{}, &1))
    end

    test "a choice into a String.t() field is the option string, unchanged" do
      script(%{"team_name" => "platform"})

      {:ok, output} = TriageStep.execute(Context.detached(), input())

      assert output.team_name == "platform"
    end

    test "a choice outside the vocabulary becomes :other where :other is declared" do
      script(%{"department" => "x"})

      {:ok, output} = TriageStep.execute(Context.detached(), input())

      assert output.department == :other
    end

    test "a choice outside a vocabulary without :other is a coercion failure" do
      script(%{"department" => "x"})

      assert StrictTriageStep.execute(Context.detached(), StrictTriageStep.Input.new(text: "t")) ==
               {:error, {:coerce, [department: {:unknown_value, "x"}]}}
    end

    test "tokens_used is the response's total tokens" do
      answers = %{"department" => ClassificationAnswer.new(type: :choice, choice: "billing")}

      Process.put(
        :classify_override,
        {:ok,
         ClassificationResponse.new(
           answers: answers,
           usage: ALLM.Usage.new(input_tokens: 30, output_tokens: 12)
         )}
      )

      {:ok, output} = TriageStep.execute(Context.detached(), input())

      assert output.tokens_used == 42
    end

    test "an adapter error is tagged :llm_error and returned" do
      error = %ALLM.Error.ClassificationAdapterError{reason: :invalid_request}
      Process.put(:classify_script, [{:error, error}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error,
                  {:llm_error, %ALLM.Error.ClassificationAdapterError{reason: :invalid_request}}} =
                   TriageStep.execute(Context.detached(), input())
        end)

      assert log =~ "Classification error in #{inspect(TriageStep)}"
    end

    test "an adapter returning a non-response success is named, not a KeyError" do
      Process.put(:classify_override, {:ok, %{answers: %{}}})

      message =
        assert_raise(ArgumentError, fn -> TriageStep.execute(Context.detached(), input()) end).message

      assert message =~ inspect(ClassifyStub)
      assert message =~ "ALLM.ClassificationResponse"
    end

    test "the adapter sees the step's context" do
      script(%{})

      {:ok, _output} = TriageStep.execute(Context.detached(account_id: "a3"), input())

      assert_received {:stub, {:resolve_engine, :classifier, seen}}
      assert Context.get_opt(seen, :account_id) == "a3"

      assert_received {:stub, {:classify, _state, _questions, seen}}
      assert Context.get_opt(seen, :account_id) == "a3"
    end

    test "the adapter receives the state and string-keyed questions" do
      script(%{})

      {:ok, _output} = TriageStep.execute(nil, input())

      assert_received {:stub, {:classify, "Charged twice!", questions, %Context{opts: []}}}

      assert Enum.sort(Map.keys(questions)) == [
               "department",
               "frustration",
               "refund",
               "team_name"
             ]
    end

    test "an override over call_classifier/2 + coerce/2 yields the generated path's struct" do
      script(%{"department" => "technical", "frustration" => 2})
      {:ok, generated} = TriageStep.execute(Context.detached(), input())

      script(%{"department" => "technical", "frustration" => 2})
      {:ok, overridden} = OverridingTriageStep.execute(Context.detached(), input())

      assert overridden == generated
    end
  end

  # ── call_classifier/2's question validation ─────────────────────────────────

  describe "call_classifier/2 question validation" do
    test "an id naming no Output field is refused before any call" do
      result = TriageStep.call_classifier(nil, input(questions: %{"nope" => question()}))

      assert result == {:error, {:invalid_questions, unknown: ["nope"]}}
      refute_received {:stub, _}
    end

    test "the reserved `answers` id is refused as unknown" do
      result = TriageStep.call_classifier(nil, input(questions: %{"answers" => question()}))

      assert result == {:error, {:invalid_questions, unknown: ["answers"]}}
      refute_received {:stub, _}
    end

    test "an empty question map is refused" do
      assert TriageStep.call_classifier(nil, input(questions: %{})) ==
               {:error, {:invalid_questions, empty: []}}

      refute_received {:stub, _}
    end

    test "an atom and a string key collapsing to one id are refused as duplicates" do
      questions = %{:department => question(), "department" => question()}

      assert TriageStep.call_classifier(nil, input(questions: questions)) ==
               {:error, {:invalid_questions, duplicate: ["department"]}}

      refute_received {:stub, _}
    end

    test "unknown is reported before duplicate, de-duplicated and sorted" do
      questions = %{:zzz => question(), "zzz" => question(), :aaa => question()}

      assert TriageStep.call_classifier(nil, input(questions: questions)) ==
               {:error, {:invalid_questions, unknown: ["aaa", "zzz"]}}
    end

    test "a non-map questions/1 raises, naming the step and questions/1" do
      keyword_input = %{input() | questions: [department: question()]}

      message =
        assert_raise(ArgumentError, fn -> TriageStep.call_classifier(nil, keyword_input) end).message

      assert message =~ "#{inspect(TriageStep)}.questions/1 must return a map"
      refute_received {:stub, _}
    end
  end

  # ── coerce/2 ────────────────────────────────────────────────────────────────

  describe "coerce/2" do
    test "a yes_no answer into a boolean() field is a type mismatch" do
      answers = %{"flag" => ClassificationAnswer.new(type: :yes_no, yes_probability: 0.9)}

      assert MismatchStep.coerce(answers, 0) ==
               {:error, {:coerce, [flag: {:type_mismatch, :yes_no}]}}
    end

    test "a choice answer into a float() field is a type mismatch" do
      answers = %{"level" => ClassificationAnswer.new(type: :choice, choice: "high")}

      assert MismatchStep.coerce(answers, 0) ==
               {:error, {:coerce, [level: {:type_mismatch, :choice}]}}
    end

    test "a score answer into an integer() field is a type mismatch" do
      answers = %{"count" => ClassificationAnswer.new(type: :score, score: 2.0)}

      assert MismatchStep.coerce(answers, 0) ==
               {:error, {:coerce, [count: {:type_mismatch, :score}]}}
    end

    test "a score answer into an atom() field is a type mismatch" do
      answers = %{"department" => ClassificationAnswer.new(type: :score, score: 2.0)}

      assert TriageStep.coerce(answers, 0) ==
               {:error, {:coerce, [department: {:type_mismatch, :score}]}}
    end

    test "an absent answer leaves the field at its declared default" do
      assert {:ok, %Triage.Output{department: :unassigned}} = TriageStep.coerce(%{}, 0)
    end

    test "a choice answer with no choice leaves the field at its default, not :other" do
      answers = %{"department" => %ClassificationAnswer{type: :choice}}

      assert {:ok, %Triage.Output{department: :unassigned}} = TriageStep.coerce(answers, 0)
    end

    test "a score answer with no score leaves the field at its default" do
      answers = %{"frustration" => %ClassificationAnswer{type: :score}}

      assert {:ok, %Triage.Output{frustration: nil}} = TriageStep.coerce(answers, 0)
    end

    test "a yes_no answer with no probability leaves the field at its default" do
      answers = %{"refund" => %ClassificationAnswer{type: :yes_no}}

      assert {:ok, %Triage.Output{refund: nil}} = TriageStep.coerce(answers, 0)
    end
  end

  # ── Compile-time checks ─────────────────────────────────────────────────────

  describe "compile-time checks" do
    test "a missing state/1 is named" do
      {module, message} = compile_error(state: false)

      assert message =~ module
      assert message =~ "state/1"
    end

    test "a missing questions/1 is named" do
      {module, message} = compile_error(questions: false)

      assert message =~ module
      assert message =~ "questions/1"
    end

    test "an unknown option is named" do
      {module, message} = compile_error(use: "type: :t, engine: :e, schema_name: \"s\"")

      assert message =~ module
      assert message =~ ":schema_name"
    end

    test "a missing type: is named" do
      {module, message} = compile_error(use: "engine: :e")

      assert message =~ module
      assert message =~ "type:"
    end

    test "a missing engine: is named" do
      {module, message} = compile_error(use: "type: :t")

      assert message =~ module
      assert message =~ "engine:"
    end

    test "a non-atom engine: is named" do
      {module, message} = compile_error(use: "type: :t, engine: \"classifier\"")

      assert message =~ module
      assert message =~ "engine:"
      assert message =~ "must be an atom"
    end

    test "an `output:` that is not a schema module is named" do
      {module, message} = compile_error(use: "type: :t, engine: :e, output: Enum")

      assert message =~ module
      assert message =~ "output: Enum"
    end

    test "an `input:` that is not a struct module is named" do
      {module, message} = compile_error(use: "type: :t, engine: :e, input: Enum")

      assert message =~ module
      assert message =~ "input: Enum"
    end

    test "an Output field declaring wire: is refused" do
      {module, message} = compile_error(output: "field(:team, String.t(), wire: \"t\")")

      assert message =~ module
      assert message =~ "wire:"
      assert message =~ ":team"
    end

    test "an atom() Output field without values: is refused" do
      {module, message} = compile_error(output: "field(:team, atom())")

      assert message =~ module
      assert message =~ "values:"
      assert message =~ ":team"
    end

    test "the fixture shape compiles when nothing is wrong" do
      assert {{:module, _, _, _}, _} = compile_step([])
    end
  end

  @spec compile_error(keyword()) :: {String.t(), String.t()}
  defp compile_error(opts) do
    module = unique_name()
    {module, assert_raise(ArgumentError, fn -> compile_step(opts, module) end).message}
  end

  defp unique_name,
    do: "ALLM.Pipeline.ClassifyStepTest.Inline#{System.unique_integer([:positive])}"

  # A ClassifyStep under a unique module name; `opts` swap out one part.
  defp compile_step(opts, module \\ unique_name()) do
    use_opts = Keyword.get(opts, :use, "type: :t, engine: :e")
    output = Keyword.get(opts, :output, "field(:team, String.t())")

    state =
      if Keyword.get(opts, :state, true), do: "def state(%Input{text: t}), do: t", else: ""

    questions =
      if Keyword.get(opts, :questions, true), do: "def questions(_input), do: %{}", else: ""

    Code.eval_string("""
    defmodule #{module} do
      use ALLM.Pipeline.ClassifyStep, #{use_opts}

      input_schema do
        field(:text, String.t(), required: true)
      end

      output_schema do
        #{output}
      end

      #{state}
      #{questions}
    end
    """)
  end

  # ── Through the Executor ────────────────────────────────────────────────────

  describe "through the Executor" do
    setup do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ALLM.Pipeline.Config.repo(), shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      :ok
    end

    test "the Output casts and the answer structs persist in the step log" do
      script(%{"department" => "billing"})
      {:ok, run} = ALLM.Pipeline.Executor.create_pipeline_run("classify_step_executor")

      assert {:ok, step_log, %Triage.Output{department: :billing}} =
               ALLM.Pipeline.Executor.run_step(run, TriageStep, input(), nil, [])

      assert step_log.output_data["answers"]["department"]["choice"] == "billing"
    end
  end
end
