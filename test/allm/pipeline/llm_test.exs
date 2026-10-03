defmodule ALLM.Pipeline.LLMTest do
  @moduledoc """
  `ALLM.Pipeline.LLM`'s dispatch helpers — which arity of a host adapter's
  callback the package calls.

  **Not `async: true`**, though no test here touches application env (every
  helper takes the adapter explicitly): the lazy-load test purges loaded code,
  which is global to the VM.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.{Context, LLM}
  alias ALLM.Pipeline.TestSupport.LazyLLMAdapter

  # No `@behaviour` on these doubles: the helpers take the adapter as an
  # argument and dispatch on exports alone, and a partial adapter is exactly
  # the subject under test.

  defmodule LegacyOnly do
    @moduledoc false
    def resolve_engine(name), do: {:legacy, name}

    def generate_structured(prompt, schema, name, engine),
      do: {:legacy, prompt, schema, name, engine}
  end

  defmodule ContextAware do
    @moduledoc false
    def resolve_engine(_name), do: raise("resolve_engine/1 must not be called")
    def resolve_engine(name, ctx), do: {:context, name, ctx}

    def generate_structured(_prompt, _schema, _name, _engine),
      do: raise("generate_structured/4 must not be called")

    def generate_structured(prompt, schema, name, engine, ctx),
      do: {:context, prompt, schema, name, engine, ctx}
  end

  # Needs the override but not the account: each helper picks independently.
  defmodule Mixed do
    @moduledoc false
    def resolve_engine(_name), do: raise("resolve_engine/1 must not be called")
    def resolve_engine(name, ctx), do: {:context, name, ctx}

    def generate_structured(prompt, schema, name, engine),
      do: {:legacy, prompt, schema, name, engine}
  end

  # Exports `classify/4` and nothing else the classify helper could reach. It
  # reports its arguments and returns whatever the test put under
  # `:classify_return` (a contract-conforming error by default).
  defmodule Classifier do
    @moduledoc false
    def classify(state, questions, engine, ctx) do
      send(self(), {:classify, state, questions, engine, ctx})
      Process.get(:classify_return, {:error, :scripted})
    end
  end

  # Exports every OTHER seam function, each reporting a call — so a helper that
  # dispatched anywhere before refusing would be observed.
  defmodule NoClassify do
    @moduledoc false
    def resolve_engine(name), do: report({:resolve_engine, name})
    def resolve_engine(name, _ctx), do: report({:resolve_engine, name})
    def generate_structured(p, _s, _n, _e), do: report({:generate_structured, p})
    def generate_structured(p, _s, _n, _e, _ctx), do: report({:generate_structured, p})
    defp report(call), do: send(self(), {:unexpected_call, call})
  end

  # The intended host shape: a one-line delegation to `ALLM.classify/3`.
  defmodule DelegatingClassifier do
    @moduledoc false
    def classify(state, questions, engine, _ctx),
      do: ALLM.classify(engine, state, questions: questions)
  end

  @ctx Context.detached(engines: %{nano: :override}, account_id: "acct")

  describe "__resolve_engine__/3" do
    test "an adapter exporting only resolve_engine/1 gets /1" do
      assert LLM.__resolve_engine__(LegacyOnly, :nano, @ctx) == {:legacy, :nano}
    end

    test "an adapter exporting resolve_engine/2 gets /2, with the exact context" do
      assert {:context, :nano, ctx} = LLM.__resolve_engine__(ContextAware, :nano, @ctx)
      assert ctx === @ctx
    end

    test "a not-yet-loaded adapter is loaded before its exports are consulted" do
      # Precondition: unloaded, so a bare `function_exported?/3` answers false.
      :code.purge(LazyLLMAdapter)
      :code.delete(LazyLLMAdapter)
      :code.purge(LazyLLMAdapter)
      refute function_exported?(LazyLLMAdapter, :resolve_engine, 2)

      assert {:context, :nano, ctx} = LLM.__resolve_engine__(LazyLLMAdapter, :nano, @ctx)
      assert ctx === @ctx
    end
  end

  describe "__generate_structured__/6" do
    test "an adapter exporting only generate_structured/4 gets /4" do
      assert LLM.__generate_structured__(LegacyOnly, "p", %{"s" => 1}, "name", :eng, @ctx) ==
               {:legacy, "p", %{"s" => 1}, "name", :eng}
    end

    test "an adapter exporting generate_structured/5 gets /5, with the exact context" do
      assert {:context, "p", %{"s" => 1}, "name", :eng, ctx} =
               LLM.__generate_structured__(ContextAware, "p", %{"s" => 1}, "name", :eng, @ctx)

      assert ctx === @ctx
    end
  end

  test "dispatch is per callback: resolve_engine/2 alongside generate_structured/4" do
    assert {:context, :nano, _ctx} = LLM.__resolve_engine__(Mixed, :nano, @ctx)

    assert LLM.__generate_structured__(Mixed, "p", %{}, "name", :eng, @ctx) ==
             {:legacy, "p", %{}, "name", :eng}
  end

  describe "__context__/1" do
    test "a context passes through unchanged" do
      assert LLM.__context__(@ctx) === @ctx
    end

    test "a bare map becomes an empty detached context" do
      assert LLM.__context__(%{}) == %Context{opts: []}
    end

    test "nil becomes an empty detached context" do
      assert LLM.__context__(nil) == %Context{opts: []}
    end

    test "a foreign struct is rejected, not normalized" do
      assert_raise FunctionClauseError, fn -> LLM.__context__(%URI{}) end
    end
  end

  describe "__classify__/5" do
    @question ALLM.ClassificationQuestion.choice("Which team?", ["billing", "technical"])

    test "an adapter exporting classify/4 gets every argument and the exact context" do
      questions = %{"team" => @question}

      LLM.__classify__(Classifier, "text", questions, :eng, @ctx)

      assert_received {:classify, "text", seen_questions, :eng, ctx}
      assert seen_questions === questions
      assert ctx === @ctx
    end

    test "an adapter's error is returned unchanged" do
      reason = %{why: make_ref()}
      Process.put(:classify_return, {:error, reason})
      assert LLM.__classify__(Classifier, %{"a" => 1}, %{}, :eng, @ctx) === {:error, reason}
    end

    test "an adapter's response is returned unchanged" do
      ok =
        {:ok,
         %ALLM.ClassificationResponse{answers: %{}, request_id: "req-#{System.unique_integer()}"}}

      Process.put(:classify_return, ok)
      assert LLM.__classify__(Classifier, "text", %{}, :eng, @ctx) === ok
    end

    test "a success that is not a ClassificationResponse raises, naming the adapter" do
      Process.put(:classify_return, {:ok, %{answers: %{}}})

      message =
        assert_raise(ArgumentError, fn ->
          LLM.__classify__(Classifier, "text", %{}, :eng, @ctx)
        end).message

      assert message =~ inspect(Classifier)
      assert message =~ "ALLM.ClassificationResponse"
    end

    test "a non-tuple return raises, naming the adapter — never a CaseClauseError" do
      Process.put(:classify_return, :ok)

      message =
        assert_raise(ArgumentError, fn ->
          LLM.__classify__(Classifier, "text", %{}, :eng, @ctx)
        end).message

      assert message =~ "#{inspect(Classifier)}.classify/4 returned :ok"
    end

    test "an adapter without classify/4 raises, naming the adapter and the callback" do
      message =
        assert_raise(RuntimeError, fn ->
          LLM.__classify__(NoClassify, "text", %{"team" => @question}, :eng, @ctx)
        end).message

      assert message =~ "classify/4"
      assert message =~ inspect(NoClassify)
      assert message =~ "ALLM.classify/3"
    end

    test "an adapter without classify/4 is not called at all before the raise" do
      assert_raise RuntimeError, fn ->
        LLM.__classify__(NoClassify, "text", %{"team" => @question}, :eng, @ctx)
      end

      refute_received {:unexpected_call, _}
    end

    test "an adapter that fails to load is named as a load failure" do
      message =
        assert_raise(RuntimeError, fn ->
          LLM.__classify__(ALLM.Pipeline.NoSuchAdapter, "text", %{}, :eng, @ctx)
        end).message

      assert message =~ "ALLM.Pipeline.NoSuchAdapter"
      assert message =~ ":nofile"
      refute message =~ "does not export"
    end

    test "a delegating adapter returns ALLM 0.6.0's own response" do
      engine =
        ALLM.Engine.new(
          classification_adapter: ALLM.Providers.FakeClassification,
          adapter_opts: [classification_script: [{:answers, %{"team" => "billing"}}]]
        )

      assert {:ok, %ALLM.ClassificationResponse{} = response} =
               LLM.__classify__(
                 DelegatingClassifier,
                 "My card was charged twice.",
                 %{"team" => @question},
                 engine,
                 @ctx
               )

      assert %ALLM.ClassificationAnswer{type: :choice, choice: "billing"} =
               response.answers["team"]
    end
  end

  test "the context-taking callbacks and classify/4 are exactly the optional ones" do
    assert Enum.sort(LLM.behaviour_info(:optional_callbacks)) ==
             Enum.sort(classify: 4, generate_structured: 5, resolve_engine: 2)
  end
end
