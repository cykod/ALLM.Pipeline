defmodule ALLM.Pipeline.Context do
  @moduledoc """
  Pipeline execution context passed to each step.

  Contains the current pipeline run and step log, allowing steps
  to access pipeline-level information and log additional data.
  """

  alias ALLM.Pipeline.{PipelineRun, StepLog}

  @type t :: %__MODULE__{
          pipeline_run: PipelineRun.t(),
          step_log: StepLog.t(),
          opts: keyword()
        }

  defstruct [:pipeline_run, :step_log, opts: []]

  @doc """
  Create a new context for a step execution.
  """
  @spec new(PipelineRun.t(), StepLog.t(), keyword()) :: t()
  def new(pipeline_run, step_log, opts \\ []) do
    %__MODULE__{
      pipeline_run: pipeline_run,
      step_log: step_log,
      opts: opts
    }
  end

  @doc """
  Get the pipeline run ID from context.
  """
  @spec pipeline_run_id(t()) :: Ecto.UUID.t()
  def pipeline_run_id(%__MODULE__{pipeline_run: %{id: id}}), do: id

  @doc """
  Get the current step log ID from context.
  """
  @spec step_log_id(t()) :: Ecto.UUID.t()
  def step_log_id(%__MODULE__{step_log: %{id: id}}), do: id

  @doc """
  Get an option from context.
  """
  @spec get_opt(t(), atom(), term()) :: term()
  def get_opt(%__MODULE__{opts: opts}, key, default \\ nil) do
    Keyword.get(opts, key, default)
  end
end
