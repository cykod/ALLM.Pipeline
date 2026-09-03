defmodule ALLM.Pipeline.Step do
  @moduledoc """
  Behavior for pipeline steps with strongly-typed inputs and outputs.

  Each step declares its input/output types and produces artifacts.
  Steps are the atomic units of work in the scraping pipeline.

  ## Input/Output Schemas

  Input and output schemas are structs. `use ALLM.Pipeline.Schema` generates
  one from a field declaration — the struct, its `@type t`, `@enforce_keys`,
  `cast/1` and the introspection the `ALLM.Pipeline.Executor` and
  `ALLM.Pipeline.StepLog` read — and a plain `defstruct` is accepted too.

  ## Example Implementation

  `use ALLM.Pipeline.Step` injects the behaviour and imports
  `ALLM.Pipeline.Schema.input_schema/2` and `output_schema/2`, which declare the
  nested schema modules inline and derive `input_schema/0` / `output_schema/0`
  from them:

      defmodule MyStep do
        use ALLM.Pipeline.Step

        input_schema do
          field :url, String.t(), required: true
        end

        output_schema do
          field :result, String.t(), required: true
          field :html, String.t(), artifact: true
        end

        @impl true
        def step_type, do: :my_step

        @impl true
        def execute(_context, %Input{} = input) do
          # Process input and return output
          {:ok, %Output{result: "processed", html: fetch(input.url)}}
        end

        # Optional: Store artifacts
        @impl true
        def artifact_content_type, do: "text/html"

        @impl true
        def artifact_content(%Output{html: html}), do: html
      end

  Both declarations are optional and independent: declare either block by hand
  as a nested (or separate-file) module and write its accessor yourself, which
  is what a schema shared by two steps requires. `@behaviour
  ALLM.Pipeline.Step` without the `use` remains valid and generates nothing.

      defmodule MyStep do
        @behaviour ALLM.Pipeline.Step

        @impl true
        def input_schema, do: MyApp.Schemas.PageInput

        # ...
      end
  """

  @typedoc """
  What a step receives as its first argument: an `ALLM.Pipeline.Context` struct.

  `ALLM.Pipeline.Executor.run_with_step_log/5` always builds this struct, so the
  type names it rather than a bare `%{pipeline_run: …, step_log: …}` map — which
  is both weaker and, because `step_log` is nilable for escape-hatch bodies,
  wrong. A struct is a map, so this narrows nothing at runtime and is
  dialyzer-visible only.
  """
  @type context :: ALLM.Pipeline.Context.t()
  @type execute_result :: {:ok, output :: struct()} | {:error, reason :: term()}

  @doc "The step type identifier (e.g., :fetch_page)"
  @callback step_type() :: atom()

  @doc "The struct module for input (plain Elixir struct with typespecs)"
  @callback input_schema() :: module()

  @doc "The struct module for output (plain Elixir struct with typespecs)"
  @callback output_schema() :: module()

  @doc "Execute the step with validated input, return validated output"
  @callback execute(context(), input :: struct()) :: execute_result()

  @doc "Optional: artifact content type for storage (e.g., 'text/html', 'application/json')"
  @callback artifact_content_type() :: String.t()

  @doc "Optional: extract artifact content from output for storage"
  @callback artifact_content(output :: struct()) :: binary() | nil

  @optional_callbacks [artifact_content_type: 0, artifact_content: 1]

  @doc """
  Injects the behaviour and the inline schema declarations.

  Generates nothing on its own. It imports `ALLM.Pipeline.Schema.input_schema/2`
  and `output_schema/2`, and derives `input_schema/0` / `output_schema/0` from
  whichever of the two blocks the module declares — a block and a hand-written
  accessor of the same name is a compile error naming the module, since only one
  of them can win.

  Takes no options: everything else a step declares (`step_type/0`,
  `execute/2`, the optional artifact callbacks) is behaviour it writes itself.
  """
  defmacro __using__(opts) do
    __validate__!(__CALLER__.module, opts)

    quote do
      @behaviour ALLM.Pipeline.Step
      @before_compile ALLM.Pipeline.Step

      import ALLM.Pipeline.Schema,
        only: [input_schema: 1, input_schema: 2, output_schema: 1, output_schema: 2]
    end
  end

  @doc false
  @spec __validate__!(module(), term()) :: :ok
  def __validate__!(module, opts) do
    if opts == [] do
      :ok
    else
      raise ArgumentError,
            "#{inspect(module)}: `use ALLM.Pipeline.Step` takes no options, got: " <>
              "#{inspect(opts)}. An LLM-calling step declares its type, engine and wire " <>
              "schema through `use ALLM.Pipeline.LLMStep` instead."
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    input = accessor(env, :allm_pipeline_input_schema, :input_schema)
    output = accessor(env, :allm_pipeline_output_schema, :output_schema)

    quote do
      unquote(input)
      unquote(output)
    end
  end

  # The attribute is written by `ALLM.Pipeline.Schema.input_schema/2` and
  # `output_schema/2`, so an accessor is generated only where a block actually
  # declared the module — never by the mere existence of a nested `Input`, which
  # a step is free to point its accessor away from.
  @spec accessor(Macro.Env.t(), atom(), atom()) :: Macro.t()
  defp accessor(env, attribute, name) do
    case Module.get_attribute(env.module, attribute) do
      nil ->
        quote do
        end

      schema ->
        assert_accessor_free!(env.module, name)

        quote do
          @impl ALLM.Pipeline.Step
          @spec unquote(name)() :: module()
          def unquote(name)(), do: unquote(schema)
        end
    end
  end

  # Two `def #{name}/0` clauses defined apart would otherwise be a
  # "clauses with the same name and arity must be grouped" warning against
  # generated code, blaming the wrong module and saying nothing about the block.
  @spec assert_accessor_free!(module(), atom()) :: :ok
  defp assert_accessor_free!(module, name) do
    if Module.defines?(module, {name, 0}) do
      raise ArgumentError,
            "#{inspect(module)}: `#{name} do … end` generates `#{name}/0`, and this module " <>
              "also defines that function by hand. Keep one — drop the `def #{name}/0` to " <>
              "use the generated module, or drop the block and declare the schema module " <>
              "yourself."
    end

    :ok
  end

  @doc """
  Check if a module implements the Step behavior.
  """
  @spec implements?(module()) :: boolean()
  def implements?(module) do
    behaviours = module.module_info(:attributes)[:behaviour] || []
    __MODULE__ in behaviours
  end

  @doc """
  Check if a step module produces artifacts.
  """
  @spec produces_artifact?(module()) :: boolean()
  def produces_artifact?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :artifact_content_type, 0) and
      function_exported?(module, :artifact_content, 1)
  end
end
