defmodule ALLM.Pipeline.Dsl.Runtime do
  @moduledoc """
  The interpreter the generated `run/1` calls.

  Everything `use ALLM.Pipeline` generates is three functions —  `run/1`,
  `__pipeline__/1` and nothing else. All of the behaviour lives here, as
  ordinary code against `__pipeline__(:stages)`, so the macro stays a
  declaration reader and this module stays steppable in `iex`.

  ## It calls what a hand-written orchestrator calls

  `Executor.create_pipeline_run/3`, `Executor.run_step/5`,
  `Executor.log_section/3`, `Executor.log_summary/4`,
  `Executor.borrowed_run/1`, `Metrics.record/3` and `PipelineRun.borrow/1`,
  plus — through `ALLM.Pipeline.Lifecycle`, which owns the terminal write —
  `PipelineRun.complete/2` and `Executor.fail_pipeline_run/2`. Re-derive the set
  rather than trusting this list:

      grep -oEn '\b(Executor|PipelineRun|Metrics|FanOut|Lifecycle)\.[a-z_]+[!?]?\(' \
        lib/allm/pipeline/dsl/runtime.ex lib/allm/pipeline/lifecycle.ex \
        | sed 's/^[0-9]*://' | sort -u

  The load-bearing claim is the stronger negative one: this module reaches a
  `step_logs` / `pipeline_runs` / `pipeline_metrics` row **only** through those
  functions — no `Repo.`, no `repo()`, no changeset of its own. That is the whole
  reason a ported pipeline's step-log tree can be *structurally identical* to the
  hand-written one rather than merely equivalent.

  ## Ownership

  The owning handle is confined to the four private functions that create or
  settle a run — `run_owned/3`, `execute/4`, `execute_dry/4` and `settle/5` —
  and is passed to no hook and to no return value. (`run_borrowed/4` never sees
  one: on that path the umbrella owns the run and this pipeline terminates
  nothing.) Re-derive rather than trusting the list:
  `grep -n 'owning' lib/allm/pipeline/dsl/runtime.ex`. Every `Context` a stage body, `over:`,
  `input:`, `skip_when:` or `summarize` hook receives is built from
  `PipelineRun.borrow/1`'s projection, so a body reading `ctx.pipeline_run`
  cannot complete its own parent run. `returns: :run` hands back the completed
  run **borrowed** for the same reason: `Repo.update` carries virtual fields
  through, so the struct `PipelineRun.complete/2` returns still holds the token.

  ## State threaded through the stages

  | Key | Meaning |
  |---|---|
  | `acc` | the accumulator; written **only** by a body returning `{item_result, acc}` |
  | `prev` | the previous stage's output — a `fan_out`'s is `[Dsl.Item.t()]` |
  | `parent` | the lineage parent: the last **successfully executed** step's log id |
  | `carry` | values captured by a `carry: [...]` declaration |
  | `resources` | framework-managed handles, acquired once per run by a `resource` declaration |
  """

  alias ALLM.Pipeline.{
    Context,
    Executor,
    FanOut,
    Lifecycle,
    Metrics,
    PipelineRun,
    StepLog
  }

  alias ALLM.Pipeline.Dsl.{Item, Resource, Stage}

  require Logger

  @typedoc "The value a `FanOut.reduce/5` fold function or escape-hatch `stage` body returns, once normalized."
  @type item_result :: FanOut.item_result()

  @typedoc "Whether a body wrote the accumulator."
  @type acc_update :: :keep | {:update, term()}

  @typedoc false
  @type state :: %{
          acc: term(),
          prev: term(),
          parent: Ecto.UUID.t() | nil,
          carry: Context.carry(),
          resources: Context.resources()
        }

  @doc """
  Execute `module`'s declaration under a fresh `PipelineRun`.

  The generated `run/1` is a one-line delegation to this. Returns
  `{:ok, summary}` — or `{:ok, completed_run}` under `returns: :run` — and
  `{:error, reason}` when the run could not be created or a stage failed with
  `on_error: :fail_run`.

  The run is written terminal on **every** exit path: success, a named stage
  failure, a raise, an exit and a throw. A raise/exit/throw is re-raised
  unchanged after the run is failed, so a caller's own error handling is
  unaffected — the DSL adds the terminal write those paths were missing, and
  nothing else. That guard is `ALLM.Pipeline.Lifecycle`, shared with the
  affordance a hand-written entry point calls.

  Two declarations divert before any of that:

  * `borrowed_run: true` **and** a lent `:pipeline_run` in `opts` — the stages
    run under the umbrella's handle and this function creates and terminates
    nothing.
  * `dry_run:` **and** a truthy `:dry_run` in `opts` — see `ALLM.Pipeline`'s
    moduledoc, `## --dry-run`, which is where that contract is stated.

  They cannot both fire: declaring `borrowed_run: true` **and** `dry_run:` is a
  compile error (`Dsl.__validate__!/2`) — see the same section's "mutually
  exclusive" paragraph for why.
  """
  @spec run(module(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(module, opts) do
    hooks = module.__pipeline__(:hooks)

    case lent_run(hooks, opts) do
      {:ok, borrowed} -> run_borrowed(module, hooks, borrowed, opts)
      :error -> run_owned(module, hooks, opts)
    end
  end

  # `Executor.borrowed_run/1` is consulted ONLY when the pipeline declares
  # `borrowed_run: true`. Consulting it unconditionally would make a stray
  # `:pipeline_run` opt silently change the lifecycle of every pipeline in the
  # tree, which is the opposite of the declared-not-hidden rule (D12).
  @spec lent_run(map(), keyword()) :: {:ok, PipelineRun.t()} | :error
  defp lent_run(%{borrowed_run: true}, opts), do: Executor.borrowed_run(opts)
  defp lent_run(_hooks, _opts), do: :error

  @spec run_owned(module(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  defp run_owned(module, hooks, opts) do
    name = Keyword.get(opts, :run_name) || module.__pipeline__(:name)

    # `:parent_run_id` is lifted out of `opts` into `create_pipeline_run/3`'s
    # ATTRS, where it is a first-class column rather than a metadata key — which
    # is what makes a child run SQL/GraphQL-filterable under its parent. This has
    # ALWAYS been on the self-owned path: a ported pipeline invoked as a child
    # (`ProjectEnrichmentPipeline.run(project_id:, parent_run_id:)`) sets the
    # column through here, mirroring what the hand-written consumers do
    # (`parent_run_id: Keyword.get(opts, :parent_run_id)`).
    # `runtime_test.exs`'s "self-owned parent_run_id lift" is its regression
    # coverage.
    case Executor.create_pipeline_run(
           name,
           call(hooks.metadata, [opts], %{options: opts}),
           Keyword.take(opts, [:parent_run_id])
         ) do
      {:ok, owning} ->
        if dry_run?(hooks, opts),
          do: execute_dry(module, hooks, owning, opts),
          else: execute(module, hooks, owning, opts)

      {:error, reason} ->
        Logger.error("#{inspect(module)}: could not create pipeline run: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec dry_run?(map(), keyword()) :: boolean()
  defp dry_run?(%{dry_run: nil}, _opts), do: false
  defp dry_run?(%{dry_run: _hook}, opts), do: !!Keyword.get(opts, :dry_run, false)

  # The implementation of the `--dry-run` contract. The contract itself is stated
  # in ONE place — `ALLM.Pipeline`'s moduledoc, `## --dry-run` — including which
  # of the two live host meanings this is; do not restate it here. This body is
  # its four statements: plan hook, one summary row, complete, return.
  @spec execute_dry(module(), map(), PipelineRun.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp execute_dry(module, hooks, owning, opts) do
    label = inspect(module)
    borrowed = PipelineRun.borrow(owning)

    outcome =
      Lifecycle.guard(label, fn ->
        plan = as_map(hooks.dry_run.(Context.new(borrowed, nil, opts)), :plan)
        Executor.log_summary(borrowed, "dry_run", plan)
        {:ok, plan, Map.put(plan, :dry_run, true)}
      end)

    settle(label, hooks, owning, outcome, [])
  end

  @spec execute(module(), map(), PipelineRun.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp execute(module, hooks, owning, opts) do
    label = inspect(module)
    borrowed = PipelineRun.borrow(owning)
    declared = module.__pipeline__(:resources)
    {resources, acquisition} = Resource.acquire(declared, Context.new(borrowed, nil, opts))

    outcome =
      case acquisition do
        :ok ->
          Lifecycle.guard(label, fn ->
            work(module, module, hooks, borrowed, opts, resources)
          end)

        raised ->
          raised
      end

    # D3, and the ordering is the whole point: teardown runs AFTER the outcome
    # is computed and BEFORE the terminal write. After the write it could not
    # record a teardown failure anywhere, because the row is already terminal.
    settle(label, hooks, owning, outcome, Resource.release(declared, resources))
  end

  # The borrowed path creates nothing and terminates nothing — the umbrella
  # owner is the sole completer, and the handle `Executor.borrowed_run/1`
  # returned carries no completion token, so a stray `complete/2` inside a body
  # is a detectable `{:error, :not_run_owner}` rather than a mid-loop clobber.
  #
  # Two consequences, both deliberate. It records NO `pipeline_metrics` row: the
  # funnel would be attributed to the umbrella's run, double-counting against
  # whatever the umbrella records itself. And a teardown failure is LOGGED
  # rather than recorded in metadata, because there is no terminal write of this
  # pipeline's own to hang it on.
  @spec run_borrowed(module(), map(), PipelineRun.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp run_borrowed(module, hooks, borrowed, opts) do
    label = inspect(module)
    declared = module.__pipeline__(:resources)
    {resources, acquisition} = Resource.acquire(declared, Context.new(borrowed, nil, opts))

    outcome =
      case acquisition do
        :ok ->
          Lifecycle.guard(label, fn -> work(module, nil, hooks, borrowed, opts, resources) end)

        raised ->
          raised
      end

    log_teardown(label, Resource.release(declared, resources))

    case outcome do
      {:ok, {:ok, summary, _metadata}} ->
        if hooks.returns == :run, do: {:ok, borrowed}, else: {:ok, summary}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:raised, kind, reason, stacktrace} ->
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  # Steps 2–4 of the generated lifecycle: stages, then `summarize`, then
  # `metrics`, then the `complete_metadata:` hook. ALL of it runs inside
  # `Lifecycle.guard/2` — a `summarize` or `complete_metadata` hook that raises
  # would otherwise strand the run at `:running`, which is the exact defect the
  # phase exists to close.
  #
  # `metrics_module` is `nil` on the borrowed path and the module otherwise; it
  # is the module because `record_metrics/3` reads `__pipeline__(:metrics)`.
  @spec work(module(), module() | nil, map(), PipelineRun.t(), keyword(), Context.resources()) ::
          {:ok, term(), map()} | {:error, term()}
  defp work(module, metrics_module, hooks, run, opts, resources) do
    case run_stages(module, run, opts, call(hooks.init, [], %{}), resources) do
      {:ok, state} ->
        ctx = context(run, opts, state, state.parent)
        summary = call(hooks.summarize, [state.acc, ctx], state.acc)
        # `from:` reads the ACCUMULATOR, one contract — NOT `summary`, which
        # would silently change its input shape depending on whether the
        # unrelated `summarize` construct is declared (§9.2). A pipeline wanting
        # the summary calls its own `summarize` hook from within `from:`.
        record_metrics(metrics_module, run, state.acc)
        {:ok, summary, as_map(call(hooks.complete_metadata, [state.acc], state.acc), :result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settle(
          String.t(),
          map(),
          PipelineRun.t(),
          Lifecycle.guarded({:ok, term(), map()} | {:error, term()}),
          [Resource.teardown_error()]
        ) :: {:ok, term()} | {:error, term()}
  defp settle(label, hooks, owning, outcome, teardown_errors) do
    case Lifecycle.settle(label, owning, settlement(outcome), teardown_errors) do
      # BORROWED, not the owning handle `complete/2` returned: `Repo.update`
      # carries virtual fields through, so the completed struct still holds the
      # `completion_token` and a caller could re-terminate an already-terminal
      # run with it. Ownership ends at `run/1`.
      {:ok, _summary, completed} when hooks.returns == :run ->
        {:ok, PipelineRun.borrow(completed)}

      {:ok, summary, _completed} ->
        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settlement(Lifecycle.guarded({:ok, term(), map()} | {:error, term()})) ::
          Lifecycle.settlement()
  defp settlement({:ok, {:ok, value, metadata}}), do: {:ok, value, metadata}
  defp settlement({:ok, {:error, reason}}), do: {:error, reason}
  defp settlement({:raised, _kind, _reason, _stacktrace} = raised), do: raised

  @spec as_map(term(), atom()) :: map()
  defp as_map(value, _key) when is_map(value), do: value
  defp as_map(value, key), do: %{key => value}

  @spec log_teardown(String.t(), [Resource.teardown_error()]) :: :ok
  defp log_teardown(_label, []), do: :ok

  defp log_teardown(label, errors) do
    Logger.error(
      "#{label}: #{length(errors)} resource(s) failed to release under a BORROWED run, so " <>
        "there is no terminal write of this pipeline's own to record them on: " <>
        inspect(errors)
    )
  end

  @spec record_metrics(module() | nil, PipelineRun.t(), term()) :: :ok
  defp record_metrics(nil, _run, _acc), do: :ok

  defp record_metrics(module, run, acc) do
    case module.__pipeline__(:metrics) do
      nil ->
        :ok

      %{entity_type: entity_type, from: from} ->
        Metrics.record(run, entity_type, from.(acc))
        :ok
    end
  end

  # ── Stages ────────────────────────────────────────────────────────────────

  @spec run_stages(module(), PipelineRun.t(), keyword(), term(), Context.resources()) ::
          {:ok, state()} | {:error, term()}
  defp run_stages(module, run, opts, acc, resources) do
    default_concurrency = resolve_concurrency(module.__pipeline__(:concurrency), opts)
    state = %{acc: acc, prev: nil, parent: nil, carry: %{}, resources: resources}

    Enum.reduce_while(module.__pipeline__(:stages), {:ok, state}, fn stage, {:ok, state} ->
      case run_stage(stage, run, opts, state, default_concurrency) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec run_stage(Stage.t(), PipelineRun.t(), keyword(), state(), pos_integer()) ::
          {:ok, state()} | {:error, term()}
  defp run_stage(%Stage{} = stage, run, opts, state, default_concurrency) do
    if skip?(stage.skip_when, context(run, opts, state, state.parent)) do
      # D8: a skip writes NO step log in Phase 4, and is lineage-transparent —
      # `state` (and therefore `parent`) is returned untouched, so the next
      # stage parents to the last successfully EXECUTED step. It is also
      # subject-transparent — `prev` is left as the stage BEFORE this one
      # produced — so the log names what `prev` carries (§9.1), which is the
      # diagnostic that makes a downstream `FunctionClauseError` traceable to
      # the stage that was skipped. A detector, not a gate: the run proceeds.
      Logger.info("[#{stage.name}] skipped (skip_when); prev holds #{prev_label(state.prev)}")
      {:ok, state}
    else
      do_stage(stage, run, opts, state, default_concurrency)
    end
  end

  @spec do_stage(Stage.t(), PipelineRun.t(), keyword(), state(), pos_integer()) ::
          {:ok, state()} | {:error, term()}
  defp do_stage(%Stage{kind: :stage} = stage, run, opts, state, _default_concurrency) do
    ctx = context(run, opts, state, state.parent)
    {result, acc_update} = run_target(stage, run, ctx, state.prev, state.parent)

    apply_result(stage, apply_acc(state, acc_update), result)
  end

  defp do_stage(%Stage{kind: :fan_out} = stage, run, opts, state, default_concurrency) do
    items = resolve_items(stage, state.prev)
    concurrency = resolve_concurrency(stage.concurrency || default_concurrency, opts)
    source_parent = state.parent

    # Captured ONCE, before any item is scheduled: the dispatch reference every
    # item's `queue_time` is measured against (`worker_start - queue_since`).
    # Threaded through `opts` so it reaches `Executor.run_step/5` via
    # `step_opts/1`, where the step telemetry is emitted. Non-zero for every
    # item after the first even at `concurrency: 1`. See
    # `ALLM.Pipeline.Telemetry`'s `queue_time` section.
    opts = Keyword.put(opts, :queue_since, System.monotonic_time())

    Logger.info(
      "[#{stage.name}] fanning out over #{length(items)} item(s) at concurrency #{concurrency}"
    )

    {results, acc} =
      if concurrency > 1 do
        {run_concurrent(stage, run, opts, state, items, source_parent, concurrency), state.acc}
      else
        run_sequential(stage, run, opts, state, items, source_parent)
      end

    # A `fan_out` is lineage-transparent for the stages AFTER it: its items'
    # steps hang off `source_parent`, and the root parent is unchanged.
    {:ok, %{state | acc: acc, prev: results}}
  end

  @spec resolve_items(Stage.t(), term()) :: [term()]
  defp resolve_items(%Stage{over: over, name: name}, prev) do
    case over.(prev) do
      items when is_list(items) ->
        items

      other ->
        raise ArgumentError,
              "fan_out :#{name}'s `over:` hook must return a list of items, got: #{inspect(other)}"
    end
  end

  @spec run_sequential(
          Stage.t(),
          PipelineRun.t(),
          keyword(),
          state(),
          [term()],
          Ecto.UUID.t() | nil
        ) ::
          {[Item.t()], term()}
  defp run_sequential(stage, run, opts, state, items, source_parent) do
    {reversed, acc} =
      Enum.reduce(items, {[], state.acc}, fn item, {done, acc} ->
        # The RUNNING accumulator, not the one this stage started with: a body
        # writing `{item_result, acc + 1}` has to read the value its
        # predecessor wrote, or every item folds from the same snapshot.
        #
        # The sequential path is NOT wrapped in the link-safe `catch` — what
        # survives a Step's own safety is infrastructure raising, and one of
        # those should abort the run rather than be tallied as N failed items
        # under a `:success` run. (Phase 5.10 removed the `catch_item_failures:`
        # option that could opt into catching here; nothing consumed it.)
        {result, acc_update} =
          run_item(stage, run, opts, %{state | acc: acc}, item, source_parent)

        {[result | done], fold_acc(acc, acc_update)}
      end)

    {Enum.reverse(reversed), acc}
  end

  # `Task.async_stream` LINKS its children, so an uncaught raise OR exit in one
  # item kills this process before the stream emits anything for it. The `catch`
  # is therefore not a policy choice here — it is what keeps the fan-out alive,
  # and `rescue` alone is insufficient because an exit is not an exception.
  # See `ALLM.Pipeline.FanOut`'s moduledoc.
  @spec run_concurrent(
          Stage.t(),
          PipelineRun.t(),
          keyword(),
          state(),
          [term()],
          Ecto.UUID.t() | nil,
          pos_integer()
        ) :: [Item.t()]
  defp run_concurrent(stage, run, opts, state, items, source_parent, concurrency) do
    items
    |> Task.async_stream(
      fn item -> guarded_item(stage, run, opts, state, item, source_parent) end,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: true
    )
    # The compose check runs OUT HERE, not inside the task: raised in there it
    # would be caught by the very `catch` that keeps the fan-out alive and
    # degraded into a per-item `{:uncaught, :error, _}`, turning a declaration
    # bug into three silently-failed items.
    |> Enum.map(fn {:ok, {result, acc_update}} ->
      assert_no_concurrent_fold!(stage, acc_update)
      result
    end)
  end

  # `Task.async_stream` LINKS its children, so the concurrent path is ALWAYS
  # wrapped — that is link safety, not policy: an uncaught raise or exit in one
  # item kills the caller before the stream emits anything. The SEQUENTIAL path
  # is NOT wrapped (`run_sequential/6` calls `run_item/6` directly), so an
  # uncaught infrastructure raise aborts the run there. The always-on
  # `catch kind, reason` lives in `FanOut.guard/3` — the single home shared with
  # `FanOut.reduce/5`, so the two paths cannot diverge on one kind. `rescue`
  # alone would miss the exit a Playwright/`GenServer.call` teardown arrives as.
  @spec guarded_item(
          Stage.t(),
          PipelineRun.t(),
          keyword(),
          state(),
          term(),
          Ecto.UUID.t() | nil
        ) :: {Item.t(), acc_update()}
  defp guarded_item(stage, run, opts, state, item, source_parent) do
    FanOut.guard(
      item_label(stage, item),
      fn -> run_item(stage, run, opts, state, item, source_parent) end,
      fn tagged -> {%Item{input: item, result: {:error, tagged}}, :keep} end
    )
  end

  @spec run_item(Stage.t(), PipelineRun.t(), keyword(), state(), term(), Ecto.UUID.t() | nil) ::
          {Item.t(), acc_update()}
  defp run_item(stage, run, opts, state, item, source_parent) do
    # A fan-out item ALWAYS runs (Phase 4.5.3 removed `gate:` and its skip
    # path). It sees the run-level `state.carry` a prior `stage` captured, but
    # captures nothing of its own — `carry:` on a `fan_out` is a compile error.
    parent = item_parent(stage, item, source_parent)
    ctx = context(run, opts, state, parent)
    run_item_body(stage, run, ctx, item, parent)
  end

  @spec run_item_body(Stage.t(), PipelineRun.t(), Context.t(), term(), Ecto.UUID.t() | nil) ::
          {Item.t(), acc_update()}
  defp run_item_body(stage, run, ctx, item, parent) do
    {result, acc_update} = run_target(stage, run, ctx, item, parent)
    {FanOut.to_item(item, result), acc_update}
  end

  # The ONE place a stage's target is invoked, for both kinds. `:stage` and
  # `:fan_out` differ only in what they do with the result afterwards
  # (`apply_result/3` vs `to_item/2`), never in how the target is called. It is
  # the single dispatch seam: a step-module target routes through
  # `Executor.run_step/5`, an escape-hatch body is called directly.
  @spec run_target(Stage.t(), PipelineRun.t(), Context.t(), term(), Ecto.UUID.t() | nil) ::
          {item_result(), acc_update()}
  defp run_target(%Stage{step: nil} = stage, _run, ctx, subject, _parent),
    do: normalize!(stage, stage.body.(ctx, subject))

  defp run_target(%Stage{step: step} = stage, run, ctx, subject, parent) do
    result =
      case Executor.run_step(run, step, stage.input.(ctx, subject), parent, step_opts(ctx)) do
        {:ok, step_log, output} -> {:ok, output, step_log}
        {:error, _step_log, reason} -> {:error, reason}
      end

    {result, :keep}
  end

  # ── Result handling ───────────────────────────────────────────────────────

  @spec apply_result(Stage.t(), state(), item_result()) :: {:ok, state()} | {:error, term()}
  defp apply_result(stage, state, {:ok, value}),
    do: {:ok, %{state | prev: value, carry: capture(stage, state.carry, value)}}

  defp apply_result(stage, state, {:ok, value, %StepLog{id: id}}),
    do: {:ok, %{state | prev: value, parent: id, carry: capture(stage, state.carry, value)}}

  # Both branches leave `prev` untouched, so the next stage receives what the
  # stage BEFORE this one produced. Name it (§9.1) so a downstream mismatch is
  # one line above the crash. Neither changes control flow or the return.
  defp apply_result(stage, state, {:skipped, reason}) do
    Logger.info(
      "[#{stage.name}] skipped: #{inspect(reason)}; prev holds #{prev_label(state.prev)}"
    )

    {:ok, state}
  end

  defp apply_result(%Stage{on_error: :continue, name: name}, state, {:error, reason}) do
    Logger.warning(
      "[#{name}] failed, continuing (on_error: :continue): #{inspect(reason)}; " <>
        "prev holds #{prev_label(state.prev)}"
    )

    {:ok, state}
  end

  defp apply_result(%Stage{name: name}, _state, {:error, reason}) do
    Logger.error("[#{name}] failed: #{inspect(reason)}")
    {:error, reason}
  end

  # The accumulator's ONLY write channel. A body returning a bare `item_result`
  # leaves it untouched — which is why `normalize!/2` has to tell the two shapes
  # apart by the first element rather than by tuple size.
  @spec normalize!(Stage.t(), term()) :: {item_result(), acc_update()}
  defp normalize!(_stage, {tag, _} = result) when tag in [:ok, :skipped, :error],
    do: {result, :keep}

  defp normalize!(_stage, {:ok, _value, %StepLog{}} = result), do: {result, :keep}

  defp normalize!(_stage, {result, acc}) when is_tuple(result), do: {result, {:update, acc}}

  defp normalize!(%Stage{name: name}, other) do
    raise ArgumentError,
          "#{name}'s body returned #{inspect(other)}, which is not an item result. Return " <>
            "`{:ok, value}`, `{:ok, value, %ALLM.Pipeline.StepLog{}}`, `{:skipped, reason}` " <>
            "or `{:error, reason}` — optionally wrapped as `{item_result, accumulator}`."
  end

  # `apply_acc/2` and `fold_acc/2` are the SAME rule over two representations of
  # the accumulator (the whole state, and the bare value the sequential fan-out
  # threads), so the rule has one body.
  @spec apply_acc(state(), acc_update()) :: state()
  defp apply_acc(state, update), do: %{state | acc: fold_acc(state.acc, update)}

  @spec fold_acc(term(), acc_update()) :: term()
  defp fold_acc(acc, :keep), do: acc
  defp fold_acc(_acc, {:update, acc}), do: acc

  # A concurrent fan-out and the accumulator do not compose: the fold order is
  # undefined, so a silently-lost update is the failure mode. Raise instead.
  @spec assert_no_concurrent_fold!(Stage.t(), acc_update()) :: :ok
  defp assert_no_concurrent_fold!(_stage, :keep), do: :ok

  defp assert_no_concurrent_fold!(%Stage{name: name}, {:update, _acc}) do
    raise ArgumentError,
          "fan_out :#{name} runs at concurrency > 1 and its fold returned the " <>
            "`{item_result, accumulator}` form. The two do not compose — the fold order is " <>
            "undefined. Return a bare item result and aggregate in `summarize`, or declare " <>
            "`concurrency: 1`."
  end

  # ── Per-stage helpers ─────────────────────────────────────────────────────

  # Delegates to `FanOut.item_parent/3`, the single home shared with
  # `FanOut.reduce/5` — the re-parent-or-raise rule is written once.
  @spec item_parent(Stage.t(), term(), Ecto.UUID.t() | nil) :: Ecto.UUID.t() | nil
  defp item_parent(%Stage{parent: parent}, item, source_parent),
    do: FanOut.item_parent(parent, item, source_parent)

  @spec skip?(Stage.skip_spec() | nil, Context.t()) :: boolean()
  defp skip?(nil, _ctx), do: false
  defp skip?({:opt, key, default}, ctx), do: !!Context.get_opt(ctx, key, default)
  defp skip?(fun, ctx) when is_function(fun, 1), do: !!fun.(ctx)

  # A declared key the subject does not carry is DROPPED, not fatal — a later
  # `Context.carried/3` for it simply returns its default. `Dsl.validate_carry!/3`
  # can only check the declaration is a literal list of atoms; whether the key is
  # a field of whatever the stage produces is knowable here and nowhere earlier.
  # So the miss is logged rather than silent (user decision, 2026-08-21: warn,
  # not raise — a raise would change framework behaviour that nothing gates).
  @spec capture(Stage.t(), Context.carry(), term()) :: Context.carry()
  defp capture(%Stage{carry: []}, carry, _subject), do: carry

  defp capture(%Stage{carry: keys, name: name}, carry, subject) do
    Enum.reduce(keys, carry, fn key, acc ->
      case fetch_field(subject, key) do
        {:ok, value} ->
          Map.put(acc, key, value)

        :error ->
          Logger.warning(
            "[#{name}] `carry:` declares `:#{key}`, but the captured subject is " <>
              "#{subject_label(subject)}, which has no such field — nothing was carried " <>
              "under `:#{key}` and every later `Context.carried(ctx, :#{key})` returns its " <>
              "default. A `stage` captures from its OWN output and a `fan_out` from each " <>
              "ITEM (never from the subject the stage was handed), so declare a key that " <>
              "subject defines, or read the value in the consuming stage's `input:` hook."
          )

          acc
      end
    end)
  end

  # Names what `state.prev` is carrying at a skip point (§9.1). A `fan_out`'s
  # output is a `[%Item{}]`, so the diagnostic that matters is the payload struct
  # ONE item carries (the type a downstream `input:` hook would be handed), not
  # "a list" — `committee`'s `--skip-transform` leaves `prev` holding the DETAIL
  # items, and `loader_input/2` would then be handed a `CommitteeDetailScraper.
  # Output` where a transformer output is declared. Says "first carrying" because
  # only the head item is inspected — it does not verify the list is homogeneous.
  # Delegates the scalar case to `subject_label/1`.
  @spec prev_label(term()) :: String.t()
  defp prev_label([%Item{result: {:ok, payload}} | _] = items),
    do: "#{length(items)} item(s), first carrying #{subject_label(payload)}"

  defp prev_label([%Item{result: result} | _] = items),
    do: "#{length(items)} item(s), first result #{inspect(result, limit: 2)}"

  defp prev_label([]), do: "an empty list"

  defp prev_label(other), do: subject_label(other)

  @spec subject_label(term()) :: String.t()
  defp subject_label(%module{}), do: "a #{inspect(module)}"

  defp subject_label(subject) when is_map(subject),
    do: "a plain map with keys #{inspect(Map.keys(subject))}"

  defp subject_label(subject), do: "#{inspect(subject, limit: 3)}, which is not a map"

  @spec fetch_field(term(), atom()) :: {:ok, term()} | :error
  defp fetch_field(subject, key) when is_map(subject), do: Map.fetch(subject, key)
  defp fetch_field(_subject, _key), do: :error

  @spec resolve_concurrency(Stage.concurrency_spec(), keyword()) :: pos_integer()
  defp resolve_concurrency(spec, opts) do
    case resolve_opt(spec, opts) do
      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError,
              "`concurrency:` resolved to #{inspect(other)}; it must be a positive integer."
    end
  end

  @spec resolve_opt(term(), keyword()) :: term()
  defp resolve_opt({:opt, key, default}, opts) when is_atom(key),
    do: Keyword.get(opts, key, default)

  defp resolve_opt(value, _opts), do: value

  @spec context(PipelineRun.t(), keyword(), state(), Ecto.UUID.t() | nil) :: Context.t()
  defp context(run, opts, state, parent) do
    Context.new(
      run,
      nil,
      Keyword.merge(opts,
        resources: state.resources,
        carry: state.carry,
        acc: state.acc,
        input_step_id: parent
      )
    )
  end

  # `Executor.run_step/5` hands its `opts` to `Context.new/3`, which pops these
  # two onto struct fields — so a Step reads `Context.resource(ctx, :browser)`,
  # not `Keyword.get(opts, :page)`.
  @spec step_opts(Context.t()) :: keyword()
  defp step_opts(%Context{} = ctx),
    do: Keyword.merge(ctx.opts, resources: ctx.resources, carry: ctx.carry)

  @spec item_label(Stage.t(), term()) :: String.t()
  defp item_label(%Stage{name: name}, item),
    do: "fan_out :#{name} item #{inspect(item, limit: 3, printable_limit: 64)}"

  @spec call((... -> term()) | nil, [term()], term()) :: term()
  defp call(nil, _args, default), do: default
  defp call(fun, args, _default), do: apply(fun, args)
end
