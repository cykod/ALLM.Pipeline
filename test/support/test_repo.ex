defmodule ALLM.Pipeline.TestRepo do
  @moduledoc """
  The standalone test harness's Ecto repo.

  The package owns no production repo — a host supplies its own through
  `use ALLM.Pipeline.Registry` — so this module exists only under
  `elixirc_paths(:test)` and is started by `test/test_helper.exs` (the package
  has no supervision tree; nothing else would start it).

  Deliberately generates no `repo/0`: `behaviours_test.exs` pins the set of
  modules exposing one to exactly `[ALLM.Pipeline.Config]`, and this module is
  enumerated by that scan (`elixirc_paths(:test)` modules DO appear in
  `Application.spec(:allm_pipeline, :modules)`).
  """

  use Ecto.Repo, otp_app: :allm_pipeline, adapter: Ecto.Adapters.Postgres
end
