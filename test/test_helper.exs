ExUnit.start()

# The package's DB-backed tests (`store_test.exs`) check the sandbox out
# explicitly, which requires `:manual` mode. Set it HERE rather than relying on
# a sibling umbrella app's `test_helper.exs` having run first in the same BEAM:
# `apps/allm_pipeline` deliberately depends on no umbrella app, and a test tree
# that silently borrows the host's harness is the same leak `mix.exs`'s omitted
# dependency exists to prevent for `lib/`. The failure mode if the ordering ever
# changes is not a clean red — in `:auto` mode every query gets its own
# rolled-back transaction, so `create_run/3` succeeds and `get_run/1` returns
# `nil` one line later, which reads as an adapter bug.
#
# `Config.repo/0` is how package code names the host repo everywhere else; it
# cannot be written as `Amesbury.Repo` here for the same reason.
Ecto.Adapters.SQL.Sandbox.mode(ALLM.Pipeline.Config.repo(), :manual)
