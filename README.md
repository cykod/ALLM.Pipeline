# ALLM.Pipeline

A step-based LLM pipeline framework for Elixir: typed steps with persistent
step logs, artifact lineage (DynamoDB/S3-tiered), run lifecycle ownership, and
a declarative pipeline DSL (`use ALLM.Pipeline`).

Extracted from a production Elixir umbrella (Phases 1–8 of the ALLM pipeline
extraction plan), which remains the production consumer — it consumes this
repo as a path dependency. Publishable to Hex as `allm_pipeline` via
`scripts/release.exs` (see "Releasing to Hex").

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

### Service stack (`docker-compose.yml`)

```bash
docker compose up -d                       # DynamoDB Local :4028 + MinIO :4026 (+ bucket)
docker compose --profile postgres up -d    # …plus Postgres :5432 if the host has none
```

Same images and ports as the host umbrella's stack — run one or the other;
if the umbrella's is already up, this suite just uses it.

### Devcontainer

`.devcontainer/` gives the same toolchain in a container (erlang/elixir via
asdf at the `.tool-versions` pins, Claude Code, `docker-outside-of-docker`).
The service stack runs on the **host** daemon (`docker compose up -d` from
inside the container publishes on the host) and is reached back through
`host.docker.internal` — `containerEnv` presets `DATABASE_HOST`,
`DYNAMODB_ENDPOINT` and `MEDIA_ENDPOINT` accordingly, with
`DATABASE_USER=postgres` matching the compose `postgres` profile. Unlike the
umbrella's devcontainer, this repo is the workspace (read-write), so
`mix test` and `mix precommit` run inside it.

## Gates

```bash
mix precommit   # compile --warnings-as-errors, format, test --warnings-as-errors
mix dialyzer    # separate manual step, matching the host convention
mix docs        # hexdocs preview in doc/
```

## Releasing to Hex

Same two-phase pattern as [`allm`](https://github.com/cykod/ALLM)'s
`scripts/release.exs`. The script never publishes or pushes itself.

```bash
# 0. Write the release notes first — the script requires a `## … vX.Y.Z` heading.
/changelog                                   # (Claude Code skill) or edit CHANGELOG.md by hand

# Phase A — every gate, then bump mix.exs:@version (no commit)
mix run scripts/release.exs patch            # or minor | major | 0.2.0-rc.1
mix run scripts/release.exs patch --dry-run  # gates only, no mutations

# Publish by hand so Hex's prompts / OAuth device flow get a real terminal
mix hex.publish

# Phase B — commit mix.exs + CHANGELOG.md, annotated tag vX.Y.Z (no push)
mix run scripts/release.exs --finalize
git push origin main vX.Y.Z
```

Gates run by Phase A: `deps.get`, `compile --warnings-as-errors`,
`format --check-formatted`, `test --warnings-as-errors`, `dialyzer`
(`--skip-dialyzer` to skip), `hex.build`. It warns — does not fail — when the
test run excluded the `:dynamo` tags (stack down) or when
`priv/test_repo/migrations/` changed since the last tag (re-run the host
schema-parity check first). Hex auth is `~/.hex/hex.config` per maintainer
(`mix hex.user auth` on a browser-capable machine; in the devcontainer copy
the file in or set `HEX_API_KEY`). Hotfix runbook and co-maintainer
onboarding are in the script's header.

Publishing does not change the host umbrella, which consumes this repo as a
path dep until it opts into `{:allm_pipeline, "~> X.Y"}`.

## Host consumption

A host wires the framework at runtime through `use ALLM.Pipeline.Registry` —
the repo, the seam adapters, and the table DDL are the host's to supply. **New
consumers: start with the [host-wiring guide](guides/host_wiring.md)**, which
walks through the registry declaration, the optional `llm:` seam, adopting the
production DDL, provisioning the artifact backends, and the test-suite pattern.

### The path-dep umbrella

The first consumer, an internal umbrella, consumes this repo as
`{:allm_pipeline, path: ...}` — sibling checkout at `~/Projects/ALLM.Pipeline`
on the host, readonly bind mount at `/workspaces/ALLM.Pipeline` in its
devcontainer (the mount appears only after a container rebuild — see the
umbrella's `CLAUDE.md` on devcontainer declarations), and a vendored copy
staged by its `scripts/deploy.sh` for production Docker builds. Inside that
devcontainer this suite is **not runnable** (readonly mount — `_build` can't be
written); run it on the host.
