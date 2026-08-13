defmodule ALLM.Pipeline.Config do
  @moduledoc """
  Resolves the host-supplied collaborators the package cannot name directly.

  `allm_pipeline` deliberately depends on no umbrella app (see
  `apps/allm_pipeline/mix.exs`), so `Amesbury.Repo` is not on this tree's
  compile path — a literal `alias Amesbury.Repo` here is a compile error at
  `--warnings-as-errors`, which is the enforcement the omission exists to buy.
  The repo is therefore looked up at RUNTIME instead.

  ## Phase 1 shape

  Today this resolves exactly one thing: the Ecto repo. The extraction plan's
  §3.3 puts store / artifacts / lock module wiring on an `ALLM.Pipeline.Registry`
  the host `use`s, resolved at compile time; those adapters keep resolving
  *their own values* (table names, endpoints) at runtime via
  `Application.get_env`. That registry lands in Phase 1.C. Until it does, this
  module is the single seam, and `:amesbury_scraper` stays the config namespace
  — renaming the namespace is a separate change with its own deployment
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
  The Ecto repo the framework persists runs, step logs and metrics through.

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
