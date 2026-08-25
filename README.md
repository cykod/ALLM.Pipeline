# ALLM.Pipeline

A step-based LLM pipeline framework for Elixir: typed steps with persistent
step logs, artifact lineage (DynamoDB/S3-tiered), run lifecycle ownership, and
a declarative pipeline DSL (`use ALLM.Pipeline`).

Extracted from the [Amesbury City project](https://www.amesbury.city)'s
umbrella (Phases 1–8 of the ALLM pipeline extraction plan), which remains the
production consumer — it consumes this repo as a path dependency. Not yet
published to hex; the `package()` metadata in `mix.exs` is publish-readiness
only.

## What's here

- `ALLM.Pipeline.Step` — the step behaviour: typed Input/Output structs
  (`use ALLM.Pipeline.Schema`), executed with lineage via
  `ALLM.Pipeline.Executor.run_step/5`.
- `ALLM.Pipeline.StepLog` / `PipelineRun` / `PipelineMetric` — persistent
  step logs and run records (Ecto schemas; the **host** owns the repo and the
  migrations — table names are contract).
- `ALLM.Pipeline.ArtifactStore` — artifact bodies, tiered across DynamoDB
  (small) and S3 (large).
- `use ALLM.Pipeline` — the pipeline DSL: stages, fan-out, skips, lineage,
  metrics, run ownership. See `ALLM.Pipeline`'s moduledoc.
- `use ALLM.Pipeline.LLMStep` — generated LLM call path (strict-mode JSON
  schema derived from the Output declaration) on top of
  [`allm`](https://hex.pm/packages/allm).
- `use ALLM.Pipeline.Registry` — how a host wires its repo and adapters in at
  boot. The package resolves host collaborators at runtime; nothing in `lib/`
  may name a host module.

Read `CLAUDE.md` before working in this repo.

## Test setup

The suite is self-contained: it brings its own `ALLM.Pipeline.TestRepo`, a
test-only migration (`priv/test_repo/migrations/`), and a test registry
(`test/support/test_registry.ex`). Requirements:

- Postgres on `localhost:5432` (override with `DATABASE_HOST` /
  `DATABASE_USER` / `DATABASE_PASSWORD`). The `test` alias creates and
  migrates `allm_pipeline_test` itself.
- **Optional:** DynamoDB Local on `localhost:4028` (`DYNAMODB_ENDPOINT`) and
  MinIO on `localhost:4026` (`MEDIA_ENDPOINT`). When either is down the
  affected tests are excluded with an operator message, not failed — the
  two-direction check is:

```bash
mix test                                          # stack up: no "Excluding tags" line
DYNAMODB_ENDPOINT=http://127.0.0.1:9 mix test     # stack down: exclusions fire, still exit 0
```

Toolchain is pinned by `.tool-versions` (`erlang 27.1.2` /
`elixir 1.17.3-otp-27`, via asdf).

## Gates

```bash
mix precommit   # compile --warnings-as-errors, format, test --warnings-as-errors
mix dialyzer    # separate manual step, matching the host convention
```

## Host consumption (the Amesbury umbrella)

The umbrella consumes this repo as `{:allm_pipeline, path: ...}` — sibling
checkout at `~/Projects/ALLM.Pipeline` on the host, readonly bind mount at
`/workspaces/ALLM.Pipeline` in its devcontainer (the mount appears only after
a container rebuild — see the umbrella's `CLAUDE.md` on devcontainer
declarations), and a vendored copy staged by its `scripts/deploy.sh` for
production Docker builds. Inside that devcontainer this suite is **not
runnable** (readonly mount — `_build` can't be written); run it on the host.

The config namespace is `:amesbury_scraper` — a deliberate non-goal of the
extraction (renaming it is deferred until a second consumer makes the name a
real API; see `config/test.exs`).
