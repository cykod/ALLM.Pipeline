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
  be written as a bare atom naming a **private** function.

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
  | `skip_when:` | `(ctx)` — or the data form `{:opt, key, default}` |
  | `metrics …, from:` | `(acc)` |
  | `summarize` | `(acc, ctx)` |
  | `resource …, start:` | `(ctx)` |
  | `resource …, stop:` | `(handle)` |
  | `dry_run:` | `(ctx)` |

  `subject` is the previous stage's output for a `stage`, and the item for a
  `fan_out`. Note `carry:` does **not** capture from the subject — see
  `ALLM.Pipeline.Dsl.Stage`'s `carry` row.

  ## The two `stage/3` forms are told apart by AST SHAPE, not by a keyword

  An alias — `MyApp.ListScraper` — arrives as `{:__aliases__, _, _}` and means
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

  @common_options [:input, :skip_when, :carry]

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
  # unknown-option gate. `carry:` still rides `@common_options` for `@stage_options`.
  # (`:catch_item_failures` was removed in Phase 5.10 as a zero-consumer option;
  # the concurrent path's always-on link-safe catch is unconditional and was
  # never the option — see `Runtime.guarded_item/6`.)
  @fan_out_options [
                     :over,
                     :parent,
                     :concurrency
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
          kind: :stage | :fan_out,
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

      stage :list, MyApp.ListScraper, input: :build_list_input
      stage :warm_cache, fn _ctx, _prev -> {:ok, ensure_cache()} end

  Options: `input:`, `skip_when:`, `carry:`, `on_error:`.
  """
  defmacro stage(name, target, opts \\ []) do
    spec = __stage__(:stage, __CALLER__, name, target, opts)
    accumulate(spec)
  end

  @doc """
  Declare a stage that runs **once per item** produced by its `over:` hook.

      fan_out :detail, MyApp.DetailScraper, over: :items_from, input: :detail_input

  A `fan_out` always names a **Step-module** target. To fold an ordinary body
  over the items instead, call `ALLM.Pipeline.FanOut.reduce/5` from a plain
  `stage` body.

  Options: `input:` (required), `over:` (required), plus `skip_when:`,
  `parent:` and `concurrency:`. **Not** `carry:` — a
  fan-out captures nothing to propagate (read per-item values off the
  `[Item.t()]` output instead). **Not** `on_error:` — that governs
  a whole-stage failure, which a fan-out does not have; both are a compile error
  here.
  """
  defmacro fan_out(name, step, opts \\ []) do
    spec = __stage__(:fan_out, __CALLER__, name, step, opts)
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
  changes the run's status are `ALLM.Pipeline.Dsl.Resource`'s moduledoc.
  """
  defmacro resource(name, opts) do
    spec = __resource__(__CALLER__, name, opts)

    quote do
      @allm_pipeline_resources unquote(Macro.escape(spec))
    end
  end

  @doc """
  Declare the one `ALLM.Pipeline.Metrics` row this pipeline records.

      metrics "records", from: :funnel

  `from:` receives the accumulator — the value the stages folded, the same
  input `summarize` sees — and returns an `ALLM.Pipeline.Metrics.funnel()`. A
  pipeline that deliberately records no metrics simply omits the declaration.
  """
  defmacro metrics(entity_type, opts) do
    caller = __CALLER__
    entity = validate_entity_type!(caller.module, entity_type)

    unless keyword_ast?(opts) and Keyword.has_key?(opts, :from) do
      raise ArgumentError,
            "#{inspect(caller.module)}: `metrics #{inspect(entity)}, …` requires `from:` " <>
              "— an arity-1 hook taking the accumulator and returning an " <>
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
              "itself always succeeds. To act on per-item failures, read the item results in " <>
              "the next stage or in `summarize`."
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
              "own output)."
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

    {skip_when, skip_atoms} = validate_skip_when!(module, label, Keyword.get(opts, :skip_when))

    scalars = [
      skip_when: skip_when,
      carry: validate_carry!(module, label, Keyword.get(opts, :carry, [])),
      parent: validate_parent!(module, kind, label, Keyword.get(opts, :parent, :source_stage)),
      concurrency: concurrency,
      on_error: validate_on_error!(module, label, Keyword.get(opts, :on_error, :fail_run))
    ]

    {scalars, skip_atoms}
  end

  # `skip_when:` is either a 1-arity `(ctx)` hook (a bare atom naming one, or an
  # `fn`) — routed through `hook/2` as any hook — OR the `{:opt, key, default}`
  # data form, which since Phase 4.5.5 is validated by the SAME
  # `validate_opt_ref!/5` that backs `concurrency:` (one notation, one meaning).
  # An `{:opt, …}`-shaped value in any other arity (the old 2-tuple `{:opt, key}`,
  # a 4-tuple, …) is a compile error naming the stage, rather than the silent
  # runtime `FunctionClauseError` it used to be in `skip?/2`.
  @spec validate_skip_when!(module(), String.t(), Macro.t() | nil) ::
          {Macro.t() | nil, [{atom(), atom(), arity()}]}
  defp validate_skip_when!(_module, _label, nil), do: {nil, []}

  defp validate_skip_when!(module, label, value) do
    if opt_ref?(value) do
      # Message inlined at the call site, matching `concurrency:`'s form (4.5.5 F2).
      {validate_opt_ref!(
         module,
         label,
         value,
         fn _default -> true end,
         "`skip_when:` must be a 1-arity `(ctx)` hook (a bare atom naming one, or an " <>
           "`fn ctx -> … end`) or the data form `{:opt, key, default}` (Phase 4.5.5 removed " <>
           "the 2-tuple `{:opt, key}`: one notation, one meaning)"
       ), []}
    else
      hook(value, :skip_when)
    end
  end

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

  # Anything non-integer is either the `{:opt, key, default}` data form or a
  # mistake; both are handled by the shared `validate_opt_ref!/5`, whose default
  # predicate here demands a positive integer default so a resolved
  # `--concurrency` still yields a valid concurrency.
  defp validate_concurrency!(module, other, label) do
    validate_opt_ref!(
      module,
      label,
      other,
      &(is_integer(&1) and &1 > 0),
      "`concurrency:` must be a positive integer or `{:opt, key, default}` " <>
        "(so a CLI flag can still reach it)"
    )
  end

  # Is this quoted value an `{:opt, …}` reference in ANY arity? Both the
  # self-quoting 2-tuple `{:opt, key}` (2-tuples quote to themselves) and the
  # escaped n-tuple `{:{}, _, [:opt | _]}`. Used to route only opt-shaped values
  # to `validate_opt_ref!/5`, so a `skip_when:` hook atom or `fn` still passes
  # through `hook/2` untouched.
  @spec opt_ref?(Macro.t()) :: boolean()
  defp opt_ref?({:opt, _}), do: true
  defp opt_ref?({:{}, _, [:opt | _]}), do: true
  defp opt_ref?(_), do: false

  # The ONE validator for the `{:opt, key, default}` data form, shared by
  # `concurrency:` and `skip_when:` since Phase 4.5.5 collapsed the mini-language
  # to this single 3-tuple shape. It accepts ONLY the quoted 3-tuple
  # `{:{}, _, [:opt, key, default]}` with an atom key and a `default_ok?` default,
  # and RETURNS the quoted tuple it arrived as — BOTH consumers splice the result
  # back inside a `quote`, where a real 3-element tuple is not a valid AST node
  # (package `CLAUDE.md` §7): `__stage_ast__/1`'s `{:%{}, [], fields}` and
  # `ALLM.Pipeline.__before_compile__/1`'s `def __pipeline__(:concurrency)`. The
  # escaped `{:{}, _, [...]}` is already the form the splice needs; returning the
  # REAL tuple (as `validate_concurrency!` did until Phase 4.4) is
  # `** (CompileError) invalid quoted expression` at the using module, naming
  # neither the option nor this file. `default_ok?` is the option-specific
  # predicate on the default; `base_message` describes the accepted forms for the
  # rejection, which names the declaration's `label` (its stage). The 2-tuple
  # `{:opt, key}` and any other arity fall to the catch-all clause and are
  # rejected — the compile-time signal `skip_when:` lacked before 4.5.5.
  @spec validate_opt_ref!(module(), String.t(), Macro.t(), (term() -> boolean()), String.t()) ::
          Macro.t()
  defp validate_opt_ref!(
         module,
         label,
         {:{}, _, [:opt, key, default]} = value,
         default_ok?,
         base_message
       )
       when is_atom(key) do
    if default_ok?.(default) do
      value
    else
      raise ArgumentError,
            "#{inspect(module)}: `#{label}`'s #{base_message}, got: #{Macro.to_string(value)}"
    end
  end

  defp validate_opt_ref!(module, label, other, _default_ok?, base_message) do
    raise ArgumentError,
          "#{inspect(module)}: `#{label}`'s #{base_message}, got: #{Macro.to_string(other)}"
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
