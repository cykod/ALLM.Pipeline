defmodule ALLM.Pipeline.LLM do
  @moduledoc """
  The seam through which the package calls a host's LLM engine.

  The package declares no host dependency (see this repo's `CLAUDE.md` §1),
  so `ALLM.Pipeline.LLMStep` **cannot name**
  `AmesburyScraper.Transformers.LLMEngine`. The engine is reached at RUNTIME
  through `impl/0` instead, exactly as the repo is reached through
  `ALLM.Pipeline.Config.repo/0` and the persistence adapter through
  `ALLM.Pipeline.Store.impl/0`.

  ## The success shape is the host's, unchanged

  `generate_structured/4` returns the `{:ok, %{parsed: _, tokens: _}}` envelope
  the host's engine already returns, and the error term stays opaque to the
  package. This seam **relocates** the call; it does not redefine it. A host
  adapter is therefore a delegation, not a translation — see
  `AmesburyScraper.Pipelines.LLM`.

  ## Engine names are the host's vocabulary

  `resolve_engine/1` takes an atom naming a *call-site intent* (`:nano`,
  `:summarize`, …) and returns whatever engine value the host's
  `generate_structured/4` accepts. The package never inspects it and never
  validates the name — the vocabulary belongs to the host, and a step declaring
  `engine: :nano` is asserting that its host knows that name. An unknown name is
  the host adapter's error to raise.

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
  `config :amesbury_scraper, ALLM.Pipeline.LLM, impl: MyApp.Pipelines.LLM`, with
  `put_new` semantics, so an env-specific config-file override still wins (see
  `ALLM.Pipeline.Registry`, "Precedence").
  """

  @typedoc """
  A host engine handle, opaque to the package.

  Whatever `resolve_engine/1` returns is passed straight back into
  `generate_structured/4`; nothing here inspects it.
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
  The host's LLM adapter.

  Resolved at RUNTIME, like every config read in this package. Unlike the three
  adapter seams there is **no package default** — see the moduledoc — so this
  raises when the host declared no `llm:` rather than returning `nil` and
  failing inside a generated `call_llm/1` with a `BadFunctionError` that names
  neither this key nor this package.
  """
  @spec impl() :: module()
  def impl do
    :amesbury_scraper
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

            config :amesbury_scraper, ALLM.Pipeline.LLM, impl: MyApp.Pipelines.LLM

        The adapter must implement the ALLM.Pipeline.LLM behaviour.
        """

      other ->
        raise """
        ALLM.Pipeline's configured LLM adapter must be a module, got: #{inspect(other)}

        Fix on the host's ALLM.Pipeline.Registry declaration, or in
        config/config.exs:

            config :amesbury_scraper, ALLM.Pipeline.LLM, impl: MyApp.Pipelines.LLM
        """
    end
  end
end
