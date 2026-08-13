defmodule ALLM.Pipeline.Step do
  @moduledoc """
  Behavior for pipeline steps with strongly-typed inputs and outputs.

  Each step declares its input/output types and produces artifacts.
  Steps are the atomic units of work in the scraping pipeline.

  ## Input/Output Schemas

  Input and output schemas are plain Elixir structs with typespecs.
  Use `@enforce_keys` for required fields and `@derive Jason.Encoder`
  for output schemas that need JSON serialization.

  ## Example Implementation

      defmodule MyStep do
        @behaviour ALLM.Pipeline.Step

        defmodule Input do
          @enforce_keys [:url]
          defstruct [:url]
          @type t :: %__MODULE__{url: String.t()}
        end

        defmodule Output do
          @derive Jason.Encoder
          @enforce_keys [:result]
          defstruct [:result]
          @type t :: %__MODULE__{result: String.t()}
        end

        @impl true
        def step_type, do: :my_step

        @impl true
        def input_schema, do: __MODULE__.Input

        @impl true
        def output_schema, do: __MODULE__.Output

        @impl true
        def execute(_context, %Input{} = input) do
          # Process input and return output
          {:ok, %Output{result: "processed"}}
        end

        # Optional: Store artifacts
        @impl true
        def artifact_content_type, do: "text/html"

        @impl true
        def artifact_content(%Output{html: html}), do: html
      end
  """

  @type context :: %{
          pipeline_run: ALLM.Pipeline.PipelineRun.t(),
          step_log: ALLM.Pipeline.StepLog.t()
        }
  @type execute_result :: {:ok, output :: struct()} | {:error, reason :: term()}

  @doc "The step type identifier (e.g., :scrape_committee_list)"
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
