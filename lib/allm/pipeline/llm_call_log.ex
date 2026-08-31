defmodule ALLM.Pipeline.LLMCallLog do
  @moduledoc """
  Per-step collector for full LLM-call inputs/outputs.

  The `Executor` calls `activate/0` in the step process before `execute/2` and
  `drain/0` after; `AmesburyScraper.Transformers.LLMEngine.generate_structured/4`
  calls `record/1` for each call. The active collector pid lives in the step
  process's dictionary and is resolved from child tasks via the same
  `:"$callers"` walk `LLMEngine` uses for engine injection
  (`llm_engine.ex` `fetch_override/0` / `engine_in_dict/1`), so a future
  `Task.async`/`Task.async_stream` fan-out still records into the right step.

  ## Lifecycle

    1. `activate/0` — start an empty `Agent` collector and stash its pid in the
       current process's dictionary. No-op (returns `:ok`, stashes nothing) when
       logging is disabled.
    2. `record/1` — append one captured call entry. Resolves the collector via
       the current process dict, then the `:"$callers"` ancestor chain. No-op
       when no collector is reachable (logging off, or `record/1` called outside
       an activated step).
    3. `drain/0` — read the pid from the **current** process dict only (the step
       process that called `activate/0`), return entries in chronological order,
       stop the agent, and delete the dict key.

  ## Configuration

  Logging is on by default, governed by an explicit config key on this module:

      config :allm_pipeline, ALLM.Pipeline.LLMCallLog, enabled: true

  Set `enabled: false` to make `activate/0` and `record/1` zero-cost no-ops.
  """

  @process_key :llm_call_log

  @typedoc """
  One logical LLM call's captured input/output.

  Built by `LLMEngine.generate_structured/4`; the map carries the redacted
  `messages`, the `schema_name`, the requested `model` / `adapter` / `params`,
  and — depending on outcome — the raw `response_text` / `usage` /
  `finish_reason` / `served_model`, or an `error` string. The exact keys are
  owned by the recorder; this module treats entries as opaque maps.
  """
  @type entry :: %{optional(atom()) => term()}

  @doc """
  Whether LLM-call logging is enabled (default `true`).

  Reads `:enabled` from `config :allm_pipeline, #{inspect(__MODULE__)}`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:allm_pipeline, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @doc """
  Start a collector in the current process and stash its pid in the process
  dictionary. No-op when logging is disabled. Always returns `:ok`.
  """
  @spec activate() :: :ok
  def activate do
    if enabled?() do
      {:ok, pid} = Agent.start(fn -> [] end)
      Process.put(@process_key, pid)
    end

    :ok
  end

  @doc """
  Append `entry` to the active collector for the current step.

  Resolves the collector pid via the current process dict, then the
  `:"$callers"` ancestor chain. No-op when none is reachable.
  """
  @spec record(entry()) :: :ok
  def record(entry) do
    case resolve_collector() do
      nil ->
        :ok

      pid ->
        Agent.update(pid, &[entry | &1])
    end
  end

  @doc """
  Drain the current step's collector: return its entries in chronological
  order, stop the agent, and delete the dict key. Returns `[]` when no
  collector is active on the current process.
  """
  @spec drain() :: [entry()]
  def drain do
    case Process.delete(@process_key) do
      pid when is_pid(pid) ->
        entries = Agent.get(pid, &Enum.reverse/1)
        Agent.stop(pid)
        entries

      _ ->
        []
    end
  end

  # Look up the collector pid on the current process, then walk the
  # `:"$callers"` ancestor chain that `Task.async`/`Task.async_stream`
  # propagate. Returns `nil` when no collector is installed anywhere in the
  # chain. Mirrors `LLMEngine.fetch_override/0`.
  @spec resolve_collector() :: pid() | nil
  defp resolve_collector do
    case Process.get(@process_key) do
      pid when is_pid(pid) ->
        pid

      _ ->
        :"$callers"
        |> Process.get([])
        |> Enum.find_value(&collector_in_dict/1)
    end
  end

  @spec collector_in_dict(pid()) :: pid() | nil
  defp collector_in_dict(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case List.keyfind(dict, @process_key, 0) do
          {@process_key, pid} when is_pid(pid) -> pid
          _ -> nil
        end

      nil ->
        nil
    end
  end
end
