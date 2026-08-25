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
#
# Bootstrap first: the standalone suite uses its OWN table
# (`allm_pipeline_artifacts_test`, distinct from the umbrella host's so the two
# suites never share Dynamo state), and `exclusions/0`'s probe keys on the
# TABLE existing — while the `:dynamo`-tagged tests that would create it only
# run when not excluded. Without this line a fresh DynamoDB Local reads as
# "down" forever. `create_table/0` is idempotent (`:ok` when it already
# exists); when the endpoint is genuinely unreachable it returns `{:error, _}`
# and the probe below excludes as before — the Logger squelch keeps that
# expected failure from printing an alarming error before the operator message.
squelched_level = Logger.level()
Logger.configure(level: :none)

try do
  _ = ALLM.Pipeline.Artifacts.Dynamo.create_table()
after
  # `after`, not a bare next line: if `create_table/0` ever raises, the level
  # must still be restored or the whole suite runs with Logger silenced.
  Logger.configure(level: squelched_level)
end

{dynamo_exclusions, dynamo_message} = ALLM.Pipeline.Artifacts.Dynamo.exclusions()
if dynamo_message, do: IO.puts(dynamo_message)

# Same shape for the live S3 round-trip test (Phase 7.5): `:s3` / `:skip_unless_s3`
# are excluded when MinIO is unreachable, so a clone without the media stack up
# skips rather than fails.
{s3_exclusions, s3_message} = ALLM.Pipeline.Artifacts.S3.exclusions()
if s3_message, do: IO.puts(s3_message)

ExUnit.start(exclude: dynamo_exclusions ++ s3_exclusions)

# Standalone harness wiring, in the role the umbrella host's boot played:
# install the test registry (repo + store/artifacts/lock seams — what
# `Amesbury.Pipelines.install/0` does from `AmesburyScraper.Application` in the
# umbrella), then start the TestRepo. The package has no supervision tree
# (`application/0` carries no `mod:`), so nothing else starts the repo, and
# `Sandbox.mode/2` below raises "could not lookup Ecto repo … it was not
# started" without the explicit `start_link/0`.
:ok = ALLM.Pipeline.TestSupport.Registry.install()
{:ok, _} = ALLM.Pipeline.TestRepo.start_link()

# The package's DB-backed tests (`store_test.exs`) check the sandbox out
# explicitly, which requires `:manual` mode. Set it HERE: the failure mode if
# this is ever dropped is not a clean red — in `:auto` mode every query gets
# its own rolled-back transaction, so `create_run/3` succeeds and `get_run/1`
# returns `nil` one line later, which reads as an adapter bug.
#
# `Config.repo/0` is how package code names the wired repo everywhere else; it
# resolves to `ALLM.Pipeline.TestRepo` via the registry install above
# (pinned by `test_harness_test.exs`).
Ecto.Adapters.SQL.Sandbox.mode(ALLM.Pipeline.Config.repo(), :manual)
