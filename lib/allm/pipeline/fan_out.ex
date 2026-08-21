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

  alias ALLM.Pipeline.{Context, StepLog}
  alias ALLM.Pipeline.Dsl.Item

  @typedoc """
  A per-item failure that escaped every named error path. Persisted through the
  caller's own error shape; `inspect`ed to a string before it reaches jsonb.
  """
  @type uncaught :: {:uncaught, kind :: atom(), reason :: term()}

  @typedoc """
  The value a per-item body returns, before it is wrapped into an `Item`. A
  3-tuple `{:ok, value, %StepLog{}}` nominates a producing step log; every other
  shape leaves `Item.step_log` `nil`.
  """
  @type item_result :: Item.result() | {:ok, term(), StepLog.t()}

  @typedoc "The fold accumulator threaded through `reduce/5`."
  @type acc :: term()

  @typedoc "How each item's steps are parented — see `reduce/5`."
  @type parent_mode :: :source_stage | :per_item

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

  @doc """
  Fold a body over a list of items, sequentially, with per-item link safety.

  This is the FUNCTION form of a `body:`-mode `fan_out`: an ordinary `stage`
  body calls it instead of declaring the mode. It owns exactly the properties
  §8.3 of the DSL review found genuinely need centralising — the always-on
  link-safe catch, the `%Item{}` wrapping with its producing-step-log capture,
  and per-item lineage — and pushes `section:`/`delay:`/`over:` back to the
  caller as ordinary code.

  Runs `fun.(ctx, item, acc)` for each item, threading `acc` **sequentially**
  (a fold), and returns the list of `%Item{}` in input order plus the final
  accumulator.

    * Each `fun` call runs under an always-on `catch kind, reason` wrapper (link
      safety — see this module's moduledoc). An uncaught `raise`/`exit`/`throw`
      becomes `%Item{result: {:error, {:uncaught, kind, reason}}}` and **leaves
      `acc` unchanged for that item**. It is `catch`, never `rescue`: an exit is
      not an exception, and Playwright/`GenServer` teardowns arrive as exits.
    * `fun`'s `item_result` is wrapped into `%Item{}`: a 3-tuple
      `{:ok, value, %StepLog{}}` carries the producing step log onto
      `%Item{step_log: …}`; every other shape leaves it `nil`.
    * `reduce/5` is **sequential only** — it folds a changing accumulator, and a
      concurrent fold has undefined order (`Dsl.Runtime`'s
      `assert_no_concurrent_fold!/2` exists to reject that very shape). A
      concurrency-capable non-folding sibling is deliberately not provided
      (Phase 4.5 Alternatives).

  ## Options

    * `parent:` — `:source_stage` (default) hangs every item's steps off
      `Context.input_step_id(ctx)`; `:per_item` re-parents each item's context
      to its OWN producing step log, which requires the items to be `%Item{}`
      wrappers (filter a previous fan-out with
      `ALLM.Pipeline.Dsl.Item.ok_items/1`), and raises otherwise.

  `section:` and `delay:` are **not** options here — the caller inlines them
  (`Executor.log_section/3` and `Process.sleep/1`). That split is the whole
  point: it keeps this function from re-accepting the costume Phase 4.5 removed.
  """
  @spec reduce(
          Context.t(),
          Enumerable.t(),
          acc(),
          (Context.t(), term(), acc() -> {item_result(), acc()}),
          keyword()
        ) :: {[Item.t()], acc()}
  def reduce(ctx, items, acc, fun, opts \\ []) do
    parent_mode = Keyword.get(opts, :parent, :source_stage)
    source_parent = Context.input_step_id(ctx)

    {reversed, final_acc} =
      Enum.reduce(items, {[], acc}, fn item, {done, acc} ->
        # The per-item parent is resolved OUTSIDE the guard: a `:per_item` input
        # that is not an `%Item{}` is a usage error and must raise loudly, not be
        # degraded into an uncaught per-item failure.
        item_ctx = %{ctx | input_step_id: item_parent(parent_mode, item, source_parent)}

        {item_result, next_acc} =
          guard(item_label(item), fn -> fun.(item_ctx, item, acc) end, fn tagged ->
            # Link-safe degrade: the raising item leaves the RUNNING acc — the one
            # bound in this closure — unchanged (`:keep`).
            {{:error, tagged}, acc}
          end)

        {[to_item(item, item_result) | done], next_acc}
      end)

    {Enum.reverse(reversed), final_acc}
  end

  @doc """
  Run a per-item body closure under the always-on link-safe catch.

  `catch kind, reason`, never `rescue`: an exit is not an exception, and
  `Task.async_stream` links its children, so an uncaught exit kills the caller.
  `on_uncaught` builds the caller's own fallback pair from the tagged failure,
  because the two consumers — `reduce/5` here and
  `Dsl.Runtime.guarded_item/7` — degrade to different shapes. This is the single
  home of the catch: writing it a second time is how the two paths silently
  diverge on one kind (package `CLAUDE.md` §7).
  """
  @spec guard(String.t(), (-> result), (uncaught() -> result)) :: result when result: var
  def guard(label, fun, on_uncaught) do
    fun.()
  catch
    kind, reason ->
      on_uncaught.(tag_uncaught(label, kind, reason, __STACKTRACE__))
  end

  @doc """
  The lineage parent for one item of a fan-out.

  Under `:source_stage`, `source_parent` — every item's steps hang off the
  source stage's step log. Under `:per_item`, the item's OWN producing step log,
  which requires the item to be an `%Item{}` wrapper (`ok_items/1` keeps it),
  and raises otherwise.
  """
  @spec item_parent(parent_mode(), term(), Ecto.UUID.t() | nil) :: Ecto.UUID.t() | nil
  def item_parent(:per_item, %Item{step_log: %StepLog{id: id}}, _source), do: id

  def item_parent(:per_item, item, _source) do
    raise ArgumentError,
          "a fan-out under `parent: :per_item` — each item must carry its own producing " <>
            "step log, but got #{inspect(item)}. Filter the previous fan-out's output with " <>
            "`ALLM.Pipeline.Dsl.Item.ok_items/1` (which keeps the wrapper) rather than " <>
            "unwrapping it with `ok_values/1`."
  end

  def item_parent(_mode, _item, source_parent), do: source_parent

  @doc """
  Wrap a per-item body's `item_result` into an `%Item{}`.

  A 3-tuple `{:ok, value, %StepLog{}}` moves its log onto `step_log` and keeps
  `{:ok, value}` as the result; every other shape leaves `step_log` `nil` (the
  two-element `{:ok, value}` form nominates no new parent — Phase 4 D2).
  """
  @spec to_item(term(), item_result()) :: Item.t()
  def to_item(item, {:ok, value, %StepLog{} = log}),
    do: %Item{input: item, result: {:ok, value}, step_log: log}

  def to_item(item, result), do: %Item{input: item, result: result}

  @spec item_label(term()) :: String.t()
  defp item_label(item), do: "fan_out item #{inspect(item, limit: 3, printable_limit: 64)}"
end
