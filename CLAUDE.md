# ALLM.Pipeline — Agent Guide

The extracted pipeline framework: `ALLM.Pipeline.*`, 24 `lib/` modules, 15 test
files. A **leaf** umbrella app headed for hex (extraction plan Phase 8), so it is
developed in-tree with no version skew against the published copy.

> Read the umbrella `/CLAUDE.md` and `/AGENTS.md` first. What the framework *does*
> — Step, Executor, StepLog, ArtifactStore, the `:content` convention, artifact
> lineage — is documented in `apps/amesbury_scraper/CLAUDE.md` §1, from the
> consumer's side. This file is only the things that are specific to working
> **inside** this app and that the code does not make obvious.

---

## 1. The dep list's omission is the architecture

`mix.exs` deliberately declares **no** umbrella dependency — no `{:amesbury,
in_umbrella: true}`, none of the others. It looks like an oversight; it is the
whole point. Naming `Amesbury.*` or `AmesburyScraper.*` anywhere in `lib/` is a
**compile error**, not a review finding somebody has to notice. Do not "fix" it,
and do not add a dep to make a reach compile — the reach is the bug.

Host collaborators resolve at **runtime** instead, through the host's
`use ALLM.Pipeline.Registry` declaration (`Amesbury.Pipelines`), installed from
`AmesburyScraper.Application.start/2`. The config namespace is `:amesbury_scraper`
in Phase 1, hardcoded in `Config`, `Store`, `Artifacts`, `Lock`, `LLMCallLog` and
`Artifacts.Dynamo`.

**`ALLM.Pipeline.Config.repo/0` is the single, permanent host-repo handle** —
settled as option (b) in batch 1.B, not a Phase-1 shim. Do not add a second
`repo/0` anywhere in `lib/`: `test/allm/pipeline/behaviours_test.exs` asserts the
set of modules exposing one is **exactly** `[ALLM.Pipeline.Config]`, and a
generated `repo/0` on a host adapter would fail it.

## 2. `mix test` runs from the umbrella root. Only from there.

```bash
mix test apps/allm_pipeline/test     # from /workspaces/amesbury
```

`cd apps/allm_pipeline && mix test` **does not work** and the error does not
point at the cause (measured 2026-08-14):

```
error: module Dotenvy is not loaded and could not be found
  │ 2 │ import Dotenvy
  └─ /workspaces/amesbury/config/runtime.exs:2
** (CompileError) /workspaces/amesbury/config/runtime.exs: cannot compile file
```

`config_path` points at the umbrella's `config/config.exs`, which pulls in
`runtime.exs`, which imports `Dotenvy` — a dep this app does not (and should not)
declare. An earlier note attributed this to `Config.repo/0`; it is `Dotenvy`, and
it happens before any of this app's code runs.

Running from the root also starts every umbrella app, which is what makes
`Config.repo/0` resolve and the registry get installed — both of which the tests
below depend on.

## 3. DB-backed tests

The package owns Ecto schemas and no repo. A DB-backed test checks the host repo
out by handle:

```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(ALLM.Pipeline.Config.repo())
  :ok
end
```

`:manual` mode is set by **this package's own** `test/test_helper.exs`, not
borrowed from a sibling app's — a test tree that silently borrows the host's
harness is the same leak `mix.exs`'s omitted dep prevents for `lib/`. The failure
mode if that ever regresses is not a clean red: under `:auto` every query gets its
own rolled-back transaction, so `create_run/3` succeeds and `get_run/1` returns
`nil` one line later, which reads as an adapter bug. `store_test.exs` pins the
mode with a bare-`spawn` probe (Ecto resolves ownership through `$callers`, which
a `Task` would inherit and an unrelated process has not).

## 4. `:dynamo` exclusion — the measured behaviour

`test_helper.exs` takes the probe, the operator message **and** the tag list from
`ALLM.Pipeline.Artifacts.Dynamo.exclusions/0` — one implementation, shared with
the host's `test_helper.exs`. Do not hand-copy the tag list back.

Measured 2026-08-14, both directions:

| DynamoDB | Result |
|---|---|
| up | `3 doctests, 226 tests, 0 failures`, **no** `Excluding tags` line |
| down (`DYNAMODB_ENDPOINT=http://127.0.0.1:9`) | `3 doctests, 226 tests, 0 failures, 19 excluded` |

Note what this means for testing `exclusions/0` itself: ExUnit exits 0 whether it
excludes 0 or 19, so a mutant of it leaves a green suite. **The two-direction run
above is its only discriminating observable** — re-run the pair rather than
mutating it.

## 5. `test/` may not depend on host-installed application env

The compiler enforces the boundary for **names** in `lib/`. It is blind to
**runtime state**, and every leak found in Phase 1 came through the test tree:
`lock_test.exs` spent a batch asserting `Lock.impl() == Noop` while
`Amesbury.Pipelines` was installing exactly `Noop` at boot, so it observed the
host's declaration and could not have seen the framework's fallback change.

So: a package test that reads or writes `Application.get_env(:amesbury_scraper,
…)` **establishes the value it depends on and restores it**, and is `async: false`
(the application env is global to the VM). The shape, in `setup`:

```elixir
use ExUnit.Case, async: false

setup do
  previous = Application.get_env(:amesbury_scraper, Lock)
  on_exit(fn ->
    if previous,
      do: Application.put_env(:amesbury_scraper, Lock, previous),
      else: Application.delete_env(:amesbury_scraper, Lock)
  end)
  :ok
end
```

Reference implementations: `lock_test.exs`, `registry_test.exs`,
`executor_store_dispatch_test.exs`. The carve-out test when deciding whether an
assertion belongs here at all is *"does it depend on a value this tree does not
own?"* — not *"does it compile here?"*. Host-owned values live in
`apps/amesbury_scraper/test/amesbury/pipelines_declared_values_test.exs`.

## 6. `Registry.__install__/1`'s `put_new` / `put` asymmetry is deliberate

The three **seam** keys (`ALLM.Pipeline.Store` / `Artifacts` / `Lock`) are written
with `Keyword.put_new(existing, :impl, impl)`; `:repo`, `:alert_on_empty` and
`:lock_keys` are written unconditionally with `Application.put_env`. Do not
"simplify" it in either direction.

Config files are applied before `Application.start/2`, so `install/0` is the last
writer. `put_new` on the seams keeps an env-specific `config :amesbury_scraper,
ALLM.Pipeline.Artifacts, impl: …Filesystem` winning — which two moduledocs
document as the supported route — because a registry is one compile-time
declaration and cannot be env-specific, while adapter selection legitimately is.
The other three are not adapter selection, have no env-specific use, and their
failure mode is the opposite: a stale config line silently outranking the
declaration. `registry_test.exs`'s "a config-file `impl:` outranks the
declaration" describe pins both halves.
