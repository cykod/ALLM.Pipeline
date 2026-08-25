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
          llm: MyApp.Pipelines.LLM,
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
  | `llm:` (optional) | `ALLM.Pipeline.LLM` → `impl:` | `ALLM.Pipeline.LLM.impl/0` |
  | `alert_on_empty:` | `:alert_on_empty` | `ALLM.Pipeline.Config.alert_on_empty/0` |
  | `lock_keys:` | `:lock_keys` | `ALLM.Pipeline.Config.lock_keys/0` |

  The `pipelines:` declaration is the one collection this table does NOT cover:
  it is **not** installed into the application environment — it is read directly
  through `__registry__(:pipelines)` by host code (`AmesburyScraper.Runner`) and
  by the `mix allm_pipeline.names` codegen task. See "The `pipelines:`
  declaration" below.

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

  ## The `pipelines:` declaration

  `pipelines:` is the host's per-pipeline metadata table — one entry per
  cron-dispatchable pipeline, each a map of `name` / `entry` / `browser` /
  `run_names` / `schedules`. It is the single source of truth the extraction
  plan's §3.8a/§3.8b codegen is built on: `AmesburyScraper.Runner` derives its
  dispatch table and name lists from it, and `mix allm_pipeline.names` emits it
  as JSON for the shell/SST/stage-scraper consumers.

  Unlike the wiring keys above, `pipelines:` is **not** installed into the
  application environment — `install/0` ignores it — because it is host domain
  data read on demand, not framework wiring resolved at runtime. It is read
  through `__registry__(:pipelines)` (an empty list when undeclared).

  The `entry:` MFAs name **host** modules (`{CommitteePipeline, :run}`), so they
  are stored as opaque data: package code never references them, only the host's
  `Runner` does. That keeps the leaf boundary intact — the package task reads
  `name`/`browser` only, never `entry`.

  ## The `artifacts:` tuple form

  `artifacts:` is the one seam that also accepts an `{module, keyword}` tuple:

      artifacts: {ALLM.Pipeline.Artifacts.Tiered,
                  small: ALLM.Pipeline.Artifacts.Dynamo,
                  large: ALLM.Pipeline.Artifacts.S3}

  The module selects the adapter (installed under `:impl`, exactly as the
  bare-module form is); the keyword carries that adapter's own wiring — a tiered
  adapter's `small:` / `large:` / `threshold:`. Those opts install under the
  **adapter's own config key** (`ALLM.Pipeline.Artifacts.Tiered` here), where
  every adapter already reads its runtime values (`Artifacts.Filesystem`'s
  `:root`, `Artifacts.S3`'s `:bucket`, `Artifacts.Dynamo`'s `:dynamo`) — NOT
  beside `:impl` on the `ALLM.Pipeline.Artifacts` seam key, which selects the
  adapter and carries nothing else. Written with `put_new` semantics like the
  seam keys, so a config-file override of the adapter's own key wins per
  environment. `store:` / `lock:` / `llm:` / `repo:` keep the strict module-only
  contract — a tuple there raises "must be a module" (pinned by
  `registry_test.exs`). `small:` / `large:` are module wiring (compile-time
  appropriate); a `threshold:` is a policy constant, not an env-specific VALUE
  like a table name — the adapter defaults it to the DynamoDB item capacity when
  omitted, so the declaration usually names only `small:` / `large:`.

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

  ## Precedence: a config file outranks the declaration for the seams

  Config files are applied before `Application.start/2`, so `install/0` is the
  LAST writer of every key in the table above. That would silently overwrite an
  env-specific adapter override, and two of this package's moduledocs document
  exactly such an override as the supported route (`Artifacts.Filesystem`'s
  "run a fresh clone with zero cloud infrastructure", `Lock`'s "restore the
  advisory lock"). So the seam keys are written with **`put_new`**
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
  `Store`, `Artifacts`, `Lock`, `LLM`, `LLMCallLog` and `Artifacts.Dynamo`. Renaming
  the namespace is a separate change with its own deployment sequencing
  (extraction plan §5.3); doing it here alone would fork the very keys this
  module exists to feed.
  """

  # The application under which the framework reads all of its configuration.
  # See "`:amesbury_scraper` is the config namespace in Phase 1" above.
  @otp_app :amesbury_scraper

  @module_keys [:repo, :store, :artifacts, :lock]

  # `llm:` is the one wiring key a host may legitimately omit: an LLM engine is
  # needed only by a host that runs `ALLM.Pipeline.LLMStep` steps, and the
  # package is meant to be extractable. Omitting it leaves
  # `ALLM.Pipeline.LLM.impl/0` raising, which is the safe direction — there is
  # no package adapter to fall back to and a silent no-op default would let a
  # step report success having called no model.
  @optional_module_keys [:llm]
  @all_keys @module_keys ++ @optional_module_keys ++ [:alert_on_empty, :lock_keys, :pipelines]

  # Every key whose value is installed under a behaviour module's `impl:`.
  @seam_keys [
    store: ALLM.Pipeline.Store,
    artifacts: ALLM.Pipeline.Artifacts,
    lock: ALLM.Pipeline.Lock,
    llm: ALLM.Pipeline.LLM
  ]

  # MEMBERSHIP GUARD, at compile time, because this is a third hand-mirrored key
  # list beside `@module_keys` and `@optional_module_keys` and the drift is
  # SILENT in the dangerous direction: a new mandatory seam added to
  # `@module_keys` alone validates clean in `__validate__!/2` and then installs
  # NOTHING in `__install__/1`, leaving the seam's `impl/0` raising at the first
  # call — the same "declares clean, stays unwired" failure mode
  # `optional_module!/3` relies on deliberately for `:llm`. `:repo` is the one
  # exclusion: it is installed under a bare `:repo` key, not under a behaviour
  # module's `impl:`, because `ALLM.Pipeline.Config.repo/0` reads it directly.
  @expected_seam_keys (@module_keys -- [:repo]) ++ @optional_module_keys

  if Enum.sort(Keyword.keys(@seam_keys)) != Enum.sort(@expected_seam_keys) do
    raise CompileError,
      description:
        "ALLM.Pipeline.Registry: `@seam_keys` is out of sync with the wiring keys. " <>
          "Expected #{inspect(Enum.sort(@expected_seam_keys))}, " <>
          "got #{inspect(Enum.sort(Keyword.keys(@seam_keys)))}. Every wiring key except " <>
          "`:repo` is installed under its behaviour module's `impl:`; a key missing from " <>
          "`@seam_keys` validates at compile time and then installs nothing."
  end

  @typedoc "One SST cron schedule entry attached to a pipeline."
  @type schedule_entry :: %{
          id: String.t(),
          cron: String.t(),
          description: String.t()
        }

  @typedoc """
  One per-pipeline metadata entry. `browser` and `schedules` are normalized to
  their defaults (`false` / `[]`) when a declaration omits them.
  """
  @type pipeline_entry :: %{
          name: atom(),
          entry: {module(), atom()},
          browser: boolean(),
          run_names: [String.t()],
          schedules: [schedule_entry()]
        }

  @typedoc """
  A validated registry declaration: the four mandatory wiring modules, the
  optional `llm:` one (`nil` when undeclared), the two domain collections
  (`lock_keys` normalized as a map), and the per-pipeline metadata list
  (`[]` when undeclared).

  `artifacts_opts` is the keyword list an `artifacts: {module, keyword}`
  declaration carries (`[]` for the bare-module form) — a tiered adapter's
  `small:` / `large:` / `threshold:` wiring. See "The `artifacts:` tuple form"
  in the moduledoc.
  """
  @type declaration :: %{
          repo: module(),
          store: module(),
          artifacts: module(),
          artifacts_opts: keyword(),
          lock: module(),
          llm: module() | nil,
          alert_on_empty: [String.t()],
          lock_keys: %{atom() => atom()},
          pipelines: [pipeline_entry()]
        }

  @doc """
  Declare a host's framework wiring and domain collections.

  Options — `:repo`, `:store`, `:artifacts` and `:lock` are required modules;
  `:llm` (an `ALLM.Pipeline.LLM` adapter) is an optional module;
  `:alert_on_empty` (a list of `PipelineRun.name` **strings**) and `:lock_keys`
  (a keyword list of pipeline atom → canonical atom) default to empty.

  Note `:alert_on_empty` keys on run-name strings rather than cron atoms: the
  two namespaces do not line up (one pipeline module emits several run names by
  mode — extraction plan §3.8a), while `:lock_keys` keys on the cron atom
  `ALLM.Pipeline.Lock.with_lock/2` is called with.

  `:pipelines` (optional, default `[]`) is the per-pipeline metadata list — see
  "The `pipelines:` declaration" in the moduledoc. Each entry is a map declaring
  at least `name:` (a unique cron atom), `entry:` (a `{module, function}` tuple)
  and `run_names:` (a list of `PipelineRun.name` strings); `browser:` (default
  `false`) and `schedules:` (default `[]`) are optional. It is read through
  `__registry__(:pipelines)` and is not installed into the application
  environment.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @allm_pipeline_registry ALLM.Pipeline.Registry.__validate__!(__MODULE__, opts)

      @doc false
      @spec __allm_pipeline_registry__?() :: true
      def __allm_pipeline_registry__?, do: true

      @doc """
      Install this registry's declarations into the application environment.

      Called from the host's `Application.start/2`. Idempotent.
      """
      @spec install() :: :ok
      def install, do: ALLM.Pipeline.Registry.__install__(@allm_pipeline_registry)

      @doc false
      @spec __registry__(atom()) :: term()
      def __registry__(key), do: Map.fetch!(@allm_pipeline_registry, key)

      @doc """
      The validated per-pipeline metadata list (the `pipelines:` declaration).

      A precisely-typed accessor — unlike `__registry__(:pipelines)`, whose
      generic `:: term()` spec would widen every caller's inferred return and
      trip `invalid_contract` on `AmesburyScraper.Runner`'s registry-derived
      `pipeline_names/0` / `browser_pipelines/0`. Host code that reads the
      metadata for its type (`Runner`) calls this; a test that only needs the
      value can still read `__registry__(:pipelines)`.
      """
      @spec pipelines() :: [ALLM.Pipeline.Registry.pipeline_entry()]
      def pipelines, do: ALLM.Pipeline.Registry.pipelines(@allm_pipeline_registry)
    end
  end

  @doc false
  # Parameter order is `(module, opts)`, matching `LLMStep.__validate__!/2`,
  # `Schema.__validate_field__!/3` and `Schema`'s own `validate_use!/2` — the
  # package's shape for a compile-time validator is "the module being validated
  # first". Flipped here 2026-08-19 (code review 3.2 F6): two same-named
  # `__validate__!/2` functions in one package with opposite signatures is a
  # footgun for the next porter, and this one was the outlier 1-of-4.
  @spec __validate__!(module(), keyword()) :: declaration()
  def __validate__!(module, opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: `use ALLM.Pipeline.Registry` takes a keyword list, " <>
              "got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @all_keys do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_message(module, unknown)
    end

    # `:artifacts` is validated by `fetch_artifacts!/2`, not the strict
    # module-only `fetch_module!/3` the other three go through: it is the one
    # seam that accepts an `{module, keyword}` form so a tiered adapter can carry
    # `small:` / `large:` / `threshold:`. `store:` / `lock:` / `repo:` keep the
    # strict "must be a module" contract (pinned by `registry_test.exs`).
    modules =
      @module_keys
      |> Enum.reject(&(&1 == :artifacts))
      |> Map.new(&{&1, fetch_module!(opts, &1, module)})

    optional = Map.new(@optional_module_keys, &{&1, optional_module!(opts, &1, module)})
    {artifacts_module, artifacts_opts} = fetch_artifacts!(opts, module)

    modules
    |> Map.merge(optional)
    |> Map.merge(%{
      artifacts: artifacts_module,
      artifacts_opts: artifacts_opts,
      alert_on_empty: validate_alert_on_empty!(opts, module),
      lock_keys: validate_lock_keys!(opts, module),
      pipelines: validate_pipelines!(opts, module)
    })
  end

  @doc false
  # Exposed so `registry_test.exs` derives its seam loop from THIS declaration
  # instead of carrying a fourth hand-written copy of the set beside
  # `@module_keys`, `@optional_module_keys` and `@seam_keys`.
  @spec __seam_keys__() :: keyword(module())
  def __seam_keys__, do: @seam_keys

  @doc false
  # The typing anchor behind the generated `pipelines/0` accessor: pattern-matches
  # a validated `declaration()` so the return is provably `[pipeline_entry()]`
  # rather than the `term()` a generic `__registry__/1` read would surface. See
  # `__using__`'s `pipelines/0` for why the precise type matters to `Runner`.
  @spec pipelines(declaration()) :: [pipeline_entry()]
  def pipelines(%{pipelines: pipelines}), do: pipelines

  @doc false
  @spec __install__(declaration()) :: :ok
  def __install__(declaration) do
    Application.put_env(@otp_app, :repo, declaration.repo)
    Application.put_env(@otp_app, :alert_on_empty, declaration.alert_on_empty)
    Application.put_env(@otp_app, :lock_keys, declaration.lock_keys)

    # The `impl =` generator doubles as the filter: an undeclared optional key
    # is `nil`, and installing nothing is what leaves `ALLM.Pipeline.LLM.impl/0`
    # raising rather than resolving to something the host never named.
    for {key, behaviour} <- @seam_keys, impl = Map.fetch!(declaration, key) do
      existing = Application.get_env(@otp_app, behaviour, [])

      # `put_new`, NOT `put` — see "Precedence" in the moduledoc. A config file
      # is applied before `Application.start/2`, so `put` here would silently
      # overwrite an env-specific `impl:` override at boot and make the adapter
      # escape hatch that `Artifacts.Filesystem` and `Lock.Advisory` both
      # document inert. The declaration is the DEFAULT; config wins.
      Application.put_env(@otp_app, behaviour, Keyword.put_new(existing, :impl, impl))
    end

    install_artifacts_opts(declaration)

    :ok
  end

  # An `artifacts: {module, keyword}` declaration carries the adapter's own
  # wiring (a tiered adapter's `small:` / `large:` / `threshold:`). It installs
  # under the ADAPTER's own config key — exactly where every adapter already
  # reads its runtime values (`Artifacts.Filesystem`'s `:root`, `Artifacts.S3`'s
  # `:bucket`, `Artifacts.Dynamo`'s `:dynamo`) — NOT beside `:impl` on the
  # `ALLM.Pipeline.Artifacts` seam key, which selects the adapter and carries
  # nothing else. `put_new` at the whole-key level, matching the seam asymmetry
  # above: a config-file `config :amesbury_scraper, <Adapter>, …` override wins,
  # per environment. The bare-module form carries `[]` and installs nothing.
  #
  # FOOT-GUN (intentional, tested by `registry_test.exs` "a config-file value for
  # the adapter key outranks the installed opts"): this is whole-key, NOT per-key.
  # If a config file sets ANY key under the adapter (e.g. only `small:`), the
  # declaration's `large:` / `threshold:` are NOT merged in — the config file
  # replaces the opts wholesale, and a partial override then crashes at
  # `Tiered.tiers/0`'s `Keyword.fetch!(config, :large)` on the first large-tier
  # put. A config-file override of an adapter's own key must name EVERY key it
  # relies on. Deliberately not changed to a per-key merge: that would invert the
  # documented `put_new` contract (moduledoc "The `artifacts:` tuple form") and
  # the enshrining test.
  @spec install_artifacts_opts(declaration()) :: :ok
  defp install_artifacts_opts(%{artifacts_opts: []}), do: :ok

  defp install_artifacts_opts(%{artifacts: adapter, artifacts_opts: opts}) do
    if is_nil(Application.get_env(@otp_app, adapter)) do
      Application.put_env(@otp_app, adapter, opts)
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
                "unreadable from this declaration. #{inspect(@optional_module_keys)} is the " <>
                "one wiring key a host may omit: the package ships no default for it, so " <>
                "omitting it raises at the call site rather than degrading."
    end
  end

  # `:artifacts` is the ONE seam that accepts a `{module, keyword}` tuple, so a
  # tiered adapter can carry its `small:` / `large:` / `threshold:` wiring in the
  # declaration (architecture §3.6/§3.3). The bare-module and every rejection
  # path reuse `fetch_module!/3`, so `artifacts: "string"` still raises "must be
  # a module" and an omitted `artifacts:` still raises "requires" — the tuple is
  # purely additive. `store:` / `lock:` / `llm:` / `repo:` never reach here and
  # keep the strict module-only contract. Returns `{module, opts}`; opts is `[]`
  # for the bare form.
  @spec fetch_artifacts!(keyword(), module()) :: {module(), keyword()}
  defp fetch_artifacts!(opts, module) do
    case Keyword.fetch(opts, :artifacts) do
      {:ok, {adapter, adapter_opts}} ->
        unless is_atom(adapter) and not is_nil(adapter) and not is_boolean(adapter) and
                 Keyword.keyword?(adapter_opts) do
          raise ArgumentError,
                "#{inspect(module)}: `artifacts:` as a tuple must be {module, keyword}, " <>
                  "got: #{inspect({adapter, adapter_opts})}"
        end

        {adapter, adapter_opts}

      _ ->
        # A bare module, a non-module, or an omitted key — all handled by the
        # strict path (returns the module, or raises "must be a module" /
        # "requires"). `artifacts:` is the only tuple-accepting seam.
        {fetch_module!(opts, :artifacts, module), []}
    end
  end

  # An UNDECLARED optional key is `nil` and installs nothing, so the seam's
  # `impl/0` keeps whatever behaviour it has when unwired. A DECLARED one is
  # validated exactly as a mandatory key is — the failure mode a lax check
  # buys is a boot-time write of a non-module that surfaces far away.
  @spec optional_module!(keyword(), atom(), module()) :: module() | nil
  defp optional_module!(opts, key, module) do
    case Keyword.fetch(opts, key) do
      :error -> nil
      {:ok, nil} -> nil
      {:ok, _value} -> fetch_module!(opts, key, module)
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

  # Each entry is validated to the full shape its `@type pipeline_entry`
  # declares — `name` an atom, `entry` a `{module, function}` MFA, `run_names` a
  # list of strings, `browser` a boolean, and each `schedules` element a map of
  # string `id`/`cron`/`description` — then normalized so `browser`/`schedules`
  # are always present. Downstream readers (`Runner`, the `names` task, 6.4's SST
  # codegen) can then read those fields without a per-field default or shape
  # check. `name` and schedule `id` uniqueness are whole-list invariants and
  # checked across the normalized set.
  @spec validate_pipelines!(keyword(), module()) :: [pipeline_entry()]
  defp validate_pipelines!(opts, module) do
    pipelines = Keyword.get(opts, :pipelines, [])

    unless is_list(pipelines) do
      raise ArgumentError,
            "#{inspect(module)}: `pipelines:` must be a list of maps, got: #{inspect(pipelines)}"
    end

    normalized = Enum.map(pipelines, &normalize_pipeline_entry!(&1, module))
    assert_unique_pipeline_names!(normalized, module)
    assert_unique_schedule_ids!(normalized, module)
    normalized
  end

  @spec normalize_pipeline_entry!(term(), module()) :: pipeline_entry()
  defp normalize_pipeline_entry!(entry, module) when is_map(entry) do
    for key <- [:name, :entry, :run_names] do
      unless Map.has_key?(entry, key) do
        raise ArgumentError,
              "#{inspect(module)}: each `pipelines:` entry must declare `#{key}:`, " <>
                "missing in #{inspect(entry)}"
      end
    end

    unless is_atom(entry.name) and not is_nil(entry.name) do
      raise ArgumentError,
            "#{inspect(module)}: `name:` in a `pipelines:` entry must be an atom, " <>
              "got: #{inspect(entry.name)}"
    end

    # Constrain the name's character content at the single source of truth so
    # EVERY downstream emitter inherits it: the name is spliced verbatim into
    # shell tokens (`scraper-entrypoint.sh` case/die) and TypeScript literals
    # (`sst/scraper.ts`), so a stray char is a codegen/injection hazard. This is
    # the compile-time gate; downstream drift/`bash -n` detection is the backstop.
    unless to_string(entry.name) =~ ~r/\A[a-z0-9_]+\z/ do
      raise ArgumentError,
            "#{inspect(module)}: `name:` in a `pipelines:` entry must match " <>
              "~r/\\A[a-z0-9_]+\\z/ (lowercase letters, digits, underscore), " <>
              "got: #{inspect(entry.name)}"
    end

    case entry.entry do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        :ok

      other ->
        raise ArgumentError,
              "#{inspect(module)}: `entry:` for `#{inspect(entry.name)}` must be a " <>
                "{module, function} tuple, got: #{inspect(other)}"
    end

    unless is_list(entry.run_names) and Enum.all?(entry.run_names, &is_binary/1) do
      raise ArgumentError,
            "#{inspect(module)}: `run_names:` for `#{inspect(entry.name)}` must be a list of " <>
              "strings, got: #{inspect(entry.run_names)}"
    end

    normalized = Map.merge(%{browser: false, schedules: []}, entry)

    unless is_boolean(normalized.browser) do
      raise ArgumentError,
            "#{inspect(module)}: `browser:` for `#{inspect(entry.name)}` must be a boolean, " <>
              "got: #{inspect(normalized.browser)}"
    end

    unless is_list(normalized.schedules) do
      raise ArgumentError,
            "#{inspect(module)}: `schedules:` for `#{inspect(entry.name)}` must be a list of " <>
              "maps, got: #{inspect(normalized.schedules)}"
    end

    schedules = Enum.map(normalized.schedules, &normalize_schedule!(&1, entry.name, module))
    Map.put(normalized, :schedules, schedules)
  end

  defp normalize_pipeline_entry!(entry, module) do
    raise ArgumentError,
          "#{inspect(module)}: each `pipelines:` entry must be a map, got: #{inspect(entry)}"
  end

  # A schedule feeds 6.4's SST codegen and has no consumer until then, so its
  # shape has no other guard — a missing `cron`/`description` would otherwise
  # drift silently into a committed `sst/scraper.ts`. Validated here to the same
  # bar as `validate_lock_keys!`/`validate_alert_on_empty!`.
  @spec normalize_schedule!(term(), atom(), module()) :: schedule_entry()
  defp normalize_schedule!(schedule, name, module) when is_map(schedule) do
    for key <- [:id, :cron, :description] do
      value = Map.get(schedule, key)

      unless is_binary(value) do
        raise ArgumentError,
              "#{inspect(module)}: each `schedules:` entry for `#{inspect(name)}` must declare a " <>
                "string `#{key}:`, got: #{inspect(value)} in #{inspect(schedule)}"
      end
    end

    schedule
  end

  defp normalize_schedule!(schedule, name, module) do
    raise ArgumentError,
          "#{inspect(module)}: each `schedules:` entry for `#{inspect(name)}` must be a map, " <>
            "got: #{inspect(schedule)}"
  end

  @spec assert_unique_pipeline_names!([pipeline_entry()], module()) :: :ok
  defp assert_unique_pipeline_names!(pipelines, module) do
    names = Enum.map(pipelines, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      dupes ->
        raise ArgumentError, "#{inspect(module)}: duplicate pipeline name(s) #{inspect(dupes)}"
    end
  end

  @spec assert_unique_schedule_ids!([pipeline_entry()], module()) :: :ok
  defp assert_unique_schedule_ids!(pipelines, module) do
    ids = Enum.flat_map(pipelines, fn entry -> Enum.map(entry.schedules, & &1.id) end)

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      dupes ->
        raise ArgumentError, "#{inspect(module)}: duplicate schedule id(s) #{inspect(dupes)}"
    end
  end
end
