defmodule ALLM.Pipeline.Telemetry do
  @moduledoc """
  The `[:allm_pipeline, …]` telemetry event contract, plus thin `emit_*`
  helpers wrapping `:telemetry.execute/3`.

  This module is the normative home for the event names; the architecture doc
  (§3.7) is the source. A host attaches `:telemetry` handlers to these names —
  `ALLM.Pipeline.Metrics.attach_step_handler/0` attaches the one built-in
  handler (populates `step_logs.queue_time_ms`).

  ## Events

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:allm_pipeline, :run, :start]` | `%{}` | `%{name, run_id, trigger}` |
  | `[:allm_pipeline, :run, :stop]` | `%{duration}` | `%{name, run_id, trigger, status}` |
  | `[:allm_pipeline, :run, :exception]` | `%{duration}` | `%{name, run_id, kind, reason}` |
  | `[:allm_pipeline, :step, :start]` | `%{}` | `%{step_type, run_id, step_id}` |
  | `[:allm_pipeline, :step, :stop]` | `%{duration, queue_time}` | `%{step_type, status, run_id, step_id}` |
  | `[:allm_pipeline, :step, :exception]` | `%{duration, queue_time}` | `%{step_type, run_id, step_id, kind, reason}` |
  | `[:allm_pipeline, :artifact, :store]` | `%{bytes, compressed_bytes}` | `%{adapter, outcome}` |

  ## Units

  `duration` and `queue_time` are in **native time units** (the `:telemetry`
  convention — `System.monotonic_time/0`). A consumer converts with
  `System.convert_time_unit(value, :native, :millisecond)`; the built-in
  `queue_time_ms` handler does exactly that. `queue_time` is `nil` on a plain
  (non-`fan_out`) step, which has no queue.

  ## `queue_time` is the backlog wait, not `started_at - inserted_at`

  `ALLM.Pipeline.StepLog.log_start/4` inserts the row with `status: :running`
  **and** `started_at: now` in the *same* op, so `started_at - inserted_at` is
  structurally ~0 for every real step — there is no `:pending`→`:running`
  step-log lifecycle. `queue_time` is instead measured from the **fan-out
  stage's dispatch timestamp** (captured once in `ALLM.Pipeline.Dsl.Runtime`
  before `Task.async_stream` schedules items) threaded into each item's
  `Context`: `queue_time = worker_start - fan_out_dispatch`. It is non-zero for
  every item after the first, even at `concurrency: 1` (item K waits for items
  1..K-1). A plain single stage has no queue, so its `queue_time` is `nil` and
  that is honest, not vacuous — the metric is meaningful only on fan-outs.

  ## Consumer accounting (earn-its-keep — `ALLM_PIPELINE_DSL.md` §6)

  - `[:allm_pipeline, :step, :stop]` has a **named consumer**:
    `ALLM.Pipeline.Metrics.attach_step_handler/0`, which reads `queue_time` and
    writes `step_logs.queue_time_ms`.
  - The `:run`, `:step, :start`, `:step, :exception` and `:artifact` families
    ship as a **deliberately consumer-less public integration surface**. That is
    defensible for a telemetry *contract* — its whole value is that a host can
    attach later without a framework change — but it is stated here rather than
    silently exempted from the earn-its-keep rule the DSL invokes everywhere
    else. Run stop/exception fire at the canonical settle point
    (`ALLM.Pipeline.Lifecycle.settle/4`, the DSL + `owned_run/4` path); a
    hand-written entry point that settles through `Executor.finish_run/2`
    instead emits `:run, :start` only. Reopening: a consumer that needs full run
    coverage routes the remaining tails through the settle point.

  ## `[:allm_pipeline, :llm, :call]` is DROPPED from this phase

  LLM telemetry already flows one layer down, at the ALLM-hex layer:
  `[:allm, :generate, :stop]` / `[:allm, :chat, :stop]`, to which
  `AmesburyScraper.Transformers.LLMTelemetry` is already attached (per-call
  model / tokens / duration). The per-*step* token aggregate is already
  persisted on `step_logs.llm_total_tokens` / `llm_call_count` and surfaced in
  the review UI. No consumer needs a per-step LLM telemetry event distinct from
  those two existing surfaces, so emitting one would be a consumer-less
  duplicate of the summed per-call events. Dropped per earn-its-keep. Reopening
  trigger: a live per-step LLM aggregate stream is needed distinct from the
  persisted columns.
  """

  @run_start [:allm_pipeline, :run, :start]
  @run_stop [:allm_pipeline, :run, :stop]
  @run_exception [:allm_pipeline, :run, :exception]
  @step_start [:allm_pipeline, :step, :start]
  @step_stop [:allm_pipeline, :step, :stop]
  @step_exception [:allm_pipeline, :step, :exception]
  @artifact_store [:allm_pipeline, :artifact, :store]

  @doc "The `[:allm_pipeline, :step, :stop]` event name (the queue_time handler attaches to it)."
  @spec step_stop_event() :: [atom(), ...]
  def step_stop_event, do: @step_stop

  @doc "The `[:allm_pipeline, :step, :start]` event name."
  @spec step_start_event() :: [atom(), ...]
  def step_start_event, do: @step_start

  @doc "The `[:allm_pipeline, :step, :exception]` event name."
  @spec step_exception_event() :: [atom(), ...]
  def step_exception_event, do: @step_exception

  @doc "The `[:allm_pipeline, :run, :start]` event name."
  @spec run_start_event() :: [atom(), ...]
  def run_start_event, do: @run_start

  @doc "The `[:allm_pipeline, :run, :stop]` event name."
  @spec run_stop_event() :: [atom(), ...]
  def run_stop_event, do: @run_stop

  @doc "The `[:allm_pipeline, :run, :exception]` event name."
  @spec run_exception_event() :: [atom(), ...]
  def run_exception_event, do: @run_exception

  @doc "The `[:allm_pipeline, :artifact, :store]` event name."
  @spec artifact_store_event() :: [atom(), ...]
  def artifact_store_event, do: @artifact_store

  @doc "Emit `[:allm_pipeline, :run, :start]`."
  @spec run_start(map()) :: :ok
  def run_start(metadata), do: :telemetry.execute(@run_start, %{}, metadata)

  @doc "Emit `[:allm_pipeline, :run, :stop]`."
  @spec run_stop(map(), map()) :: :ok
  def run_stop(measurements, metadata), do: :telemetry.execute(@run_stop, measurements, metadata)

  @doc "Emit `[:allm_pipeline, :run, :exception]`."
  @spec run_exception(map(), map()) :: :ok
  def run_exception(measurements, metadata),
    do: :telemetry.execute(@run_exception, measurements, metadata)

  @doc "Emit `[:allm_pipeline, :step, :start]`."
  @spec step_start(map()) :: :ok
  def step_start(metadata), do: :telemetry.execute(@step_start, %{}, metadata)

  @doc "Emit `[:allm_pipeline, :step, :stop]`."
  @spec step_stop(map(), map()) :: :ok
  def step_stop(measurements, metadata),
    do: :telemetry.execute(@step_stop, measurements, metadata)

  @doc "Emit `[:allm_pipeline, :step, :exception]`."
  @spec step_exception(map(), map()) :: :ok
  def step_exception(measurements, metadata),
    do: :telemetry.execute(@step_exception, measurements, metadata)

  @doc "Emit `[:allm_pipeline, :artifact, :store]`."
  @spec artifact_store(map(), map()) :: :ok
  def artifact_store(measurements, metadata),
    do: :telemetry.execute(@artifact_store, measurements, metadata)
end
