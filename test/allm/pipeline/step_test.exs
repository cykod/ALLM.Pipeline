defmodule ALLM.Pipeline.StepTest do
  @moduledoc """
  `use ALLM.Pipeline.Step` — the behaviour injection and the two accessors it
  derives from an inline schema block.

  What the blocks themselves generate is `ALLM.Pipeline.SchemaTest`'s
  ("`input_schema`/`output_schema` declare the nested module"); this file is
  only what the `use` adds on top, and every case compiles a real module rather
  than calling the macro, because the whole contract is a compile-time one.
  """

  use ExUnit.Case, async: true

  describe "the accessors are derived from the blocks" do
    defmodule Declared do
      @moduledoc false
      use ALLM.Pipeline.Step

      input_schema do
        field(:url, String.t(), required: true)
      end

      output_schema do
        field(:records, [map()], required: true)
        field(:raw_html, String.t(), artifact: true)
      end

      @impl true
      def step_type, do: :declared

      # The short `Input`/`Output` aliases resolve here — the generated
      # `defmodule` nests under this module and registers them, which is the
      # whole reason the block is written as an alias rather than a computed
      # module name.
      @impl true
      def execute(_context, %Input{url: url}) do
        {:ok, %Output{records: [%{"url" => url}], raw_html: "<html/>"}}
      end
    end

    test "input_schema/0 and output_schema/0 name the generated modules" do
      assert Declared.input_schema() == ALLM.Pipeline.StepTest.Declared.Input
      assert Declared.output_schema() == ALLM.Pipeline.StepTest.Declared.Output
    end

    test "the generated modules are ALLM.Pipeline.Schema modules, not bare structs" do
      assert Declared.Input.__allm_schema__(:required) == [:url]
      assert Declared.Output.__allm_schema__(:artifact) == [:raw_html]
    end

    test "the `use` injects the behaviour, so the census sees a Step" do
      assert ALLM.Pipeline.Step.implements?(Declared)
    end

    test "the aliases reach the step body" do
      assert {:ok, output} = Declared.execute(nil, %Declared.Input{url: "https://example.test"})
      assert output.records == [%{"url" => "https://example.test"}]
    end
  end

  describe "a block and a hand-written accessor" do
    defmodule HalfDeclared do
      @moduledoc false
      use ALLM.Pipeline.Step

      defmodule Elsewhere do
        @moduledoc false
        use ALLM.Pipeline.Schema

        schema do
          field(:count, integer())
        end
      end

      input_schema do
        field(:url, String.t(), required: true)
      end

      @impl true
      def step_type, do: :half_declared

      @impl true
      def output_schema, do: __MODULE__.Elsewhere

      @impl true
      def execute(_context, _input), do: {:ok, %Elsewhere{count: 0}}
    end

    test "each half is independent — a declared block and a hand-written accessor coexist" do
      assert HalfDeclared.input_schema() == ALLM.Pipeline.StepTest.HalfDeclared.Input
      assert HalfDeclared.output_schema() == ALLM.Pipeline.StepTest.HalfDeclared.Elsewhere
    end

    test "declaring the block AND the accessor of the same name is refused" do
      # Two `def input_schema/0` clauses defined apart are otherwise a
      # "clauses with the same name and arity must be grouped" warning against
      # generated code — which names neither the block nor the conflict.
      message =
        assert_raise(ArgumentError, fn ->
          compile_step("""
          input_schema do
            field(:url, String.t())
          end

          @impl true
          def input_schema, do: __MODULE__.Somewhere
          """)
        end).message

      assert message =~ "input_schema do"
      assert message =~ "input_schema/0"
    end
  end

  describe "`use ALLM.Pipeline.Step` options" do
    test "it takes none, and says where a type: belongs" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_step("", ", type: :typed")
        end).message

      assert message =~ "takes no options"
      assert message =~ "ALLM.Pipeline.LLMStep"
    end
  end

  # A throwaway module under a unique name: a reused name is a redefinition, and
  # the second run would observe the FIRST module.
  @spec compile_step(String.t(), String.t()) :: term()
  defp compile_step(body, use_options \\ "") do
    module = "ALLM.Pipeline.StepTest.Generated#{System.unique_integer([:positive])}"

    Code.eval_string("""
    defmodule #{module} do
      use ALLM.Pipeline.Step#{use_options}

      #{body}
    end
    """)
  end
end
