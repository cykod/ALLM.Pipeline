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
        apps/allm_pipeline/lib/allm/pipeline/dsl/runtime.ex apps/allm_pipeline/lib/allm/pipeline/lifecycle.ex \
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
  `grep -n 'owning' apps/allm_pipeline/lib/allm/pipeline/dsl/runtime.ex`. Every `Context` a stage body, `gate:`, `section:`, `over:`,
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
    Encodable,
    Executor,
    FanOut,
    Lifecycle,
    Metrics,
    PipelineRun,
    StepLog
  }

  alias ALLM.Pipeline.Dsl.{Item, Resource, Stage}

  require Logger

  @typedoc "The value a `fan_out` body or escape-hatch `stage` returns, once normalized."
  @type item_result :: Item.result() | {:ok, term(), StepLog.t()}

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
    # is what makes a child run SQL/GraphQL-filterable under its parent. Without
    # this lift `child_pipeline` cannot link a DSL-declared child at all: the
    # opt would reach the child's `run/1` and stop there. It mirrors what the
    # three hand-written consumers already do
    # (`parent_run_id: Keyword.get(opts, :parent_run_id)`).
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
        record_metrics(metrics_module, run, summary)
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
  defp record_metrics(nil, _run, _summary), do: :ok

  defp record_metrics(module, run, summary) do
    case module.__pipeline__(:metrics) do
      nil ->
        :ok

      %{entity_type: entity_type, from: from} ->
        Metrics.record(run, entity_type, from.(summary))
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
      # stage parents to the last successfully EXECUTED step.
      Logger.info("[#{stage.name}] skipped (skip_when)")
      {:ok, state}
    else
      do_stage(stage, run, opts, state, default_concurrency)
    end
  end

  @spec do_stage(Stage.t(), PipelineRun.t(), keyword(), state(), pos_integer()) ::
          {:ok, state()} | {:error, term()}
  # `:child_pipeline` shares the `:stage` branch verbatim: it runs once, its
  # result is an `item_result()`, and `apply_result/3` handles it identically.
  # Only `run_target/5`'s dispatch differs.
  defp do_stage(%Stage{kind: kind} = stage, run, opts, state, _default_concurrency)
       when kind in [:stage, :child_pipeline] do
    ctx = context(run, opts, state, state.parent)
    {result, acc_update} = run_target(stage, run, ctx, state.prev, state.parent)

    apply_result(stage, apply_acc(state, acc_update), result)
  end

  defp do_stage(%Stage{kind: :fan_out} = stage, run, opts, state, default_concurrency) do
    items = resolve_items(stage, state.prev)
    concurrency = resolve_concurrency(stage.concurrency || default_concurrency, opts)
    source_parent = state.parent

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
        {result, acc_update} =
          guarded_item(
            stage,
            run,
            opts,
            %{state | acc: acc},
            item,
            source_parent,
            stage.catch_item_failures
          )

        maybe_delay(stage, opts, result.result)
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
      fn item ->
        {result, acc_update} = guarded_item(stage, run, opts, state, item, source_parent, true)
        maybe_delay(stage, opts, result.result)
        {result, acc_update}
      end,
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

  # `Task.async_stream` LINKS its children, so the concurrent path passes
  # `guard? = true` unconditionally — that is link safety, not policy. The
  # SEQUENTIAL path passes the `catch_item_failures:` declaration, which
  # defaults to `false`: what survives a Step's own safety is infrastructure
  # raising, and one of those should abort the run rather than be tallied as N
  # individually-failed items under a `:success` run.
  @spec guarded_item(
          Stage.t(),
          PipelineRun.t(),
          keyword(),
          state(),
          term(),
          Ecto.UUID.t() | nil,
          boolean()
        ) :: {Item.t(), acc_update()}
  defp guarded_item(stage, run, opts, state, item, source_parent, false),
    do: run_item(stage, run, opts, state, item, source_parent)

  defp guarded_item(stage, run, opts, state, item, source_parent, true) do
    run_item(stage, run, opts, state, item, source_parent)
  catch
    # `catch kind, reason`, never `rescue`: an exit is not an exception, and
    # Playwright teardowns and `GenServer.call` timeouts arrive as exits.
    kind, reason ->
      tagged = FanOut.tag_uncaught(item_label(stage, item), kind, reason, __STACKTRACE__)
      {%Item{input: item, result: {:error, tagged}}, :keep}
  end

  @spec run_item(Stage.t(), PipelineRun.t(), keyword(), state(), term(), Ecto.UUID.t() | nil) ::
          {Item.t(), acc_update()}
  defp run_item(stage, run, opts, state, item, source_parent) do
    maybe_section(stage, run, item, source_parent)

    case gate(stage, item, opts) do
      {:skip, reason} ->
        # D8 again: silent. The decision is visible in this log line and in
        # whatever the body's accumulator records, not in a `:skipped` row.
        Logger.info("[#{stage.name}] item skipped by gate: #{inspect(reason)}")
        {%Item{input: item, result: {:skipped, reason}}, :keep}

      {:run, decision} ->
        parent = item_parent(stage, item, source_parent)
        carry = stage |> capture(state.carry, item) |> put_decision(decision)
        ctx = context(run, opts, %{state | carry: carry}, parent)

        run_item_body(stage, run, ctx, item, parent)
    end
  end

  @spec run_item_body(Stage.t(), PipelineRun.t(), Context.t(), term(), Ecto.UUID.t() | nil) ::
          {Item.t(), acc_update()}
  defp run_item_body(stage, run, ctx, item, parent) do
    {result, acc_update} = run_target(stage, run, ctx, item, parent)
    {to_item(item, result), acc_update}
  end

  # The ONE place a stage's target is invoked, for both kinds. `:stage` and
  # `:fan_out` differ only in what they do with the result afterwards
  # (`apply_result/3` vs `to_item/2`), never in how the target is called — so
  # anything that changes the invocation (4.3's `retry:`, which re-invokes
  # `execute/2` from the top) wraps this and nothing else.
  @spec run_target(Stage.t(), PipelineRun.t(), Context.t(), term(), Ecto.UUID.t() | nil) ::
          {item_result(), acc_update()}
  defp run_target(stage, run, ctx, subject, parent),
    do: attempt_target(stage, run, ctx, subject, parent, 1)

  # Phase 4 D11: `retry:` RE-INVOKES the target, so each attempt gets its own
  # step log — the framework never re-applies a step's hooks to an existing one,
  # which matters because `post_process/2` is not idempotent on two ported steps
  # (`.work/HANDOFF.md`). The LAST attempt's `{result, acc_update}` is the one
  # that survives: an earlier attempt's accumulator write is discarded, and each
  # attempt sees the same context.
  @spec attempt_target(
          Stage.t(),
          PipelineRun.t(),
          Context.t(),
          term(),
          Ecto.UUID.t() | nil,
          pos_integer()
        ) :: {item_result(), acc_update()}
  defp attempt_target(stage, run, ctx, subject, parent, attempt) do
    {result, acc_update} = invoke_target(stage, run, ctx, subject, parent, attempt)

    if retry?(stage.retry, result, attempt) do
      backoff(stage, attempt)
      attempt_target(stage, run, ctx, subject, parent, attempt + 1)
    else
      {result, acc_update}
    end
  end

  @spec retry?(Stage.retry_spec() | nil, item_result(), pos_integer()) :: boolean()
  defp retry?(nil, _result, _attempt), do: false
  defp retry?(%{max: max}, _result, attempt) when attempt >= max, do: false
  defp retry?(%{on: on}, {:error, reason}, _attempt), do: retryable?(on, reason)
  defp retry?(_retry, _result, _attempt), do: false

  # A bare reason atom, or the first element of a tagged tuple — the two shapes
  # `Executor.run_step/5` actually returns (`:rate_limited`,
  # `{:output_validation_failed, _}`). Anything else is not retried, because a
  # reason nobody can name is not one anybody declared `on:` for.
  @spec retryable?(:any | [atom()], term()) :: boolean()
  defp retryable?(:any, _reason), do: true
  defp retryable?(on, reason) when is_atom(reason), do: reason in on

  defp retryable?(on, reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: elem(reason, 0) in on

  defp retryable?(_on, _reason), do: false

  @spec backoff(Stage.t(), pos_integer()) :: :ok
  defp backoff(%Stage{name: name, retry: %{backoff: kind, base_ms: base}}, attempt) do
    ms =
      case kind do
        :none -> 0
        :linear -> base * attempt
        :exponential -> base * Integer.pow(2, attempt - 1)
      end

    Logger.warning("[#{name}] attempt #{attempt} failed; retrying in #{ms}ms")
    if ms > 0, do: Process.sleep(ms)
    :ok
  end

  # The child clause is FIRST because a `:child_pipeline` stage also has
  # `step: nil` — matching the escape hatch before it would call `nil.(ctx, _)`.
  @spec invoke_target(
          Stage.t(),
          PipelineRun.t(),
          Context.t(),
          term(),
          Ecto.UUID.t() | nil,
          pos_integer()
        ) :: {item_result(), acc_update()}
  defp invoke_target(
         %Stage{kind: :child_pipeline, child: child} = stage,
         run,
         ctx,
         subject,
         _p,
         _a
       ) do
    args = child.args.(ctx, subject)
    {normalize_child!(stage, apply(child.module, child.fun, link_child(stage, args, run))), :keep}
  end

  defp invoke_target(%Stage{step: nil} = stage, _run, ctx, subject, _parent, _attempt),
    do: normalize!(stage, stage.body.(ctx, subject))

  defp invoke_target(%Stage{step: step} = stage, run, ctx, subject, parent, attempt) do
    result =
      case Executor.run_step(
             run,
             step,
             stage.input.(ctx, subject),
             parent,
             step_opts(ctx, attempt)
           ) do
        {:ok, step_log, output} -> {:ok, output, step_log}
        {:error, _step_log, reason} -> {:error, reason}
      end

    {result, :keep}
  end

  # `parent_run_id:` is merged into the argument list's LAST element, which must
  # be a keyword list. All three live consumer call sites are `run(opts)`
  # (`project_refresh_pipeline.ex:204`, `:266`, `:275`), so an append would
  # serve them — merging is what keeps the child's arity intact for an
  # `f(id, opts)` entry point such as `ProjectEnrichmentPipeline.run_single/2`.
  @spec link_child(Stage.t(), term(), PipelineRun.t()) :: [term()]
  defp link_child(stage, args, run) when is_list(args) and args != [] do
    last = List.last(args)

    if Keyword.keyword?(last) do
      List.replace_at(args, -1, Keyword.put(last, :parent_run_id, run.id))
    else
      raise_child_args!(stage, args)
    end
  end

  defp link_child(stage, args, _run), do: raise_child_args!(stage, args)

  # `Encodable.render/1`, not `inspect/1`: `Lifecycle.guard/2` logs this message
  # and `PipelineRun.fail/2` persists it to `pipeline_runs.metadata.error`, and
  # an `args:` hook's last element is a keyword list — exactly where an API token
  # or session handle would be threaded to a child pipeline.
  @spec raise_child_args!(Stage.t(), term()) :: no_return()
  defp raise_child_args!(%Stage{name: name}, args) do
    raise ArgumentError,
          "child_pipeline :#{name}'s `args:` hook returned #{Encodable.render(args)}. " <>
            "It must return a " <>
            "non-empty argument LIST whose last element is a keyword list — that is where " <>
            "`parent_run_id:` is merged, and it is what links the child run to this one."
  end

  @spec normalize_child!(Stage.t(), term()) :: item_result()
  defp normalize_child!(_stage, {tag, _payload} = result) when tag in [:ok, :skipped, :error],
    do: result

  defp normalize_child!(%Stage{name: name, child: child}, other) do
    raise ArgumentError,
          "child_pipeline :#{name} invoked #{inspect(child.module)}.#{child.fun}, which " <>
            "returned #{Encodable.render(other)}. A child pipeline's entry point must " <>
            "return " <>
            "`{:ok, value}`, `{:skipped, reason}` or `{:error, reason}`."
  end

  @spec to_item(term(), item_result()) :: Item.t()
  defp to_item(item, {:ok, value, %StepLog{} = log}),
    do: %Item{input: item, result: {:ok, value}, step_log: log}

  defp to_item(item, result), do: %Item{input: item, result: result}

  # ── Result handling ───────────────────────────────────────────────────────

  @spec apply_result(Stage.t(), state(), item_result()) :: {:ok, state()} | {:error, term()}
  defp apply_result(stage, state, {:ok, value}),
    do: {:ok, %{state | prev: value, carry: capture(stage, state.carry, value)}}

  defp apply_result(stage, state, {:ok, value, %StepLog{id: id}}),
    do: {:ok, %{state | prev: value, parent: id, carry: capture(stage, state.carry, value)}}

  defp apply_result(stage, state, {:skipped, reason}) do
    Logger.info("[#{stage.name}] skipped: #{inspect(reason)}")
    {:ok, state}
  end

  defp apply_result(%Stage{on_error: :continue, name: name}, state, {:error, reason}) do
    Logger.warning("[#{name}] failed, continuing (on_error: :continue): #{inspect(reason)}")
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
          "fan_out :#{name} runs at concurrency > 1 and its body returned the " <>
            "`{item_result, accumulator}` form. The two do not compose — the fold order is " <>
            "undefined. Return a bare item result and aggregate in `summarize`, or declare " <>
            "`concurrency: 1`."
  end

  # ── Per-stage helpers ─────────────────────────────────────────────────────

  @spec maybe_section(Stage.t(), PipelineRun.t(), term(), Ecto.UUID.t() | nil) :: :ok
  defp maybe_section(%Stage{section: nil}, _run, _item, _parent), do: :ok

  defp maybe_section(%Stage{section: section}, run, item, parent) do
    # A SIBLING leaf, never the lineage parent: the section's own log id is
    # discarded, and the item's steps keep parenting to `parent`.
    Executor.log_section(run, section.(item), parent)
    :ok
  end

  @spec gate(Stage.t(), term(), keyword()) :: {:run, term()} | {:skip, term()}
  defp gate(%Stage{gate: nil}, _item, _opts), do: {:run, nil}

  defp gate(%Stage{gate: gate}, item, opts) do
    decision = gate.(item, opts)
    if gate_pass?(decision), do: {:run, decision}, else: {:skip, gate_reason(decision)}
  end

  # A decision map/struct answers through `:should_process`; a bare boolean
  # answers as itself. `meeting_agenda`'s `MeetingProcessingDecision` returns
  # `%{should_process:, reason:, actions:}` and its body branches on `actions`,
  # which is why the whole decision is bound into the context rather than only
  # its verdict.
  @spec gate_pass?(term()) :: boolean()
  defp gate_pass?(%{should_process: value}), do: !!value
  defp gate_pass?(value), do: !!value

  @spec gate_reason(term()) :: term()
  defp gate_reason(%{reason: reason}), do: reason
  defp gate_reason(_decision), do: :gate

  @spec put_decision(Context.carry(), term()) :: Context.carry()
  defp put_decision(carry, nil), do: carry
  defp put_decision(carry, decision), do: Map.put(carry, :gate, decision)

  @spec item_parent(Stage.t(), term(), Ecto.UUID.t() | nil) :: Ecto.UUID.t() | nil
  defp item_parent(%Stage{parent: :per_item}, %Item{step_log: %StepLog{id: id}}, _source), do: id

  defp item_parent(%Stage{parent: :per_item, name: name}, item, _source) do
    raise ArgumentError,
          "fan_out :#{name} declares `parent: :per_item`, so each item must carry its own " <>
            "producing step log — but `over:` returned #{inspect(item)}. Filter the previous " <>
            "fan-out's output with `ALLM.Pipeline.Dsl.Item.ok_items/1` (which keeps the " <>
            "wrapper) rather than unwrapping it with `ok_values/1`."
  end

  defp item_parent(_stage, _item, source_parent), do: source_parent

  @spec maybe_delay(Stage.t(), keyword(), Item.result()) :: :ok
  defp maybe_delay(%Stage{delay: nil}, _opts, _result), do: :ok

  defp maybe_delay(%Stage{name: name, delay: %{ms: ms_spec, when: when_spec}}, opts, result) do
    ms = resolve_ms(name, resolve_opt(ms_spec, opts))
    if ms > 0 and delay?(when_spec, result), do: Process.sleep(ms)
    :ok
  end

  # `validate_ms!/3` rejects a malformed LITERAL at compile time; this catches
  # the `{:opt, key}` form resolving to a non-integer at run time — a CLI parse
  # yielding `nil` for an absent `--delay` is an ordinary shape. Guarded rather
  # than left to `Process.sleep/1` because Erlang term ordering puts every
  # non-number above every number, so `nil > 0` is `true` and the bare guard
  # passes a value the sleep then dies on, with nothing naming the stage.
  @spec resolve_ms(atom(), term()) :: non_neg_integer()
  defp resolve_ms(_name, ms) when is_integer(ms) and ms >= 0, do: ms

  defp resolve_ms(name, other) do
    raise ArgumentError,
          "stage :#{name}'s `delay: [ms: …]` resolved to #{inspect(other)}; it must be a " <>
            "non-negative integer. A `{:opt, key}` form with no default resolves to `nil` " <>
            "when the option is absent — declare `{:opt, key, default}` instead."
  end

  @spec delay?(:processed | :always | (Item.result() -> as_boolean(term())), Item.result()) ::
          boolean()
  defp delay?(:always, _result), do: true
  defp delay?(:processed, {:ok, _value}), do: true
  defp delay?(:processed, _result), do: false
  defp delay?(fun, result) when is_function(fun, 1), do: !!fun.(result)

  @spec skip?(Stage.skip_spec() | nil, Context.t()) :: boolean()
  defp skip?(nil, _ctx), do: false
  defp skip?({:opt, key}, ctx), do: !!Context.get_opt(ctx, key)
  defp skip?({:opt, key, default}, ctx), do: !!Context.get_opt(ctx, key, default)
  defp skip?(fun, ctx) when is_function(fun, 1), do: !!fun.(ctx)

  @spec capture(Stage.t(), Context.carry(), term()) :: Context.carry()
  defp capture(%Stage{carry: []}, carry, _subject), do: carry

  defp capture(%Stage{carry: keys}, carry, subject) do
    Enum.reduce(keys, carry, fn key, acc ->
      case fetch_field(subject, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

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

  defp resolve_opt({:opt, key}, opts) when is_atom(key), do: Keyword.get(opts, key)
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
  # `is_retry: true` from the SECOND attempt (Phase 4 D11). It reaches
  # `StepLog.log_failure/3`'s `retry_count` through `Executor.run_step/5`'s
  # opts, so a retried attempt that fails again is distinguishable from a first
  # one in `step_logs` — which is the only persisted trace a re-invoking retry
  # leaves, since each attempt writes its own row.
  @spec step_opts(Context.t(), pos_integer()) :: keyword()
  defp step_opts(%Context{} = ctx, 1),
    do: Keyword.merge(ctx.opts, resources: ctx.resources, carry: ctx.carry)

  defp step_opts(%Context{} = ctx, _attempt),
    do: ctx |> step_opts(1) |> Keyword.put(:is_retry, true)

  @spec item_label(Stage.t(), term()) :: String.t()
  defp item_label(%Stage{name: name}, item),
    do: "fan_out :#{name} item #{inspect(item, limit: 3, printable_limit: 64)}"

  @spec call((... -> term()) | nil, [term()], term()) :: term()
  defp call(nil, _args, default), do: default
  defp call(fun, args, _default), do: apply(fun, args)
end
