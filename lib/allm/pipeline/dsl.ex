defmodule ALLM.Pipeline.Dsl do
  @moduledoc """
  The construct macros behind `use ALLM.Pipeline`, plus the compile-time
  validators.

  Imported into a pipeline module by `ALLM.Pipeline.__using__/1`; you do not
  `use` this module directly. What the constructs MEAN at runtime is documented
  on `ALLM.Pipeline`; this module is the compiler half.

  ## Why AST, not terms

  A hook cannot be stored as a value. `Module.put_attribute/3` rejects anonymous
  functions, and `&local_fun/2` written in a module body requires the function
  to be defined already — which a declaration block at the top of a module never
  satisfies. So each construct accumulates a **specification containing quoted
  AST** onto `@allm_pipeline_stages`, and `ALLM.Pipeline.__before_compile__/1`
  splices that AST into the body of the generated `__pipeline__(:stages)`, where
  every `def`/`defp` in the module is already defined. That is what lets a hook
  be written as a bare atom naming a **private** function (Phase 4 D6).

  ## Hook forms

  In every hook position, a bare **atom** is the recommended form and expands to
  a local capture at the declared arity; anything else — an `fn`, `& &1.field`,
  `&Mod.fun/1` — is spliced verbatim.

  Every hook's **arity is `__hook_arities__/0`** and is not restated here: that
  one attribute is what the capture is built at AND what
  `__assert_hooks_defined__!/2` checks the module defines, so a table repeating
  it would be a second shape of the same rule with nothing linking them.

  | Hook | Arguments |
  |---|---|
  | `metadata:` | `(opts)` |
  | `complete_metadata:` | `(acc)` |
  | `init:` | `()` |
  | `input:` | `(ctx, subject)` |
  | `over:` | `(previous_stage_output)` |
  | `body:` / escape-hatch stage | `(ctx, subject)` |
  | `skip_when:` | `(ctx)` — or the data form `{:opt, key}` / `{:opt, key, default}` |
  | `metrics …, from:` | `(summary)` |
  | `summarize` | `(acc, ctx)` |
  | `resource …, start:` | `(ctx)` |
  | `resource …, stop:` | `(handle)` |
  | `child_pipeline …, args:` | `(ctx, subject)` |
  | `dry_run:` | `(ctx)` |

  `subject` is the previous stage's output for a `stage`, and the item for a
  `fan_out`. Note `carry:` does **not** capture from the subject — see
  `ALLM.Pipeline.Dsl.Stage`'s `carry` row.

  ## The two `stage/3` forms are told apart by AST SHAPE, not by a keyword

  An alias — `MeetingListScraper` — arrives as `{:__aliases__, _, _}` and means
  the Step form. Anything else means the escape hatch. Matching on `is_atom/1`
  instead would treat every Step module as a hook, because an alias **is** an
  atom once expanded, and the failure would be a `FunctionClauseError` at the
  first run rather than a compile error.
  """

  alias ALLM.Pipeline.Dsl.Stage

  @use_options [
    :name,
    :metadata,
    :complete_metadata,
    :init,
    :returns,
    :concurrency,
    :borrowed_run,
    :dry_run,
    :summary_type
  ]

  @common_options [:input, :skip_when, :carry, :retry]

  # `on_error:` governs a WHOLE-STAGE failure, and a `fan_out` has none — its
  # items' failures land in the `[Dsl.Item.t()]` it returns, and the stage
  # itself always succeeds. Accepting the option there would be a declaration
  # that compiles, validates and does nothing, so it is a `stage`-only option
  # and `assert_on_error_placement!/4` rejects it by name on a `fan_out`.
  @stage_options @common_options ++ [:on_error]

  # `:carry` is deliberately dropped from what `@fan_out_options` inherits from
  # `@common_options`, and `:gate` is gone entirely: both were zero-consumer
  # traps removed in Phase 4.5.3. A `fan_out`'s `carry:` captured into each
  # item's own context and propagated nothing past the stage — the silent-bug
  # shape the removal closes — so `assert_carry_placement!/4` rejects it by name
  # and points the author at the item chain. `:gate` simply falls to the generic
  # unknown-option gate. `carry:` still rides `@common_options` for `@stage_options`
  # and the `child_pipeline` `known` list.
  @fan_out_options [
                     :over,
                     :parent,
                     :concurrency,
                     :catch_item_failures
                   ] ++ (@common_options -- [:carry])

  # `(hook key, arity)` for EVERY hook any declaration may name — the `use`-level
  # three, the five a stage may declare, and the four that ride inside another
  # option. This attribute is the single source: `hook/2` builds the capture at
  # the arity it finds here, and `__assert_hooks_defined__!/2` checks the module
  # defines that same arity, so the two can never disagree. Read it through
  # `__hook_arities__/0`; do not restate an arity anywhere else.
  @hook_arities [
    metadata: 1,
    complete_metadata: 1,
    init: 0,
    input: 2,
    over: 1,
    body: 2,
    skip_when: 1,
    from: 1,
    summarize: 2,
    start: 1,
    stop: 1,
    args: 2,
    dry_run: 1
  ]

  # The subset a `stage`/`fan_out` declares directly, in the order they are read.
  @stage_hook_keys [:input, :over, :body]

  @typedoc "A validated `use ALLM.Pipeline` declaration. Hook values are quoted AST."
  @type declaration :: %{
          name: String.t(),
          metadata: Macro.t() | nil,
          complete_metadata: Macro.t() | nil,
          init: Macro.t() | nil,
          returns: :summary | :run,
          concurrency: Macro.t(),
          borrowed_run: boolean(),
          dry_run: Macro.t() | nil,
          summary_type: atom() | nil,
          atom_hooks: [{atom(), atom(), arity()}]
        }

  @typedoc "One accumulated stage specification. Hook values are quoted AST."
  @type stage_spec :: %{
          name: atom(),
          kind: :stage | :fan_out | :child_pipeline,
          step: Macro.t() | nil,
          hooks: keyword(Macro.t()),
          scalars: keyword(Macro.t()),
          atom_hooks: [{atom(), atom(), arity()}]
        }

  @typedoc "One accumulated `resource` declaration. Hook values are quoted AST."
  @type resource_spec :: %{
          name: atom(),
          start: Macro.t(),
          stop: Macro.t(),
          atom_hooks: [{atom(), atom(), arity()}]
        }

  # ── Constructs ────────────────────────────────────────────────────────────

  @doc """
  Declare a stage that runs **once**.

      stage :list, MeetingListScraper, input: :build_list_input
      stage :committee_cache, fn _ctx, _prev -> {:ok, ensure_cache()} end

  Options: `input:`, `skip_when:`, `carry:`, `on_error:`.
  """
  defmacro stage(name, target, opts \\ []) do
    spec = __stage__(:stage, __CALLER__, name, target, opts)
    accumulate(spec)
  end

  @doc """
  Declare a stage that runs **once per item** produced by its `over:` hook.

      fan_out :detail, CommitteeDetailScraper, over: :committees_from, input: :detail_input

  A `fan_out` always names a **Step-module** target. The `body:`-mode form was
  removed in Phase 4.5 — to fold an ordinary body over the items, call
  `ALLM.Pipeline.FanOut.reduce/5` from a plain `stage` body instead.

  Options: `input:` (required), `over:` (required), plus `skip_when:`,
  `parent:`, `concurrency:` and `catch_item_failures:`. **Not** `carry:` — a
  fan-out captures nothing to propagate (removed in Phase 4.5.3; read per-item
  values off the `[Item.t()]` output instead). **Not** `on_error:` — that governs
  a whole-stage failure, which a fan-out does not have; both are a compile error
  here.
  """
  defmacro fan_out(name, step, opts \\ []) do
    spec = __stage__(:fan_out, __CALLER__, name, step, opts)
    accumulate(spec)
  end

  @doc """
  Declare a stage that invokes **another pipeline's** entry point.

      child_pipeline :enrich, ProjectEnrichmentPipeline, :run, args: :enrich_args

  The child creates and terminates its **own** `PipelineRun`; this pipeline's
  run is untouched by it and gains no step log. What the construct adds over an
  escape-hatch `stage` is the link: `args:` returns the full argument LIST, and
  the DSL merges `parent_run_id: <this run's id>` into its **last** element —
  which must be a keyword list.

  Merging into the last element rather than appending is what keeps the child's
  arity intact. All three live consumer call sites are `run(opts)` today
  (`project_refresh_pipeline.ex:204`, `:266`, `:275`), so a plain append would
  work for them — but `ProjectEnrichmentPipeline.run_single/2` is an
  `f(id, opts)` entry point that exists now and would break under one.

  Options: `args:` (required), plus `skip_when:`, `carry:`, `retry:` and
  `on_error:` as a `stage` has them.
  """
  defmacro child_pipeline(name, module, fun, opts \\ []) do
    spec = __child_pipeline__(__CALLER__, name, module, fun, opts)
    accumulate(spec)
  end

  @doc """
  Declare a handle acquired **once per run** and released before the terminal write.

      resource :browser, start: :open_browser, stop: :close_browser

  `start:` is `(ctx)` and returns the handle; `stop:` is `(handle)`. The handle
  reaches every step and body as `ALLM.Pipeline.Context.resource(ctx, :browser)`
  — a struct field, never an `opts` key. Multiple `resource` declarations are
  acquired in declaration order and released in reverse.

  Teardown ordering, its failure handling, and why a teardown failure never
  changes the run's status are `ALLM.Pipeline.Dsl.Resource`'s moduledoc
  (Phase 4 D3).
  """
  defmacro resource(name, opts) do
    spec = __resource__(__CALLER__, name, opts)

    quote do
      @allm_pipeline_resources unquote(Macro.escape(spec))
    end
  end

  @doc """
  Declare the one `ALLM.Pipeline.Metrics` row this pipeline records.

      metrics "meetings", from: :funnel

  `from:` receives the value `summarize` produced and returns an
  `ALLM.Pipeline.Metrics.funnel()`. A pipeline that deliberately records no
  metrics simply omits the declaration.
  """
  defmacro metrics(entity_type, opts) do
    caller = __CALLER__
    entity = validate_entity_type!(caller.module, entity_type)

    unless keyword_ast?(opts) and Keyword.has_key?(opts, :from) do
      raise ArgumentError,
            "#{inspect(caller.module)}: `metrics #{inspect(entity)}, …` requires `from:` " <>
              "— an arity-1 hook taking what `summarize` produced and returning an " <>
              "ALLM.Pipeline.Metrics.funnel(). There is one `metrics` form (Phase 4 D10)."
    end

    case Keyword.keys(opts) -- [:from] do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_message(caller.module, "metrics", unknown, [:from])
    end

    {ast, atom_hooks} = hook(Keyword.fetch!(opts, :from), :from)

    quote do
      @allm_pipeline_metrics %{entity_type: unquote(entity), from: unquote(Macro.escape(ast))}
      @allm_pipeline_metrics_hooks unquote(Macro.escape(atom_hooks))
    end
  end

  @doc """
  Declare the hook that turns the accumulator into this pipeline's summary.

      summarize :finalize          # (acc, ctx) -> term()

  It runs at step 4 — **before** the terminal write — which is why a pipeline
  needing the completed `%PipelineRun{}` as its return value declares
  `returns: :run` instead of trying to produce it here.
  """
  defmacro summarize(hook) do
    {ast, atom_hooks} = hook(hook, :summarize)

    quote do
      @allm_pipeline_summarize unquote(Macro.escape(ast))
      @allm_pipeline_summarize_hooks unquote(Macro.escape(atom_hooks))
    end
  end

  # ── Compile-time validation ───────────────────────────────────────────────

  @doc false
  # Parameter order is `(module, opts)`, matching `Registry.__validate__!/2`,
  # `LLMStep.__validate__!/2` and `Schema.__validate_field__!/3` — the package's
  # shape for a compile-time validator is "the module being validated first".
  #
  # `opts` is the QUOTED option list from `use ALLM.Pipeline, …`, not evaluated
  # terms: hook values must survive to `__before_compile__` as AST. Scalars are
  # therefore validated as literals, which is also what makes a malformed one a
  # compile error rather than a runtime surprise.
  @spec __validate__!(module(), Macro.t()) :: declaration()
  def __validate__!(module, opts) do
    unless keyword_ast?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: `use ALLM.Pipeline` takes a keyword list, " <>
              "got: #{Macro.to_string(opts)}"
    end

    case Keyword.keys(opts) -- @use_options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, unknown_message(module, "use ALLM.Pipeline", unknown, @use_options)
    end

    {metadata, a1} = use_hook(opts, :metadata)
    {complete_metadata, a2} = use_hook(opts, :complete_metadata)
    {init, a3} = use_hook(opts, :init)
    {dry_run, a4} = use_hook(opts, :dry_run)
    returns = fetch_returns!(module, opts)

    %{
      name: fetch_name!(module, opts),
      metadata: metadata,
      complete_metadata: complete_metadata,
      init: init,
      returns: returns,
      concurrency:
        validate_concurrency!(module, Keyword.get(opts, :concurrency, 1), "use ALLM.Pipeline"),
      borrowed_run: fetch_borrowed_run!(module, opts, dry_run),
      dry_run: dry_run,
      summary_type: fetch_summary_type!(module, opts, returns),
      atom_hooks: a1 ++ a2 ++ a3 ++ a4
    }
  end

  @doc false
  # The single source for every hook arity in the DSL. Public (as `@doc false`)
  # so the moduledoc can cite it instead of restating it and so a membership
  # test can pin the set — root `CLAUDE.md`: a rule enforced in more than one
  # shape needs a membership guard.
  @spec __hook_arities__() :: [{atom(), arity()}]
  def __hook_arities__, do: @hook_arities

  @doc false
  # The `use ALLM.Pipeline` option vocabulary. Same reason as
  # `__hook_arities__/0` above: `@use_options` and `ALLM.Pipeline`'s
  # `## \`use\` options` moduledoc table are two hand-maintained copies of one
  # vocabulary, and this is what lets `dsl_test.exs` pin that they agree rather
  # than leaving the third of the DSL's three mirrored vocabularies eye-checked
  # (code review 4.3 F8).
  @spec __use_options__() :: [atom()]
  def __use_options__, do: @use_options

  @doc false
  # Every atom hook a declaration named, checked against what the module
  # actually defines. Runs from `__before_compile__`, which is the earliest
  # point at which `Module.defines?/2` can answer.
  @spec __assert_hooks_defined__!(Macro.Env.t(), [{atom(), atom(), arity()}]) :: :ok
  def __assert_hooks_defined__!(env, atom_hooks) do
    for {option, name, arity} <- atom_hooks, not Module.defines?(env.module, {name, arity}) do
      raise ArgumentError,
            "#{inspect(env.module)}: `#{option}: #{inspect(name)}` names " <>
              "#{name}/#{arity}, which this module does not define. A hook atom expands to a " <>
              "local capture, so it may be `defp` — but it must exist."
    end

    :ok
  end

  @doc false
  # The quoted `%Stage{}` a spec compiles to. Called from
  # `ALLM.Pipeline.__before_compile__/1` so the splice lands in the using
  # module, where a local capture resolves.
  @spec __stage_ast__(stage_spec()) :: Macro.t()
  def __stage_ast__(spec) do
    fields =
      [name: spec.name, kind: spec.kind, step: spec.step] ++ spec.hooks ++ spec.scalars

    quote do
      struct!(unquote(Stage), unquote({:%{}, [], fields}))
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  @spec __resource__(Macro.Env.t(), Macro.t(), Macro.t()) :: resource_spec()
  defp __resource__(caller, name, opts) do
    module = caller.module
    label = "resource #{Macro.to_string(name)}"

    unless is_atom(name) and not is_nil(name) do
      raise ArgumentError,
            "#{inspect(module)}: a resource's name must be a literal atom, " <>
              "got: #{Macro.to_string(name)}"
    end

    unless keyword_ast?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}` takes a keyword list of options, " <>
              "got: #{Macro.to_string(opts)}"
    end

    case Keyword.keys(opts) -- [:start, :stop] do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_message(module, label, unknown, [:start, :stop])
    end

    # BOTH are required, and `stop:` is the one that matters: a resource with no
    # `stop` is a value, and the construct exists for the release half. There is
    # no default — only the declaring module knows how to close its handle.
    for key <- [:start, :stop], not Keyword.has_key?(opts, key) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}` requires `#{key}:`. A `resource` is an " <>
              "acquire/release pair; if there is nothing to release, it is not a resource."
    end

    {start_ast, start_atoms} = hook(Keyword.fetch!(opts, :start), :start)
    {stop_ast, stop_atoms} = hook(Keyword.fetch!(opts, :stop), :stop)

    %{name: name, start: start_ast, stop: stop_ast, atom_hooks: start_atoms ++ stop_atoms}
  end

  @spec __child_pipeline__(Macro.Env.t(), Macro.t(), Macro.t(), Macro.t(), Macro.t()) ::
          stage_spec()
  defp __child_pipeline__(caller, name, child_module, fun, opts) do
    module = caller.module
    label = "child_pipeline #{Macro.to_string(name)}"
    # COMPOSED, not hand-copied — this is a fourth member of the same vocabulary
    # as `@stage_options` and `@fan_out_options` above. Copied, a fifth common
    # option would reach `stage` and `fan_out` automatically and silently skip
    # `child_pipeline`, so a declaration the sibling kinds accept would raise
    # "unknown option" here.
    #
    # `:input` is the exclusion: it is a Step's input builder and a child
    # pipeline has no Step. Everything else a stage may declare, a
    # `child_pipeline` may too.
    known = [:args | @common_options -- [:input]] ++ [:on_error]

    unless is_atom(name) do
      raise ArgumentError,
            "#{inspect(module)}: a child_pipeline's name must be a literal atom, " <>
              "got: #{Macro.to_string(name)}"
    end

    # An ALIAS, for the same reason `stage/3` demands one: `is_atom/1` cannot
    # tell a module from a hook name once an alias is expanded.
    unless match?({:__aliases__, _, _}, child_module) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}`'s second argument must be a module alias — " <>
              "`child_pipeline :name, OtherPipeline, :run, args: …`, got: " <>
              "#{Macro.to_string(child_module)}"
    end

    unless is_atom(fun) and not is_nil(fun) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}`'s third argument must be a literal function name " <>
              "atom, got: #{Macro.to_string(fun)}"
    end

    unless keyword_ast?(opts) and Keyword.has_key?(opts, :args) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}` requires `args:` — an arity-2 hook " <>
              "`(ctx, subject)` returning the child's argument LIST, whose last element is " <>
              "the keyword list `parent_run_id:` is merged into."
    end

    case Keyword.keys(opts) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_message(module, label, unknown, known)
    end

    {args_ast, args_atoms} = hook(Keyword.fetch!(opts, :args), :args)
    {scalars, scalar_atoms} = stage_scalars(module, :child_pipeline, label, opts)

    child_ast =
      quote do
        %{module: unquote(child_module), fun: unquote(fun), args: unquote(args_ast)}
      end

    %{
      name: name,
      kind: :child_pipeline,
      step: nil,
      hooks: Enum.map(@stage_hook_keys, &{&1, nil}) ++ [child: child_ast],
      scalars: scalars,
      atom_hooks: args_atoms ++ scalar_atoms
    }
  end

  @spec accumulate(stage_spec()) :: Macro.t()
  defp accumulate(spec) do
    quote do
      @allm_pipeline_stages unquote(Macro.escape(spec))
    end
  end

  @spec __stage__(:stage | :fan_out, Macro.Env.t(), Macro.t(), Macro.t(), Macro.t()) ::
          stage_spec()
  defp __stage__(kind, caller, name, target, opts) do
    module = caller.module
    known = if kind == :fan_out, do: @fan_out_options, else: @stage_options
    label = "#{kind} #{Macro.to_string(name)}"

    unless is_atom(name) do
      raise ArgumentError,
            "#{inspect(module)}: a #{kind}'s name must be a literal atom, " <>
              "got: #{Macro.to_string(name)}"
    end

    unless keyword_ast?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}` takes a keyword list of options, " <>
              "got: #{Macro.to_string(opts)}"
    end

    assert_on_error_placement!(module, kind, label, opts)
    assert_carry_placement!(module, kind, label, opts)

    case Keyword.keys(opts) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_message(module, label, unknown, known)
    end

    {step, body_from_target, target_hooks} = split_target(module, kind, label, target)
    opts = if body_from_target, do: Keyword.put(opts, :body, body_from_target), else: opts

    assert_runnable!(module, kind, label, step, opts)

    {hooks, hook_atoms} =
      Enum.reduce(@stage_hook_keys, {[], []}, fn key, {hooks, atoms} ->
        case Keyword.fetch(opts, key) do
          :error ->
            {hooks ++ [{key, nil}], atoms}

          {:ok, value} ->
            {ast, named} = hook(value, key)
            {hooks ++ [{key, ast}], atoms ++ named}
        end
      end)

    {scalars, scalar_atoms} = stage_scalars(module, kind, label, opts)

    %{
      name: name,
      kind: kind,
      step: step,
      hooks: hooks,
      scalars: scalars,
      atom_hooks: target_hooks ++ hook_atoms ++ scalar_atoms
    }
  end

  # An alias is the Step form; anything else is the escape hatch. See the
  # moduledoc — this is a SHAPE test, and `is_atom/1` is the trap. It serves
  # BOTH kinds, so it is kind-conditional: a `:fan_out` requires a Step-module
  # alias (the `body:`-mode form was removed in Phase 4.5), while a `:stage`
  # keeps its escape-hatch body branches (a keyword-list or an inline `fn`).
  @spec split_target(module(), atom(), String.t(), Macro.t()) ::
          {Macro.t() | nil, Macro.t() | nil, [{atom(), atom(), arity()}]}
  defp split_target(_module, _kind, _label, nil), do: {nil, nil, []}

  defp split_target(_module, _kind, _label, {:__aliases__, _, _} = alias_ast),
    do: {alias_ast, nil, []}

  defp split_target(module, :fan_out, label, _target) do
    raise ArgumentError,
          "#{inspect(module)}: a `fan_out` requires a Step-module target (#{label}) — write " <>
            "`fan_out :name, MyStep, over: …, input: …`. The `body:`-mode `fan_out` was " <>
            "removed in Phase 4.5; to fold a body over the items, call " <>
            "`ALLM.Pipeline.FanOut.reduce/5` from a plain `stage` body instead."
  end

  defp split_target(module, kind, label, target) do
    if keyword_ast?(target) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}` was given a keyword list where a Step module or a " <>
              "body was expected. Write `#{kind} :name, MyStep, input: …` or " <>
              "`#{kind} :name, fn ctx, prev -> … end`."
    end

    {ast, atoms} = hook(target, :body)
    {nil, ast, atoms}
  end

  # `on_error:` is read by `Runtime.apply_result/3`, which the `:fan_out` branch
  # of `do_stage/5` never reaches: a fan-out cannot fail AS A STAGE — every item
  # outcome lands in the `[Dsl.Item.t()]` it returns and the stage itself always
  # succeeds. So the option would compile, validate and do nothing. Rejected by
  # name rather than through the generic unknown-option message, because the
  # remedy is a different construct, not a typo.
  @spec assert_on_error_placement!(module(), atom(), String.t(), Macro.t()) :: :ok
  defp assert_on_error_placement!(module, :fan_out, label, opts) do
    if Keyword.has_key?(opts, :on_error) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}` declares `on_error:`, which governs a WHOLE-STAGE " <>
              "failure and therefore does not apply to a `fan_out` — a fan-out's items fail " <>
              "individually into its `[ALLM.Pipeline.Dsl.Item.t()]` output and the stage " <>
              "itself always succeeds. For per-item failures use `catch_item_failures: true`; " <>
              "to act on them, read the item results in the next stage or in `summarize`."
    end

    :ok
  end

  defp assert_on_error_placement!(_module, _kind, _label, _opts), do: :ok

  # A targeted rejection so `carry:` on a `fan_out` names the item-chain
  # alternative rather than falling to the generic "unknown option" message
  # (Phase 4.5.3). `carry:` is off `@fan_out_options`, so the generic gate would
  # reject it anyway — but the trap it used to be (captures into each item's own
  # context, propagates nothing) is exactly what a bare "unknown option" would
  # fail to explain.
  @spec assert_carry_placement!(module(), atom(), String.t(), Macro.t()) :: :ok
  defp assert_carry_placement!(module, :fan_out, label, opts) do
    if Keyword.has_key?(opts, :carry) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}` declares `carry:`, which is not available on a " <>
              "`fan_out` — it would capture into each item's own context and propagate nothing " <>
              "past the stage, exactly the silent-bug shape Phase 4.5.3 removed. To read a " <>
              "per-item value downstream, filter the fan-out's `[ALLM.Pipeline.Dsl.Item.t()]` " <>
              "output with `ALLM.Pipeline.Dsl.Item.ok_items/1` in the next stage and read the " <>
              "field off each item. `carry:` remains available on a `stage` (captured from its " <>
              "own output) and on a `child_pipeline`."
    end

    :ok
  end

  defp assert_carry_placement!(_module, _kind, _label, _opts), do: :ok

  @spec assert_runnable!(module(), atom(), String.t(), Macro.t() | nil, Macro.t()) :: :ok
  defp assert_runnable!(module, kind, label, step, opts) do
    if is_nil(step) and is_nil(Keyword.get(opts, :body)) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}` declares neither a Step module nor a `body:` — " <>
              "there is nothing for it to run."
    end

    if not is_nil(step) and is_nil(Keyword.get(opts, :input)) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}` names a Step module, so it requires `input:` — " <>
              "an arity-2 hook `(ctx, subject)` building that Step's input struct. There is " <>
              "no default: only the declaring module knows how to build one."
    end

    if kind == :fan_out and is_nil(Keyword.get(opts, :over)) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}` requires `over:` — an arity-1 hook taking the " <>
              "previous stage's output and returning the list of items to fan out over."
    end

    :ok
  end

  @spec stage_scalars(module(), atom(), String.t(), Macro.t()) ::
          {keyword(Macro.t()), [{atom(), atom(), arity()}]}
  defp stage_scalars(module, kind, label, opts) do
    concurrency =
      case Keyword.fetch(opts, :concurrency) do
        :error -> nil
        {:ok, value} -> validate_concurrency!(module, value, label)
      end

    {skip_when, skip_atoms} = validate_skip_when!(Keyword.get(opts, :skip_when))

    scalars = [
      skip_when: skip_when,
      carry: validate_carry!(module, label, Keyword.get(opts, :carry, [])),
      parent: validate_parent!(module, kind, label, Keyword.get(opts, :parent, :source_stage)),
      concurrency: concurrency,
      catch_item_failures:
        validate_boolean!(
          module,
          label,
          :catch_item_failures,
          Keyword.get(opts, :catch_item_failures, false)
        ),
      on_error: validate_on_error!(module, label, Keyword.get(opts, :on_error, :fail_run)),
      retry: validate_retry!(module, label, Keyword.get(opts, :retry))
    ]

    {scalars, skip_atoms}
  end

  @spec validate_skip_when!(Macro.t() | nil) :: {Macro.t() | nil, [{atom(), atom(), arity()}]}
  defp validate_skip_when!(nil), do: {nil, []}
  defp validate_skip_when!(value), do: hook(value, :skip_when)

  @spec validate_carry!(module(), String.t(), Macro.t()) :: Macro.t()
  defp validate_carry!(module, label, value) do
    if is_list(value) and Enum.all?(value, &is_atom/1) do
      value
    else
      raise ArgumentError,
            "#{inspect(module)}: `#{label}`'s `carry:` must be a literal list of field " <>
              "atoms, got: #{Macro.to_string(value)}"
    end
  end

  @spec validate_parent!(module(), atom(), String.t(), Macro.t()) :: Macro.t()
  defp validate_parent!(_module, _kind, _label, parent) when parent in [:source_stage, :per_item],
    do: parent

  defp validate_parent!(module, _kind, label, parent) do
    raise ArgumentError,
          "#{inspect(module)}: `#{label}`'s `parent:` must be `:source_stage` or `:per_item`, " <>
            "got: #{Macro.to_string(parent)}"
  end

  @spec validate_on_error!(module(), String.t(), Macro.t()) :: Macro.t()
  defp validate_on_error!(_module, _label, on_error) when on_error in [:fail_run, :continue],
    do: on_error

  defp validate_on_error!(module, label, on_error) do
    raise ArgumentError,
          "#{inspect(module)}: `#{label}`'s `on_error:` must be `:fail_run` or `:continue`, " <>
            "got: #{Macro.to_string(on_error)}"
  end

  @spec validate_boolean!(module(), String.t(), atom(), Macro.t()) :: Macro.t()
  defp validate_boolean!(_module, _label, _key, value) when is_boolean(value), do: value

  defp validate_boolean!(module, label, key, value) do
    raise ArgumentError,
          "#{inspect(module)}: `#{label}`'s `#{key}:` must be `true` or `false`, " <>
            "got: #{Macro.to_string(value)}"
  end

  # Phase 4 D11: `retry:` RE-INVOKES the target and produces one step log per
  # attempt. `max:` counts ATTEMPTS, not retries, so `max: 1` is a declaration
  # that never retries and is rejected — it reads as "one retry" and is the
  # off-by-one this option's name invites.
  @spec validate_retry!(module(), String.t(), Macro.t() | nil) :: Macro.t() | nil
  defp validate_retry!(_module, _label, nil), do: nil

  defp validate_retry!(module, label, spec) do
    known = [:max, :backoff, :base_ms, :on]

    unless keyword_ast?(spec) and Keyword.has_key?(spec, :max) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}`'s `retry:` must be a keyword list carrying `max:`, " <>
              "e.g. `retry: [max: 3, backoff: :exponential, on: [:rate_limited]]`, " <>
              "got: #{Macro.to_string(spec)}"
    end

    case Keyword.keys(spec) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_message(module, "#{label}'s retry:", unknown, known)
    end

    max = Keyword.fetch!(spec, :max)

    unless is_integer(max) and max > 1 do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}`'s `retry: [max: …]` counts total ATTEMPTS and must " <>
              "be an integer greater than 1, got: #{Macro.to_string(max)}"
    end

    backoff = Keyword.get(spec, :backoff, :none)

    unless backoff in [:none, :linear, :exponential] do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}`'s `retry: [backoff: …]` must be `:none`, " <>
              "`:linear` or `:exponential`, got: #{Macro.to_string(backoff)}"
    end

    base_ms = Keyword.get(spec, :base_ms, 1_000)

    unless is_integer(base_ms) and base_ms >= 0 do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}`'s `retry: [base_ms: …]` must be a non-negative " <>
              "integer, got: #{Macro.to_string(base_ms)}"
    end

    on = Keyword.get(spec, :on, :any)

    unless on == :any or (is_list(on) and on != [] and Enum.all?(on, &is_atom/1)) do
      raise ArgumentError,
            "#{inspect(module)}: `#{label}`'s `retry: [on: …]` must be `:any` or a non-empty " <>
              "literal list of reason atoms, got: #{Macro.to_string(on)}"
    end

    quote do
      %{max: unquote(max), backoff: unquote(backoff), base_ms: unquote(base_ms), on: unquote(on)}
    end
  end

  # `summary_type:` names a ZERO-ARITY type the using module defines, and its
  # only effect is on the GENERATED `@spec run/1`: without it the return is
  # `{:ok, term()}` and dialyzer stops type-checking every consumer of the
  # pipeline's stats map. Under `returns: :run` the summary type is already
  # known (`PipelineRun.t()`), so declaring both is a contradiction rather than
  # a redundancy.
  @spec fetch_summary_type!(module(), Macro.t(), :summary | :run) :: atom() | nil
  defp fetch_summary_type!(module, opts, returns) do
    case {Keyword.fetch(opts, :summary_type), returns} do
      {:error, _returns} ->
        nil

      {{:ok, _type}, :run} ->
        raise ArgumentError,
              "#{inspect(module)}: `summary_type:` and `returns: :run` cannot both be " <>
                "declared — under `returns: :run` the generated `run/1` returns the completed " <>
                "`ALLM.Pipeline.PipelineRun.t()`, which is already typed."

      {{:ok, type}, _returns} when is_atom(type) and not is_nil(type) and not is_boolean(type) ->
        type

      {{:ok, other}, _returns} ->
        raise ArgumentError,
              "#{inspect(module)}: `summary_type:` must be an atom naming a zero-arity type " <>
                "this module defines (e.g. `summary_type: :stats` for `@type stats :: …`), " <>
                "got: #{Macro.to_string(other)}"
    end
  end

  # `borrowed_run: true` and `dry_run:` are mutually exclusive, and the rejection
  # is the whole implementation of that rule — there is no runtime branch for the
  # pair. `Runtime.run/1` resolves the lent handle (`lent_run/2`) BEFORE the dry
  # branch (`dry_run?/2`), so a declaration carrying both, invoked with a lent run
  # and a truthy `:dry_run`, would execute every stage for real with the flag
  # silently dropped and return `{:ok, …}` indistinguishable from a successful
  # plan — the one shape in which "`--dry-run` did not stop the work" is reachable
  # without a declaration bug, on the phase where a stage costs LLM tokens.
  # Inverting the precedence instead was rejected: a dry borrowed run cannot
  # complete a run it does not own, so honouring the flag there needs new runtime
  # semantics for a shape that has no consumer. Rejected at compile time, which is
  # the only moment anyone can act on it — as `summary_type:` + `returns: :run`
  # already is. Cost, accepted: a pipeline cannot be dry-runnable when self-owned
  # and lendable otherwise.
  @spec fetch_borrowed_run!(module(), Macro.t(), Macro.t() | nil) :: Macro.t()
  defp fetch_borrowed_run!(module, opts, dry_run) do
    borrowed =
      validate_boolean!(
        module,
        "use ALLM.Pipeline",
        :borrowed_run,
        Keyword.get(opts, :borrowed_run, false)
      )

    if borrowed == true and not is_nil(dry_run) do
      raise ArgumentError,
            "#{inspect(module)}: `borrowed_run: true` and `dry_run:` cannot both be " <>
              "declared — `run/1` resolves the lent run before the dry branch, so under a " <>
              "lent run every stage would execute for real with the flag silently dropped, " <>
              "and a dry borrowed run cannot complete a run it does not own."
    end

    borrowed
  end

  @spec validate_concurrency!(module(), Macro.t(), String.t()) :: Macro.t()
  defp validate_concurrency!(_module, n, _label) when is_integer(n) and n > 0, do: n

  defp validate_concurrency!(module, n, label) when is_integer(n) do
    raise ArgumentError,
          "#{inspect(module)}: `#{label}`'s `concurrency:` must be a positive integer, got: #{n}"
  end

  # A 3-element tuple is `{:{}, meta, elements}` in quoted form — which is the
  # ONLY shape `{:opt, key, default}` can arrive in here, since `__validate__!/2`
  # is handed quoted opts. (`Runtime.resolve_opt/2`, which sees the RUNTIME
  # value, matches the real tuple; the two are different sides of the same
  # `unquote`.) Validated directly rather than by recursing on a reconstructed
  # tuple: the recursion could only ever reach the raising catch-all, which
  # dialyzer reports as `call … will not succeed`.
  #
  # Returned as the QUOTED tuple it arrived as (the shared rule for every
  # `{:opt, …}`-shaped option — `validate_ms!/3` was its sibling until Phase 4.5
  # removed `delay:`): BOTH of this value's splice sites put
  # it back inside a `quote`, where a real 3-element tuple is not a valid AST
  # node — `__stage_ast__/1`'s `{:%{}, [], fields}` and
  # `ALLM.Pipeline.__before_compile__/1`'s `def __pipeline__(:concurrency)`.
  # This clause returned the REAL tuple until Phase 4.4, under a comment
  # asserting that `Macro.escape/1` covered it; `accumulate/1`'s escape runs
  # BEFORE the splice (it round-trips the spec through a module attribute) and
  # therefore does not. The whole `{:opt, …}` concurrency form was a compile
  # error — `** (CompileError) invalid quoted expression: {:opt, :concurrency, 2}`
  # — and unreachable for any consumer, which is why `committee`'s port is the
  # first thing to hit it.
  defp validate_concurrency!(_module, {:{}, _, [:opt, key, default]} = value, _label)
       when is_atom(key) and is_integer(default) and default > 0,
       do: value

  defp validate_concurrency!(module, other, label) do
    raise ArgumentError,
          "#{inspect(module)}: `#{label}`'s `concurrency:` must be a positive integer or " <>
            "`{:opt, key, default}` (so a CLI flag can still reach it), " <>
            "got: #{Macro.to_string(other)}"
  end

  @spec fetch_name!(module(), Macro.t()) :: String.t()
  defp fetch_name!(module, opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_binary(name) and name != "" ->
        name

      {:ok, other} ->
        raise ArgumentError,
              "#{inspect(module)}: `name:` must be a non-empty string literal — it is the " <>
                "`PipelineRun.name` passed to `Executor.create_pipeline_run/3`, not a cron " <>
                "atom (the two namespaces do not line up). Got: #{Macro.to_string(other)}"

      :error ->
        raise ArgumentError,
              "#{inspect(module)}: `use ALLM.Pipeline` requires `name:`, the run-name string."
    end
  end

  @spec fetch_returns!(module(), Macro.t()) :: :summary | :run
  defp fetch_returns!(_module, opts) do
    case Keyword.get(opts, :returns, :summary) do
      value when value in [:summary, :run] ->
        value

      other ->
        raise ArgumentError,
              "`returns:` must be `:summary` or `:run`, got: #{Macro.to_string(other)}"
    end
  end

  # `use`-level hooks are checked against the module in `__before_compile__`
  # alongside the stage hooks, so the atoms travel out with the declaration
  # rather than being written to an attribute that `__using__` has not yet
  # registered.
  @spec use_hook(Macro.t(), atom()) :: {Macro.t() | nil, [{atom(), atom(), arity()}]}
  defp use_hook(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> {nil, []}
      {:ok, value} -> hook(value, key)
    end
  end

  # An atom is a local capture at the arity `@hook_arities` declares for that
  # option; anything else is spliced verbatim. The returned atom list is what
  # `__assert_hooks_defined__!/2` checks against the module — same attribute,
  # so the capture and the existence check can never disagree.
  @spec hook(Macro.t(), atom()) :: {Macro.t(), [{atom(), atom(), arity()}]}
  defp hook(value, option), do: hook(value, option, Keyword.fetch!(@hook_arities, option))

  @spec hook(Macro.t(), atom(), arity()) :: {Macro.t(), [{atom(), atom(), arity()}]}
  defp hook(name, option, arity)
       when is_atom(name) and not is_nil(name) and not is_boolean(name) do
    {{:&, [], [{:/, [], [{name, [], nil}, arity]}]}, [{option, name, arity}]}
  end

  defp hook(ast, _option, _arity), do: {ast, []}

  @spec validate_entity_type!(module(), Macro.t()) :: String.t()
  defp validate_entity_type!(_module, entity) when is_binary(entity) and entity != "", do: entity

  defp validate_entity_type!(module, other) do
    raise ArgumentError,
          "#{inspect(module)}: `metrics`' entity type must be a non-empty string literal " <>
            "(it becomes `pipeline_metrics.entity_type`), got: #{Macro.to_string(other)}"
  end

  @spec keyword_ast?(Macro.t()) :: boolean()
  defp keyword_ast?(ast), do: is_list(ast) and Keyword.keyword?(ast)

  @spec unknown_message(module(), String.t(), [atom()], [atom()]) :: String.t()
  defp unknown_message(module, label, unknown, known) do
    "#{inspect(module)}: unknown `#{label}` option(s) #{inspect(unknown)}. " <>
      "Known options: #{inspect(known)}."
  end
end
