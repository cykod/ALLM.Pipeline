defmodule ALLM.Pipeline.Config do
  @moduledoc """
  Resolves the host-supplied collaborators the package cannot name directly.

  `allm_pipeline` deliberately depends on no umbrella app (see
  `apps/allm_pipeline/mix.exs`), so `Amesbury.Repo` is not on this tree's
  compile path — a literal `alias Amesbury.Repo` here is a compile error at
  `--warnings-as-errors`, which is the enforcement the omission exists to buy.
  The repo is therefore looked up at RUNTIME instead.

  ## This module is permanent by design — `Store` does not replace it

  _(Decided in batch 1.B, 2026-08-14. This section previously framed the module
  as temporary until the registry landed. It is not, and the two options were
  weighed explicitly — see `2026-08-10_ALLM_PIPELINE_PHASE_1.md` §5.1.)_

  The repo is a **package-level** collaborator, not an adapter-local one. Four
  modules need it and only two of them are behind `ALLM.Pipeline.Store`:

  | Consumer | Behind a behaviour? |
  |---|---|
  | `ALLM.Pipeline.PipelineRun` | yes — `Store` (run persistence) |
  | `ALLM.Pipeline.StepLog` | yes — `Store` (step persistence) |
  | `ALLM.Pipeline.Metrics` / `PipelineMetric` | no — a third schema, and a first-class framework module rather than an adapter |
  | `ALLM.Pipeline.Lock.Advisory` | no — `ALLM.Pipeline.Lock`'s whole contract is `with_lock/2`; a repo is not in it, yet the implementation needs `checkout/1` plus raw `pg_advisory_lock` SQL |

  The rejected alternative was giving `Lock.Advisory` and `Metrics` their own
  `repo:` adapter keys so this module could retire alongside `Store.Ecto`. That
  would put the same value in three config sites with nothing tying them
  together, and a drift between them is not cosmetic: an advisory lock taken on
  one pool while the pipeline writes through another is a guard that silently
  guards nothing. It would also have to invent an adapter namespace for
  `Metrics`, which is not an adapter.

  So there is exactly **one** resolution path for the repo in this package, and
  it is here. `Store.Ecto` is a consumer of it, like the other three.

  ## What the registry changes, and what it does not

  The extraction plan's §3.3 puts store / artifacts / lock module wiring on an
  `ALLM.Pipeline.Registry` the host `use`s, resolved at compile time, alongside
  a top-level `repo:` declaration. That landed in batch 1.C, and it is the
  thing that FEEDS this key — it did not become a second way to read it, and
  `repo/0` stays the package's only accessor (`ALLM.Pipeline.Registry`
  generates no `repo/0`; `behaviours_test.exs` pins that exactly one module in
  the package exposes one). Adapters keep resolving *their own values* (table
  names, endpoints, roots) at runtime via `Application.get_env`, and
  `:amesbury_scraper` stays the config namespace — renaming the namespace is a
  separate change with its own deployment sequencing (§5.3).

  ## The two domain collections

  `alert_on_empty/0` and `lock_keys/0` resolve host **domain knowledge** the
  framework used to carry as hardcoded literals (extraction plan §1.3c): the
  set of run names for which an empty scrape is an alert, and the pipelines
  that must collapse to one serialization key. Both moved onto the registry in
  batch 1.C. They read the same way everything else here does, and both default
  to empty so a host with no registry gets the neutral behaviour (nothing
  alerts on empty; every pipeline gets its own lock key) rather than a raise —
  unlike `repo/0`, which has no neutral default because there is nothing to
  persist through.

  An *absent* value is therefore neutral, but a **wrongly-shaped** one raises
  here exactly as `repo/0` does, naming the key and the package (added by the
  Phase 1 polish pass). The registry validates its own options, so this guard
  is for the direct-config route `repo/0`'s `@doc` documents as supported —
  where both keys previously failed open: a bad `alert_on_empty` degraded to a
  permanent `false` from `Metrics.expects_data?/1`, and `lock_keys` in the
  natural keyword form reached `Advisory.canonical_lock_name/1` as a
  `BadMapError` from `Map.get/3`, far from the cause.

  ## Why `Application.get_env` and not a compile-time module attribute

  A `mix release` build never evaluates `config/runtime.exs`, and
  `bin/amesbury_web eval` re-evaluates the whole file under a minimal env to run
  migrations. Anything resolved at compile time would bake in the build
  machine's view. This particular value is written by the host's registry at
  application boot and is stable thereafter, but the runtime read costs an ETS
  lookup against a database round-trip and keeps the seam honest for the
  adapters that follow.
  """

  @doc """
  The Ecto repo the framework persists runs, step logs and metrics through, and
  that `ALLM.Pipeline.Lock.Advisory` checks a connection out of.

  Declared by the host on its registry and installed at application boot:

      defmodule MyApp.Pipelines do
        use ALLM.Pipeline.Registry, repo: MyApp.Repo, store: …, artifacts: …, lock: …
      end

      # MyApp.Application.start/2
      :ok = MyApp.Pipelines.install()

  A host with no registry may still set `config :amesbury_scraper, repo:
  MyApp.Repo` directly; this reads the key either way. Amesbury declares it on
  `Amesbury.Pipelines` — batch 1.C retired the `config/config.exs` line so the
  key has one writer.

  Raises when unconfigured — or configured with something that is not a module —
  rather than returning `nil` and failing later inside Ecto with a message that
  names neither this key nor this package. Both raise branches name the key and
  the package, and `config_test.exs` pins that they do. Note the most likely
  cause of the unconfigured branch is now a host whose `Application.start/2`
  never calls `install/0`, so the message names that first.
  """
  @spec repo() :: module()
  def repo do
    case Application.get_env(:amesbury_scraper, :repo) do
      nil ->
        raise """
        ALLM.Pipeline has no repo configured.

        Most likely the host's Application.start/2 never called its registry's
        install/0 (see ALLM.Pipeline.Registry). Failing that, set it directly
        in config/config.exs:

            config :amesbury_scraper, repo: MyApp.Repo
        """

      # `not is_boolean/1`: `is_atom(true)` is `true`, so `repo: true` would
      # otherwise be returned as a "module". Same guard, same reason, as
      # `ALLM.Pipeline.LLM.impl/0` (code review 3.2 F6, 2026-08-19).
      repo when is_atom(repo) and not is_boolean(repo) ->
        repo

      other ->
        # A quoted module name (`repo: "Amesbury.Repo"`) is the likely typo here.
        # Without this clause it raised a bare `CaseClauseError`, which names
        # neither the key nor the package — the exact outcome the @doc rejects.
        raise """
        ALLM.Pipeline's configured repo must be a module, got: #{inspect(other)}

        Fix on the host's ALLM.Pipeline.Registry declaration, or in
        config/config.exs:

            config :amesbury_scraper, repo: MyApp.Repo
        """
    end
  end

  @doc """
  Run names (`PipelineRun.name` **strings**) for which `found == 0` is an
  alert rather than a quiet week — read by `ALLM.Pipeline.Metrics.expects_data?/1`.

  Declared by the host as `alert_on_empty:` on its `ALLM.Pipeline.Registry`.
  Defaults to `[]`: a host that declares nothing alerts on nothing, which is
  the safe direction (a false alarm is worse than a missed empty scrape, which
  is also the reason the one Amesbury exclusion exists — see the registry).

  A wrongly-shaped value raises here, naming the key and the package, for the
  same reason `repo/0` does: the registry validates its own `alert_on_empty:`
  option, but `config :amesbury_scraper, alert_on_empty: …` written straight
  into a config file bypasses that path, and the failure downstream is a silent
  `false` from `Metrics.expects_data?/1` — never an alert, never an error.
  """
  @spec alert_on_empty() :: [String.t()]
  def alert_on_empty do
    names = Application.get_env(:amesbury_scraper, :alert_on_empty, [])

    if is_list(names) and Enum.all?(names, &is_binary/1) do
      names
    else
      raise """
      ALLM.Pipeline's configured alert_on_empty must be a list of run-name \
      STRINGS (it keys on PipelineRun.name, not on a cron atom), got: \
      #{inspect(names)}

      Fix on the host's ALLM.Pipeline.Registry declaration, or in
      config/config.exs:

          config :amesbury_scraper, alert_on_empty: ["some_scrape"]
      """
    end
  end

  @doc """
  Pipelines that must serialize against each other, as
  `%{pipeline_name => canonical_name}` — read by
  `ALLM.Pipeline.Lock.Advisory.canonical_lock_name/1`.

  Declared by the host as `lock_keys:` on its `ALLM.Pipeline.Registry`, which
  normalizes the keyword list it accepts into the map returned here.

  A host configuring the key directly — which `repo/0`'s `@doc` documents as
  supported for a registry-less host — naturally writes the **keyword** form
  `lock_keys: [project_refresh: :project]`, the exact shape the registry takes.
  That is accepted and normalized here rather than reaching
  `Advisory.canonical_lock_name/1` as a `BadMapError` from `Map.get/3`, far
  from the cause. Anything else raises naming the key and both shapes.

  Defaults to `%{}`, i.e. every pipeline gets its own key, which is the
  behaviour of the identity mapping the module documents.
  """
  @spec lock_keys() :: %{atom() => atom()}
  def lock_keys do
    case Application.get_env(:amesbury_scraper, :lock_keys, %{}) do
      map when is_map(map) ->
        map

      pairs when is_list(pairs) ->
        if Keyword.keyword?(pairs) and
             Enum.all?(pairs, fn {name, canonical} ->
               is_atom(name) and is_atom(canonical)
             end),
           do: Map.new(pairs),
           else: raise_bad_lock_keys(pairs)

      other ->
        raise_bad_lock_keys(other)
    end
  end

  @spec raise_bad_lock_keys(term()) :: no_return()
  defp raise_bad_lock_keys(value) do
    raise """
    ALLM.Pipeline's configured lock_keys must map a pipeline atom to a \
    canonical atom — either a map or a keyword list — got: #{inspect(value)}

    Fix on the host's ALLM.Pipeline.Registry declaration, or in
    config/config.exs:

        config :amesbury_scraper, lock_keys: [some_refresh: :some]
    """
  end
end
