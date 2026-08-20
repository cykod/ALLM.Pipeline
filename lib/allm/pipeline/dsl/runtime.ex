defmodule ALLM.Pipeline.Dsl.Runtime do
  @moduledoc """
  The interpreter the generated `run/1` calls.

  Everything `use ALLM.Pipeline` generates is three functions —  `run/1`,
  `__pipeline__/1` and nothing else. All of the behaviour lives here, as
  ordinary code against `__pipeline__(:stages)`, so the macro stays a
  declaration reader and this module stays steppable in `iex`.

  ## It calls what a hand-written orchestrator calls

  `Executor.create_pipeline_run/3`, `Executor.run_step/5`,
  `Executor.log_section/3`, `Executor.fail_pipeline_run/2`,
  `PipelineRun.complete/2`, `PipelineRun.borrow/1` and `Metrics.record/3` — with
  the same arguments. Re-derive the set rather than trusting this list:

      grep -oEn '\b(Executor|PipelineRun|Metrics|FanOut)\.[a-z_]+[!?]?\(' \
        apps/allm_pipeline/lib/allm/pipeline/dsl/runtime.ex | sed 's/^[0-9]*://' | sort -u

  The load-bearing claim is the stronger negative one: this module reaches a
  `step_logs` / `pipeline_runs` / `pipeline_metrics` row **only** through those
  functions — no `Repo.`, no `repo()`, no changeset of its own. That is the whole
  reason a ported pipeline's step-log tree can be *structurally identical* to the
  hand-written one rather than merely equivalent.

  ## Ownership

  The owning handle is confined to four private functions — `run/2`,
  `execute/4`, `finish/6` and `complete/4` — and is passed to no hook and to no
  return value. Every `Context` a stage body, `gate:`, `section:`, `over:`,
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
  | `resources` | framework-managed handles; populated by `resource` (Phase 4.3) |
  """

  alias ALLM.Pipeline.{Context, Executor, FanOut, Metrics, PipelineRun, StepLog}
  alias ALLM.Pipeline.Dsl.{Item, Stage}

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
  nothing else.
  """
  @spec run(module(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(module, opts) do
    hooks = module.__pipeline__(:hooks)
    name = Keyword.get(opts, :run_name) || module.__pipeline__(:name)

    case Executor.create_pipeline_run(name, call(hooks.metadata, [opts], %{options: opts})) do
      {:ok, owning} ->
        execute(module, hooks, owning, opts)

      {:error, reason} ->
        Logger.error("#{inspect(module)}: could not create pipeline run: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec execute(module(), map(), PipelineRun.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp execute(module, hooks, owning, opts) do
    borrowed = PipelineRun.borrow(owning)

    try do
      case run_stages(module, borrowed, opts, call(hooks.init, [], %{})) do
        {:ok, state} ->
          finish(module, hooks, owning, borrowed, opts, state)

        {:error, reason} ->
          Executor.fail_pipeline_run(owning, reason)
          {:error, reason}
      end
    rescue
      e ->
        Logger.error(
          "#{inspect(module)} failed with exception: #{Exception.message(e)}\n" <>
            Exception.format_stacktrace(__STACKTRACE__)
        )

        Executor.fail_pipeline_run(owning, e)
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        # An exit or a throw is not an exception, so `rescue` never sees it —
        # and two orchestrators in this tree have no `rescue` at all, which is
        # how they strand a run at `status = running`. Both are closed here.
        Logger.error(
          "#{inspect(module)} aborted with #{kind} #{inspect(reason)}\n" <>
            Exception.format_stacktrace(__STACKTRACE__)
        )

        Executor.fail_pipeline_run(owning, {kind, reason})
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # Step 3 (summarize) → 4 (metrics) → 5 (terminal write). `summarize` runs
  # BEFORE the write, which is exactly why it cannot produce the completed run
  # and `returns: :run` exists.
  @spec finish(module(), map(), PipelineRun.t(), PipelineRun.t(), keyword(), state()) ::
          {:ok, term()}
  defp finish(module, hooks, owning, borrowed, opts, state) do
    ctx = context(borrowed, opts, state, state.parent)
    summary = call(hooks.summarize, [state.acc, ctx], state.acc)

    record_metrics(module, borrowed, summary)
    completed = complete(module, owning, hooks, state.acc)

    case hooks.returns do
      # BORROWED, not the owning handle `complete/2` returned: `Repo.update`
      # carries virtual fields through, so the completed struct still holds the
      # `completion_token` and a caller could re-terminate an already-terminal
      # run with it. Ownership ends at `run/1`, and this is the only value that
      # crosses that boundary.
      :run -> {:ok, PipelineRun.borrow(completed)}
      :summary -> {:ok, summary}
    end
  end

  @spec complete(module(), PipelineRun.t(), map(), term()) :: PipelineRun.t()
  defp complete(module, owning, hooks, acc) do
    metadata = call(hooks.complete_metadata, [acc], acc)
    metadata = if is_map(metadata), do: metadata, else: %{result: metadata}

    case PipelineRun.complete(owning, metadata) do
      {:ok, run} ->
        run

      {:error, reason} ->
        Logger.error("#{inspect(module)}: could not complete run: #{inspect(reason)}")
        owning
    end
  end

  @spec record_metrics(module(), PipelineRun.t(), term()) :: :ok
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

  @spec run_stages(module(), PipelineRun.t(), keyword(), term()) ::
          {:ok, state()} | {:error, term()}
  defp run_stages(module, run, opts, acc) do
    default_concurrency = resolve_concurrency(module.__pipeline__(:concurrency), opts)
    state = %{acc: acc, prev: nil, parent: nil, carry: %{}, resources: %{}}

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
  defp do_stage(%Stage{kind: :stage} = stage, run, opts, state, _default_concurrency) do
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
