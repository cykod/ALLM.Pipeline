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

  test "the context-taking callbacks are exactly the optional ones" do
    assert Enum.sort(LLM.behaviour_info(:optional_callbacks)) ==
             Enum.sort(resolve_engine: 2, generate_structured: 5)
  end
end
