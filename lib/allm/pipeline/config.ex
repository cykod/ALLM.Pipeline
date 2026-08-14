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
  a top-level `repo:` declaration. When that lands (batch 1.C) it becomes the
  thing that FEEDS this key — it does not become a second way to read it, and
  `repo/0` stays the package's only accessor. Adapters keep resolving *their
  own values* (table names, endpoints, roots) at runtime via
  `Application.get_env`, and `:amesbury_scraper` stays the config namespace —
  renaming the namespace is a separate change with its own deployment
  sequencing (§5.3).

  ## Why `Application.get_env` and not a compile-time module attribute

  A `mix release` build never evaluates `config/runtime.exs`, and
  `bin/amesbury_web eval` re-evaluates the whole file under a minimal env to run
  migrations. Anything resolved at compile time would bake in the build
  machine's view. This particular value comes from `config/config.exs` and is
  stable, but the runtime read costs an ETS lookup against a database round-trip
  and keeps the seam honest for the adapters that follow.
  """

  @doc """
  The Ecto repo the framework persists runs, step logs and metrics through, and
  that `ALLM.Pipeline.Lock.Advisory` checks a connection out of.

  Configured by the host:

      config :amesbury_scraper, repo: Amesbury.Repo

  Raises when unconfigured — or configured with something that is not a module —
  rather than returning `nil` and failing later inside Ecto with a message that
  names neither this key nor this package. Both raise branches name the key and
  the package, and `config_test.exs` pins that they do.
  """
  @spec repo() :: module()
  def repo do
    case Application.get_env(:amesbury_scraper, :repo) do
      nil ->
        raise """
        ALLM.Pipeline has no repo configured. Add to config/config.exs:

            config :amesbury_scraper, repo: MyApp.Repo
        """

      repo when is_atom(repo) ->
        repo

      other ->
        # A quoted module name (`repo: "Amesbury.Repo"`) is the likely typo here.
        # Without this clause it raised a bare `CaseClauseError`, which names
        # neither the key nor the package — the exact outcome the @doc rejects.
        raise """
        ALLM.Pipeline's configured repo must be a module, got: #{inspect(other)}

        Fix in config/config.exs:

            config :amesbury_scraper, repo: MyApp.Repo
        """
    end
  end
end
