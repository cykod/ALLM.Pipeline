# Wiring a host

`allm_pipeline` ships no repo, no supervision tree, and no LLM provider
integration — a **host** application supplies those at runtime. This guide is
the onboarding path for a new host: how to declare the wiring, adopt the table
DDL, provision the artifact backends, and set up a test suite. It **points at**
the normative moduledocs rather than duplicating them — each section names the
module whose `@moduledoc` is the source of truth, and links stay live in
hexdocs.

This guide is the **wiring** reference; once a host is wired, see
[the building-a-pipeline guide](building_a_pipeline.md) for the **application**
layer — authoring steps and composing them into a pipeline.

Throughout, `MyApp` stands for your host application.

## 1. Registry wiring

A host declares one module — its registry — that names the repo and the seam
adapters the framework resolves at runtime:

```elixir
defmodule MyApp.Pipelines do
  use ALLM.Pipeline.Registry,
    repo: MyApp.Repo,
    store: ALLM.Pipeline.Store.Ecto,
    artifacts: {ALLM.Pipeline.Artifacts.Tiered,
                small: ALLM.Pipeline.Artifacts.Dynamo,
                large: ALLM.Pipeline.Artifacts.S3},
    lock: ALLM.Pipeline.Lock.Noop,
    llm: MyApp.Pipelines.LLM
end
```

Call `install/0` from your `Application.start/2`, before anything dispatches a
pipeline:

```elixir
def start(_type, _args) do
  MyApp.Pipelines.install()
  children = [MyApp.Repo | _rest]
  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

`install/0` writes each declaration into the application environment under the
key the framework already reads — it does **not** become a second way to read
the config. The declaration-to-key mapping, the `put_new`-vs-unconditional
write asymmetry, the optional/tuple forms, and why `install/0` must run at
application start (not compile time) are all documented in
`ALLM.Pipeline.Registry`'s moduledoc. Read it before wiring; the rules there
are load-bearing (a value folded into a compile-time declaration is unset in a
`mix release`).

`install/0` is idempotent and safe to call more than once.

## 2. The optional `llm:` seam

`llm:` is the one wiring key a host may omit. A host that runs no
`ALLM.Pipeline.LLMStep` steps need not name an engine, so an undeclared `llm:`
installs nothing — and `ALLM.Pipeline.LLM.impl/0` then **raises**, by design,
naming the `llm:` registry key.

That is deliberate, not a defect: unlike `store` / `artifacts` / `lock`, there
is no package adapter to fall back to (an LLM adapter is a provider integration
with credentials, retry policy, and logging, all of which live in the host), so
"unwired" is loud rather than a silent no-op that would report success having
called no model. The full rationale, and the shape of a host adapter (a thin
delegation to the host's existing engine, returning the host's own
`{:ok, %{parsed: _, tokens: _}}` envelope unchanged), are in
`ALLM.Pipeline.LLM`'s moduledoc.

## 3. Production DDL adoption

The package ships **no** production migrations — table names are a contract and
the framework's Ecto schemas (`ALLM.Pipeline.PipelineRun`,
`ALLM.Pipeline.StepLog`, `ALLM.Pipeline.PipelineMetric`) bind to them. The host
owns the migrations.

The canonical DDL is the package's own test-harness migration, which ships in
the tarball:

```
priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs
```

To adopt it, copy that file's `change/0` into a new migration in your host's
`priv/repo/migrations/` (with your own timestamp prefix and a host module
name). It creates `pipeline_runs`, `step_logs`, and `pipeline_metrics` with the
indexes and foreign keys the schemas expect. Once created, **the host owns and
freezes these table names** — the framework never migrates them, and the
package's copy stays parity-checked against yours (see the migration's own
moduledoc for the parity rule).

## 4. Artifact infrastructure

The default artifact adapter is `ALLM.Pipeline.Artifacts.Tiered`, which routes
small artifacts to DynamoDB and large ones to S3 (declared via the
`artifacts:` tuple form in section 1). Each backend needs its infrastructure
provisioned:

- **DynamoDB.** Name the table with
  `config :allm_pipeline, :dynamo, table_name: "my_pipeline_artifacts"`
  (the coded fallback is `"allm_pipeline_artifacts"`). Create it once with
  `ALLM.Pipeline.Artifacts.Dynamo.create_table/0`, which is idempotent. The
  `:dynamo` config also carries the region/endpoint; see
  `ALLM.Pipeline.Artifacts.Dynamo`'s moduledoc.
- **S3.** Provision a bucket and name it with
  `config :allm_pipeline, ALLM.Pipeline.Artifacts.S3, bucket: "my-artifacts"`.
  See `ALLM.Pipeline.Artifacts.S3`'s moduledoc for the region/endpoint keys.
- **Tiering.** `ALLM.Pipeline.Artifacts.Tiered` routes on post-encode bytes
  against a `threshold:` that defaults to the DynamoDB item capacity, so
  `small: Dynamo` with no explicit threshold routes exactly as
  `Dynamo.fits_item?/1` does. Its moduledoc is the reference.

The `ex_aws` / `ex_aws_dynamo` / `ex_aws_s3` deps are `optional: true` on the
package — a host wiring a different artifact adapter need not carry them; each
adapter degrades gracefully when its dep is absent.

## 5. Consumer test-suite pattern

A host's test suite wires the framework the same way production does, but with
a test-only registry — a repo the sandbox owns, and adapters suited to the test
stack:

```elixir
defmodule MyApp.TestPipelines do
  use ALLM.Pipeline.Registry,
    repo: MyApp.Repo,
    store: ALLM.Pipeline.Store.Ecto,
    artifacts: {ALLM.Pipeline.Artifacts.Tiered,
                small: ALLM.Pipeline.Artifacts.Dynamo,
                large: ALLM.Pipeline.Artifacts.S3},
    lock: ALLM.Pipeline.Lock.Noop
end
```

Call its `install/0` from `test/test_helper.exs`.

A DB-backed test checks out whatever `ALLM.Pipeline.Config.repo/0` resolves to
— the repo your registry declared — through the Ecto SQL sandbox:

```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(ALLM.Pipeline.Config.repo())
  :ok
end
```

For the artifact backends, gate the tests that touch DynamoDB on the stack
being up. `ALLM.Pipeline.Artifacts.Dynamo.exclusions/0` is the **shared**
stack-down probe: it returns `{tags, message}` — the ExUnit exclusion tags and
an operator hint — from one probe, so a host suite and this package's suite use
the identical exclusion logic. That shared function IS the cross-repo drift
guard: call it from your `test/test_helper.exs` rather than hand-copying the tag
list.

```elixir
{dynamo_exclusions, dynamo_message} = ALLM.Pipeline.Artifacts.Dynamo.exclusions()
if dynamo_message, do: IO.puts(dynamo_message)

ExUnit.start(exclude: dynamo_exclusions)
```

It returns `{[], nil}` when the stack is up (nothing excluded) and
`{tags, message}` when it is down, so ExUnit exits 0 either way — a clone with
no DynamoDB skips those tests rather than failing. See
`ALLM.Pipeline.Artifacts.Dynamo`'s `exclusions/0` for why this lives in `lib/`
(two repos need the one answer).

The package's own `test/test_helper.exs` and `test/support/test_registry.ex`
are working references for this whole pattern.
