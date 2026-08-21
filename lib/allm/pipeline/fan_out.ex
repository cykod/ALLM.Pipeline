defmodule ALLM.Pipeline.FanOut do
  @moduledoc """
  The canonical home for this repo's fan-out safety rule, plus the one helper
  every `Task.async_stream` site shares.

  ## The rule (measured, do not re-derive)

  `Task.async_stream` **links** its children. With `trap_exit` off — every
  process in this repo; `grep -rn "trap_exit" apps/` finds no `Process.flag/2`
  call — a child that raises **or** exits kills the *calling* process before the
  stream can emit anything for that element. With `trap_exit` on it emits
  `{:exit, reason}` normally.

  Two consequences, and they point in opposite directions:

  1. **An `{:exit, _}` clause in the consumer is dead code.** Neither an
     `Enum.reduce` clause nor an `Enum.map` head can run for a dead child,
     because the caller is already gone. Adding one is not a fix; it reads as
     one, which is worse. Consumers may therefore unpack `{:ok, result}`
     exhaustively, provided (2) holds.
  2. **The fix belongs in the CHILD.** Wrap the per-item work in
     `catch kind, reason` so it never dies at all, and degrade to whatever
     per-item failure value the caller already handles. `rescue` alone is
     **not** sufficient — an exit is not an exception, so `rescue` never sees
     it, and `GenServer.call` timeouts (Playwright, the browser manager) and
     `Task` deaths surface as exits.

  Measured 2026-08-13 (n = 8 probes, Elixir 1.17.3/OTP 27) and independently by
  Phase RS for `AmesburyScraper.Services.ProjectScaleRescale.rescore/3`. Scope
  is the mechanism, not any particular call site. It does **not** license
  removing an existing `catch` — that is what keeps the child alive.

  ## Sites

  Every `Task.async_stream` **in this repo** — both trees, not just the host's —
  either fans out work that is total by construction, or wraps its per-item work
  in a `catch`:

  | Site | How it is kept safe |
  |---|---|
  | `ALLM.Pipeline.Dsl.Runtime.run_concurrent/7` | always-on `catch` via `guarded_item/7` — the concurrent path passes `true` unconditionally, which is link safety rather than the `catch_item_failures:` policy |
  | `Scrapers.HttpScraper.fetch_many/2` | `safe_fetch/2` (`catch`) |
  | `Pipelines.PoiThumbnailStep.generate_for_pois/6` | `safe_generate_one/7` (`catch`) |
  | `Processors.DocumentTextCollector.execute/2` | `safe_collect_text/1` (`catch`) |
  | `Services.ProjectScaleRescale.run/1` | `rescore/3` (`rescue` + `catch`) |

  A sequential sibling, `Pipelines.ProjectRefreshPipeline.safe_run/2`, uses the
  same `catch` for the same reason (an exit is not an exception) even though it
  has no link hazard.

  `Pipelines.CommitteePipeline` carried three rows here until Phase 4.4 ported
  it onto `use ALLM.Pipeline`. Its detail, transform and load fan-outs are now
  the framework's single site above — which is the DSL centralizing fan-out, and
  a **behaviour change** for that pipeline, since its hand-written fan-outs
  deliberately wrapped nothing. That change is declared in `CommitteePipeline`'s
  own moduledoc.

  The table's MEMBERSHIP is machine-guarded by
  `apps/allm_pipeline/test/allm/pipeline/fan_out_test.exs`, which scans both
  `lib/` trees and fails by name when the site set changes. What it cannot check
  is the right-hand column — how each site is kept safe — so a new fan-out still
  has to add its own row by hand.
  """

  require Logger

  @typedoc """
  A per-item failure that escaped every named error path. Persisted through the
  caller's own error shape; `inspect`ed to a string before it reaches jsonb.
  """
  @type uncaught :: {:uncaught, kind :: atom(), reason :: term()}

  @doc """
  Log an uncaught per-item failure with its stacktrace and return a tagged tuple.

  Call from inside a `catch kind, reason ->` clause, where `__STACKTRACE__` is
  available. These handlers exist for failures nobody anticipated, so the
  stacktrace is the whole value — the fact of the failure is already implied by
  the degraded result.

  `label` should identify the item (a URL, an index, a record id), not the
  module — the message reads `"<label> aborted with <kind> <reason>"`.
  """
  @spec tag_uncaught(String.t(), atom(), term(), Exception.stacktrace()) :: uncaught()
  def tag_uncaught(label, kind, reason, stacktrace) do
    Logger.error(
      "#{label} aborted with #{kind} #{inspect(reason)}\n" <>
        Exception.format_stacktrace(stacktrace)
    )

    {:uncaught, kind, reason}
  end
end
