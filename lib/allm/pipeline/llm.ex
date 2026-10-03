defmodule ALLM.Pipeline.LLM do
  @moduledoc """
  The seam through which the package calls a host's LLM engine.

  The package declares no host dependency (see this repo's `CLAUDE.md` §1),
  so `ALLM.Pipeline.LLMStep` **cannot name** a host's engine module (e.g.
  `MyApp.LLMEngine`). The engine is reached at RUNTIME
  through `impl/0` instead, exactly as the repo is reached through
  `ALLM.Pipeline.Config.repo/0` and the persistence adapter through
  `ALLM.Pipeline.Store.impl/0`.

  ## The success shape is the host's, unchanged

  `generate_structured/4` (or `/5`) returns the `{:ok, %{parsed: _, tokens: _}}` envelope
  the host's engine already returns, and the error term stays opaque to the
  package. This seam **relocates** the call; it does not redefine it. A host
  adapter is therefore a delegation, not a translation — e.g. a host's
  `MyApp.Pipelines.LLM`.

  ## Engine names are the host's vocabulary

  `resolve_engine/1` (or `/2`) takes an atom naming a *call-site intent*
  (`:nano`, `:summarize`, …) and returns whatever engine value the host's
  `generate_structured/4` (or `/5`) accepts. The package never inspects it and
  never validates the name — the vocabulary belongs to the host, and a step
  declaring `engine: :nano` is asserting that its host knows that name. An
  unknown name is the host adapter's error to raise.

  ## The step's context

  An adapter that exports `resolve_engine/2` or `generate_structured/5`
  receives the calling step's `ALLM.Pipeline.Context` as the last argument, and
  the package calls that arity in preference to `/1` / `/4` — per callback, so
  an adapter may take the context in one and not the other. This is how a host
  applies a per-run engine override, attributes a call to an account, or meters
  usage itself:

    * **The run's `opts` are the host's to read**, with
      `ALLM.Pipeline.Context.get_opt/3` (an engine-override map, an account
      id, …). The package interprets none of them — except `:queue_since`,
      which it adds to the options of every `fan_out` item (its telemetry
      dispatch timestamp). Treat that key as reserved.
    * **Four keys never reach `get_opt/3` inside a run.** `:resources`,
      `:carry`, `:acc` and `:input_step_id` are popped onto struct fields by
      `ALLM.Pipeline.Context.new/3`. An `ALLM.Pipeline.Context.detached/1`
      context pops nothing, so there they stay in `opts`.
    * **An escape-hatch body that calls `ALLM.Pipeline.Executor.run_step/5`
      itself passes `ctx.opts` through**, or the inner step's seam call sees
      none of them — the body owns that call.
    * **Run options are persisted.** Under the DSL's default `metadata:` hook a
      run's options are written to `pipeline_runs.metadata`, so a host passing
      engine structs or credentials as run options declares a `metadata:` hook
      that drops them — or passes names, not structs. An engine struct carrying
      an API key in its adapter options encodes with the key intact.

  The `/1` + `/4` pair stays mandatory. An adapter that needs the context in
  both callbacks still defines them, and should make them **raise** rather than
  delegate with an empty context: the package never calls them while the
  context arities are exported, so a call reaching one is a bug that an empty
  context would hide.

  A step called with a bare map or `nil` as its context (outside any run) is
  handed an empty `ALLM.Pipeline.Context.detached/0` context — never `nil`.

  ## There is no package default, and `impl/0` raises

  Unlike `Store`, `Artifacts` and `Lock` — each of which ships an adapter the
  package can fall back to — there is nothing here for the package to default
  to: an LLM adapter is a provider integration with credentials, retry policy
  and logging, all of which live in the host. A `nil`-returning or silently
  no-op default would be the documented fail-open shape (root `CLAUDE.md`: "a
  test-env default that does live I/O fails OPEN"), and its inverse — a default
  that quietly does nothing — is no better, because a step would then report
  success having called no model.

  So `impl/0` raises, naming the `llm:` registry key. That is the same shape
  `ALLM.Pipeline.Config.repo/0` uses, and for the same reason: the alternative fails far from
  the cause.

  ## Configuration

      defmodule MyApp.Pipelines do
        use ALLM.Pipeline.Registry,
          repo: MyApp.Repo,
          store: …, artifacts: …, lock: …,
          llm: MyApp.Pipelines.LLM
      end

  `llm:` is **optional** on the registry: a host that runs no LLM steps should
  not have to name an engine. Declaring it writes
  `config :allm_pipeline, ALLM.Pipeline.LLM, impl: MyApp.Pipelines.LLM`, with
  `put_new` semantics, so an env-specific config-file override still wins (see
  `ALLM.Pipeline.Registry`, "Precedence").
  """

  alias ALLM.Pipeline.Context

  @typedoc """
  A host engine handle, opaque to the package.

  Whatever `resolve_engine/1` (or `/2`) returns is passed straight back into
  `generate_structured/4` (or `/5`); nothing here inspects it.
  """
  @type engine :: term()

  @typedoc "A prompt string, or an explicit message list the host's engine understands."
  @type prompt :: String.t() | [term()]

  @typedoc """
  The host's structured-output envelope, unchanged.

  `parsed` is the decoded JSON object with **string** keys —
  `ALLM.Pipeline.LLMStep`'s `coerce/2` reads it by wire property name.
  """
  @type result ::
          {:ok, %{parsed: map(), tokens: non_neg_integer()}}
          | {:error, term()}

  @doc """
  Resolve a call-site intent name (`:nano`, `:summarize`, …) to a host engine.

  Raising on an unknown name is the adapter's responsibility: a typo'd
  `engine:` on a step must not silently fall back to a default engine.
  """
  @callback resolve_engine(name :: atom()) :: engine()

  @doc """
  Dispatch a strict-mode structured-output request and return the host's envelope.

  `schema` is the derived strict-mode JSON schema
  (`__allm_schema__(:json_schema)`); `schema_name` is the name the provider
  records the response format under.
  """
  @callback generate_structured(
              prompt :: prompt(),
              schema :: map(),
              schema_name :: String.t(),
              engine :: engine()
            ) :: result()

  @doc """
  `resolve_engine/1` with the calling step's context — optional.

  Preferred over `resolve_engine/1` when exported. Read run options with
  `ALLM.Pipeline.Context.get_opt/3`, e.g. a per-run engine override. The
  `/1` form stays mandatory; in an adapter exporting this one it is never
  called by the package, and should raise.
  """
  @callback resolve_engine(name :: atom(), context :: Context.t()) :: engine()

  @doc """
  `generate_structured/4` with the calling step's context — optional.

  Preferred over `generate_structured/4` when exported — the place to
  attribute a call to an account or meter its usage. The `/4` form stays
  mandatory; in an adapter exporting this one it is never called by the
  package, and should raise.
  """
  @callback generate_structured(
              prompt :: prompt(),
              schema :: map(),
              schema_name :: String.t(),
              engine :: engine(),
              context :: Context.t()
            ) :: result()

  @optional_callbacks resolve_engine: 2, generate_structured: 5

  @doc """
  The host's LLM adapter.

  Resolved at RUNTIME, like every config read in this package. Unlike the three
  adapter seams there is **no package default** — see the moduledoc — so this
  raises when the host declared no `llm:` rather than returning `nil` and
  failing inside a generated `call_llm/2` with a `BadFunctionError` that names
  neither this key nor this package.
  """
  @spec impl() :: module()
  def impl do
    :allm_pipeline
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:impl)
    |> case do
      # `not is_boolean/1` as well as `not is_nil/1`: `is_atom(true)` is `true`,
      # so `impl: true` would otherwise resolve as a "module" and surface as an
      # `UndefinedFunctionError` on `true.resolve_engine/1` naming neither this
      # key nor this package. `Registry.fetch_module!/3` already excludes
      # booleans, so a DECLARED `llm:` was protected; this closes the direct
      # `config/` override. (Code review 3.2 F6, 2026-08-19.)
      impl when is_atom(impl) and not is_nil(impl) and not is_boolean(impl) ->
        impl

      nil ->
        raise """
        ALLM.Pipeline has no LLM adapter configured, but a step tried to call one.

        Declare it on the host's registry — the key is optional precisely so a
        host with no LLM steps need not name one:

            defmodule MyApp.Pipelines do
              use ALLM.Pipeline.Registry,
                repo: …, store: …, artifacts: …, lock: …,
                llm: MyApp.Pipelines.LLM
            end

        Failing that, set it directly in config/config.exs:

            config :allm_pipeline, ALLM.Pipeline.LLM, impl: MyApp.Pipelines.LLM

        The adapter must implement the ALLM.Pipeline.LLM behaviour.
        """

      other ->
        raise """
        ALLM.Pipeline's configured LLM adapter must be a module, got: #{inspect(other)}

        Fix on the host's ALLM.Pipeline.Registry declaration, or in
        config/config.exs:

            config :allm_pipeline, ALLM.Pipeline.LLM, impl: MyApp.Pipelines.LLM
        """
    end
  end

  # The dispatch helpers below are the ONE place the package chooses a
  # callback arity, so every step kind that calls the seam goes through one
  # choice.
  #
  # `Code.ensure_loaded/1` comes first because `impl/0` returns a bare atom and
  # never loads it: `function_exported?/3` answers `false` for an unloaded
  # module, which would silently pick the context-free arity on the first call
  # of a lazily loaded (interactive-mode) host. On a load failure the legacy
  # branch runs and raises `UndefinedFunctionError` naming the adapter.

  @doc false
  # Resolve an engine, preferring the adapter's `resolve_engine/2`.
  @spec __resolve_engine__(module(), atom(), Context.t()) :: engine()
  def __resolve_engine__(impl, name, %Context{} = context) do
    if exports?(impl, :resolve_engine, 2),
      do: impl.resolve_engine(name, context),
      else: impl.resolve_engine(name)
  end

  @doc false
  # Dispatch a structured call, preferring the adapter's `generate_structured/5`.
  @spec __generate_structured__(module(), prompt(), map(), String.t(), engine(), Context.t()) ::
          result()
  def __generate_structured__(impl, prompt, schema, schema_name, engine, %Context{} = context) do
    if exports?(impl, :generate_structured, 5),
      do: impl.generate_structured(prompt, schema, schema_name, engine, context),
      else: impl.generate_structured(prompt, schema, schema_name, engine)
  end

  @doc false
  # A step's context as the seam receives it: a bare map (the tolerated
  # `execute(%{}, input)` idiom) or `nil` becomes an empty detached context —
  # such a caller has no run options to lose.
  @spec __context__(Context.t() | map() | nil) :: Context.t()
  def __context__(%Context{} = context), do: context

  def __context__(context) when (is_map(context) and not is_struct(context)) or is_nil(context),
    do: Context.detached()

  @spec exports?(module(), atom(), arity()) :: boolean()
  defp exports?(impl, fun, arity) do
    Code.ensure_loaded?(impl) and function_exported?(impl, fun, arity)
  end
end
