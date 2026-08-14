defmodule ALLM.Pipeline.Registry do
  @moduledoc """
  The host's one declaration of how it wires the framework, and of the domain
  knowledge the framework must not carry itself.

      defmodule MyApp.Pipelines do
        use ALLM.Pipeline.Registry,
          repo: MyApp.Repo,
          store: ALLM.Pipeline.Store.Ecto,
          artifacts: ALLM.Pipeline.Artifacts.Dynamo,
          lock: ALLM.Pipeline.Lock.Noop,
          alert_on_empty: ~w(some_scrape),
          lock_keys: [some_refresh: :some]
      end

  ## It FEEDS the config keys — it does not become a second way to read them

  `install/0` writes each declaration into the application environment under
  the key the framework **already** reads:

  | Declaration | Key written | Read by |
  |---|---|---|
  | `repo:` | `:repo` | `ALLM.Pipeline.Config.repo/0` |
  | `store:` | `ALLM.Pipeline.Store` → `impl:` | `ALLM.Pipeline.Store.impl/0` |
  | `artifacts:` | `ALLM.Pipeline.Artifacts` → `impl:` | `ALLM.Pipeline.Artifacts.impl/0` |
  | `lock:` | `ALLM.Pipeline.Lock` → `impl:` | `ALLM.Pipeline.Lock.impl/0` |
  | `alert_on_empty:` | `:alert_on_empty` | `ALLM.Pipeline.Config.alert_on_empty/0` |
  | `lock_keys:` | `:lock_keys` | `ALLM.Pipeline.Config.lock_keys/0` |

  So **no `repo/0` (or `store/0`, `artifacts/0`, `lock/0`) accessor is
  generated on the registry module**, deliberately. Batch 1.B decided that
  `ALLM.Pipeline.Config.repo/0` is the package's single, permanent host-repo
  handle with four consumers, two of which sit outside `Store` entirely
  (`ALLM.Pipeline.Metrics`, `ALLM.Pipeline.Lock.Advisory`) — see that module's
  moduledoc. An accessor here would be exactly the second resolution path that
  decision exists to prevent, and `registry_test.exs` plus
  `behaviours_test.exs`'s "exactly one module in the package exposes a repo
  accessor" pin its absence.

  `__registry__/1` exists for guards and tooling — it reads the DECLARATION,
  never the resolved value, and nothing in the framework calls it. It is what
  lets a host-side test assert "what the framework resolves equals what the
  registry declared" without hand-mirroring either side.

  ## Which module at compile time, which value at runtime

  The declaration is evaluated where the host `use`s it, so **module wiring is
  fixed at compile time**. Every *value* an adapter needs (table names,
  endpoints, filesystem roots) still resolves at runtime through
  `Application.get_env` inside the adapter — a `mix release` build never
  evaluates `config/runtime.exs`, so a registry compiled in Docker cannot know
  those. Do not fold a config VALUE into a registry declaration (extraction
  plan §3.3).

  ## When `install/0` runs

  The write happens at application start, not at compile time: a compile-time
  `Application.put_env` mutates only the compiling VM and is not carried into a
  release's `sys.config`, so a registry that wrote at compile time would leave
  the repo unset in production. The host calls `install/0` from its
  `Application.start/2` — `AmesburyScraper.Application` does — and
  `AmesburyScraper.Runner.run_pipeline/2` additionally calls
  `Application.ensure_all_started/1` before dispatching, which covers the
  release `bin/amesbury_web eval` cron path.

  `install/0` is idempotent and safe to call more than once.

  ## Precedence: a config file outranks the declaration for the three seams

  Config files are applied before `Application.start/2`, so `install/0` is the
  LAST writer of every key in the table above. That would silently overwrite an
  env-specific adapter override, and two of this package's moduledocs document
  exactly such an override as the supported route (`Artifacts.Filesystem`'s
  "run a fresh clone with zero cloud infrastructure", `Lock`'s "restore the
  advisory lock"). So the three seam keys are written with **`put_new`**
  semantics — the declaration supplies the DEFAULT and an explicit

      config :amesbury_scraper, ALLM.Pipeline.Artifacts,
        impl: ALLM.Pipeline.Artifacts.Filesystem

  wins, per environment, exactly as it did before a registry existed. That
  asymmetry is deliberate: a registry cannot be env-specific (it is one
  compile-time declaration), while adapter selection legitimately is.

  `:repo`, `:alert_on_empty` and `:lock_keys` are written **unconditionally**.
  They are not adapter selection, they have no env-specific use, and
  `config/config.exs` names the registry as `:repo`'s sole writer — a stale
  config line silently outranking the declaration is the failure mode there,
  not a feature. `registry_test.exs`'s "a config-file `impl:` outranks the
  declaration" describe pins both halves.

  ## `:amesbury_scraper` is the config namespace in Phase 1

  Hardcoded here exactly as it is in `ALLM.Pipeline.Config`,
  `Store`, `Artifacts`, `Lock`, `LLMCallLog` and `Artifacts.Dynamo`. Renaming
  the namespace is a separate change with its own deployment sequencing
  (extraction plan §5.3); doing it here alone would fork the very keys this
  module exists to feed.
  """

  # The application under which the framework reads all of its configuration.
  # See "`:amesbury_scraper` is the config namespace in Phase 1" above.
  @otp_app :amesbury_scraper

  @module_keys [:repo, :store, :artifacts, :lock]
  @all_keys @module_keys ++ [:alert_on_empty, :lock_keys]

  @typedoc """
  A validated registry declaration: the four wiring modules plus the two domain
  collections, normalized (`lock_keys` as a map).
  """
  @type declaration :: %{
          repo: module(),
          store: module(),
          artifacts: module(),
          lock: module(),
          alert_on_empty: [String.t()],
          lock_keys: %{atom() => atom()}
        }

  @doc """
  Declare a host's framework wiring and domain collections.

  Options — `:repo`, `:store`, `:artifacts` and `:lock` are required modules;
  `:alert_on_empty` (a list of `PipelineRun.name` **strings**) and `:lock_keys`
  (a keyword list of pipeline atom → canonical atom) default to empty.

  Note `:alert_on_empty` keys on run-name strings rather than cron atoms: the
  two namespaces do not line up (one pipeline module emits several run names by
  mode — extraction plan §3.8a), while `:lock_keys` keys on the cron atom
  `ALLM.Pipeline.Lock.with_lock/2` is called with.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @allm_pipeline_registry ALLM.Pipeline.Registry.__validate__!(opts, __MODULE__)

      @doc """
      Install this registry's declarations into the application environment.

      Called from the host's `Application.start/2`. Idempotent.
      """
      @spec install() :: :ok
      def install, do: ALLM.Pipeline.Registry.__install__(@allm_pipeline_registry)

      @doc false
      @spec __registry__(atom()) :: term()
      def __registry__(key), do: Map.fetch!(@allm_pipeline_registry, key)
    end
  end

  @doc false
  @spec __validate__!(keyword(), module()) :: declaration()
  def __validate__!(opts, module) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: `use ALLM.Pipeline.Registry` takes a keyword list, " <>
              "got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @all_keys do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_message(module, unknown)
    end

    modules = Map.new(@module_keys, &{&1, fetch_module!(opts, &1, module)})

    Map.merge(modules, %{
      alert_on_empty: validate_alert_on_empty!(opts, module),
      lock_keys: validate_lock_keys!(opts, module)
    })
  end

  @doc false
  @spec __install__(declaration()) :: :ok
  def __install__(declaration) do
    Application.put_env(@otp_app, :repo, declaration.repo)
    Application.put_env(@otp_app, :alert_on_empty, declaration.alert_on_empty)
    Application.put_env(@otp_app, :lock_keys, declaration.lock_keys)

    for {key, behaviour} <- [
          store: ALLM.Pipeline.Store,
          artifacts: ALLM.Pipeline.Artifacts,
          lock: ALLM.Pipeline.Lock
        ] do
      existing = Application.get_env(@otp_app, behaviour, [])
      impl = Map.fetch!(declaration, key)

      # `put_new`, NOT `put` — see "Precedence" in the moduledoc. A config file
      # is applied before `Application.start/2`, so `put` here would silently
      # overwrite an env-specific `impl:` override at boot and make the adapter
      # escape hatch that `Artifacts.Filesystem` and `Lock.Advisory` both
      # document inert. The declaration is the DEFAULT; config wins.
      Application.put_env(@otp_app, behaviour, Keyword.put_new(existing, :impl, impl))
    end

    :ok
  end

  @spec unknown_message(module(), [atom()]) :: String.t()
  defp unknown_message(module, unknown) do
    "#{inspect(module)}: unknown `use ALLM.Pipeline.Registry` option(s) " <>
      "#{inspect(unknown)}. Known options: #{inspect(@all_keys)}. Config VALUES " <>
      "(table names, endpoints) stay in config files and resolve at runtime — " <>
      "only module wiring belongs here."
  end

  @spec fetch_module!(keyword(), atom(), module()) :: module()
  defp fetch_module!(opts, key, module) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) and not is_boolean(value) ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "#{inspect(module)}: `#{key}:` must be a module, got: #{inspect(other)}"

      :error ->
        raise ArgumentError,
              "#{inspect(module)}: `use ALLM.Pipeline.Registry` requires `#{key}:`. " <>
                "All four of #{inspect(@module_keys)} are mandatory — an omitted one would " <>
                "silently fall back to a package default and leave the host's wiring " <>
                "unreadable from this declaration."
    end
  end

  @spec validate_alert_on_empty!(keyword(), module()) :: [String.t()]
  defp validate_alert_on_empty!(opts, module) do
    names = Keyword.get(opts, :alert_on_empty, [])

    if is_list(names) and Enum.all?(names, &is_binary/1) do
      names
    else
      raise ArgumentError,
            "#{inspect(module)}: `alert_on_empty:` must be a list of run-name STRINGS " <>
              "(it keys on `PipelineRun.name`, not on a cron atom), got: #{inspect(names)}"
    end
  end

  @spec validate_lock_keys!(keyword(), module()) :: %{atom() => atom()}
  defp validate_lock_keys!(opts, module) do
    pairs = Keyword.get(opts, :lock_keys, [])

    valid? =
      Keyword.keyword?(pairs) and
        Enum.all?(pairs, fn {name, canonical} -> is_atom(name) and is_atom(canonical) end)

    if valid? do
      Map.new(pairs)
    else
      raise ArgumentError,
            "#{inspect(module)}: `lock_keys:` must be a keyword list of " <>
              "pipeline atom => canonical atom, got: #{inspect(pairs)}"
    end
  end
end
