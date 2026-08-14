# `:skip_unless_dynamo` is a real exclusion, not decoration — the same answer the
# host's `test_helper.exs` gets, from the same function, because
# `artifact_store_test.exs` moved into this tree in batch 1.D and each umbrella
# app starts ExUnit with its own option set. Without it, a developer with the
# local DynamoDB stack down sees those tests FAIL rather than skip, which is the
# fail-open shape root `CLAUDE.md` warns about.
#
# The probe, the operator message AND the tag list all come from
# `ALLM.Pipeline.Artifacts.Dynamo.exclusions/0` rather than being re-written
# here: a hand-copied tag list is the same invariant in a second shape, and it is
# the shape most likely to be waved through because it reads as data. `Dynamo` is
# package code, so this needs nothing from the host.
{dynamo_exclusions, dynamo_message} = ALLM.Pipeline.Artifacts.Dynamo.exclusions()
if dynamo_message, do: IO.puts(dynamo_message)

ExUnit.start(exclude: dynamo_exclusions)

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
