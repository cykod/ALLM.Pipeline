# ALLM.Pipeline — Agent Guide

The extracted pipeline framework: `ALLM.Pipeline.*`, a **standalone repo** since
Phase 8 of the extraction plan (`steering/2026-08-25_ALLM_PIPELINE_PHASE_8.md`
in the Amesbury repo). It is hex-**ready** (`package()` metadata, MIT LICENSE)
but **not published** — its one consumer, the Amesbury umbrella
(`~/Projects/amesbury`), consumes it as a **path dep**: this sibling checkout on
the host, a readonly bind mount at `/workspaces/ALLM.Pipeline` in the Amesbury
devcontainer, and a `vendor/allm_pipeline` copy staged by the umbrella's
`scripts/deploy.sh` for production Docker builds. Publishing trigger: a second
consumer, or the user asks.

Its size carries no literal here on purpose — every file this package gains
re-breaks one, and the two that used to live on this line had drifted by 2.4
(`24`/`15` written, `25`/`18` measured). Re-derive instead, from this repo's
root:

```bash
find lib  -name '*.ex'       | wc -l   # lib files
find test -name '*_test.exs' | wc -l   # test files
```

> What the framework *does* — Step, Executor, StepLog, ArtifactStore, the
> `:content` convention, artifact lineage — is documented from the consumer's
> side in the Amesbury repo: `apps/amesbury_scraper/CLAUDE.md` §1 there, plus
> the pipeline sections of its root `CLAUDE.md`. This file is only the things
> that are specific to working **inside** this repo and that the code does not
> make obvious.

---

## 1. The dep list's omission is the architecture

`mix.exs` deliberately declares **no** host dependency — nothing from the
Amesbury umbrella or any other consumer. It looks sparse; it is the whole
point. Naming `Amesbury.*` or `AmesburyScraper.*` (or any consumer's namespace)
anywhere in `lib/` is a **compile error**, not a review finding somebody has to
notice — the omitted in-umbrella dep enforced this in the umbrella era, and the
repo boundary now enforces it even harder. Do not "fix" it, and do not add a
dep to make a reach compile — the reach is the bug.

Host collaborators resolve at **runtime** instead, through the host's
`use ALLM.Pipeline.Registry` declaration (Amesbury's is `Amesbury.Pipelines`,
installed from `AmesburyScraper.Application.start/2`; this repo's own suite
installs `ALLM.Pipeline.TestSupport.Registry` from `test/test_helper.exs`).
The config namespace is `:allm_pipeline` — the package's own OTP app name,
hardcoded in `Config`, `Store`, `Artifacts`, `Lock`, `LLM`, `LLMCallLog` and
`Artifacts.Dynamo`. That per-module literal is deliberately not centralized
into one `otp_app/0` accessor (it would churn 40+ sites for no behavioral gain,
and the house style distrusts singleton accessors); to move the namespace again
you substitute the value at each site, but there is no trigger left to — it is
already the package's own name.

**`ALLM.Pipeline.Config.repo/0` is the single, permanent host-repo handle** —
settled as option (b) in batch 1.B, not a Phase-1 shim. Do not add a second
`repo/0` anywhere in `lib/`: `test/allm/pipeline/behaviours_test.exs` asserts the
set of modules exposing one is **exactly** `[ALLM.Pipeline.Config]`, and a
generated `repo/0` on a host adapter would fail it.

**Adding a mandatory `@callback` to a package behaviour means stubbing it on
EVERY in-tree implementer in the same batch — test doubles included.**
`behaviours_test.exs`'s conformance scan iterates
`Application.spec(:allm_pipeline, :modules)` — which **does** include
`elixirc_paths(:test)` support modules (`TestRepo`, the test registry and
`TargetDeclaration` all appear in it; verified by execution in Phase 8.1 —
what the spec excludes is modules defined inside `.exs` test FILES). So a test
double like `SentinelStore` (`test/allm/pipeline/executor_store_dispatch_test.exs`,
an `.exs`-defined module) that misses the new callback is invisible to that
guard — it surfaces only as a test-compile warning. `mix precommit`'s
`test --warnings-as-errors` turns that warning into a hard red, so the gate
catches it, but stub it proactively rather than discovering it at the gate. Declare `@optional_callbacks` only if the callback
is genuinely optional for an adapter. (Phase 7.4's `Store.log_skipped/4` shipped a
missing `SentinelStore` stub for exactly this reason.)

## 2. `mix test` runs from THIS repo's root, standalone

```bash
mix test        # from ~/Projects/ALLM.Pipeline — creates + migrates allm_pipeline_test itself
mix precommit   # compile --warnings-as-errors + format + test --warnings-as-errors
```

The harness is self-contained (Phase 8.1). The `test` alias runs
`ecto.create` / `ecto.migrate -r ALLM.Pipeline.TestRepo` against
`priv/test_repo/migrations/` — **test-harness DDL only**; production migrations
stay in the host ("table names are contract"), and the DDL is
schema-parity-checked against the host's `amesbury_test` (the re-run site is
named in the migration's own moduledoc). `test/test_helper.exs` installs
`ALLM.Pipeline.TestSupport.Registry` (TestRepo + `Store.Ecto` + Tiered
artifacts + `Lock.Noop`; deliberately **no `llm:`** — `ALLM.Pipeline.LLM.impl/0`
raising when unwired is designed behaviour and no package test may depend on a
wired LLM), then starts the TestRepo before `Sandbox.mode/2` — the package has
no supervision tree (`application/0` carries no `mod:`), so nothing else would
start it. `test/allm/pipeline/test_harness_test.exs` pins that wiring.

Environment: host Postgres at `localhost:5432` (`DATABASE_HOST`/`DATABASE_USER`
env overrides, same shape as the umbrella's test config); DynamoDB Local at
`localhost:4028` with the **distinct** table `allm_pipeline_artifacts_test`
(bootstrapped idempotently by `test_helper.exs` — the `:dynamo` exclusion probe
keys on the table existing, so without the bootstrap a fresh clone with the
stack UP would exclude the dynamo tests; see §4); MinIO at `localhost:4026`
(bucket `amesbury-artifacts-test`, shared with the umbrella suite — keys are
per-test unique). Toolchain pin: `.tool-versions`
(erlang 27.1.2 / elixir 1.17.3-otp-27). The suite runs on the **host**: inside
the Amesbury devcontainer this repo is mounted **readonly**, so `_build`
cannot be written there.

**Two-gate reality** (the Amesbury repo's root `CLAUDE.md` → "Continuous
Integration"): the umbrella's `mix precommit` no longer
compiles-with-warnings-as-errors, formats, or tests this tree — a path dep
compiles without `--warnings-as-errors`, the umbrella's `.formatter.exs` no
longer reaches it, and this `test/` tree is never on the umbrella's load path
(a non-umbrella path dep compiles with dep-internal `Mix.env() == :prod`).
Every package change gates with THIS repo's `mix precommit`. One asymmetric
extra: the umbrella compiles this package under whatever toolchain compiles
the umbrella (that host's global is Elixir 1.19.5/OTP 28), so the package must
also stay warning-free there. Check it fail-closed from the umbrella root —
never as a bare `… | grep -c 'warning:'`, whose success signal is emptiness
(a compile ERROR also produces zero `warning:` lines, and the pipe eats the
non-zero exit — the exit-code-by-pipe trap):

    mix deps.compile allm_pipeline --force > /tmp/allm-compile.log 2>&1; echo "exit: $?"
                                            # expect: exit: 0
    grep -c 'Compiling' /tmp/allm-compile.log   # positive control — expect non-zero
    grep -c 'warning:' /tmp/allm-compile.log    # expect 0

**Devcontainer + service stack.** `.devcontainer/` is the ALLM/Amesbury
pattern (asdf erlang/elixir features at the `.tool-versions` pins,
`docker-outside-of-docker`); `docker-compose.yml` is the DynamoDB Local +
MinIO (+ optional `--profile postgres`) stack on the **same ports as the
umbrella's** — deliberately, because `config/test.exs` defaults to them and
the MinIO bucket is shared. So the two stacks are mutually exclusive, and
that is fine: either one serves this suite. In the container the stack is on
the host daemon, reached via `host.docker.internal` (preset in
`containerEnv`).

(The umbrella-era failure this section used to document — `cd
apps/allm_pipeline && mix test` dying in the umbrella's `runtime.exs` on a
missing `Dotenvy` — died with the extraction: the standalone `mix.exs` carries
no umbrella `config_path` and this repo has its own `config/`.)

## 3. DB-backed tests

The package owns Ecto schemas and no production repo. A DB-backed test checks
out whatever `Config.repo/0` resolves to — in this repo's suite that is the
test-only `ALLM.Pipeline.TestRepo`, installed by the test registry:

```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(ALLM.Pipeline.Config.repo())
  :ok
end
```

`:manual` mode is set by **this repo's own** `test/test_helper.exs` — a test
tree that silently borrowed a host harness would be the same leak `mix.exs`'s
omitted dep prevents for `lib/` (and is structurally impossible now that the
host lives in a different repo). The failure
mode if that ever regresses is not a clean red: under `:auto` every query gets its
own rolled-back transaction, so `create_run/3` succeeds and `get_run/1` returns
`nil` one line later, which reads as an adapter bug. `store_test.exs` pins the
mode with a bare-`spawn` probe (Ecto resolves ownership through `$callers`, which
a `Task` would inherit and an unrelated process has not).

## 4. `:dynamo` exclusion — the measured behaviour

`test_helper.exs` takes the probe, the operator message **and** the tag list from
`ALLM.Pipeline.Artifacts.Dynamo.exclusions/0` — one implementation, which the
Amesbury umbrella's `test_helper.exs` ALSO calls from its repo (the shared
function is the cross-repo drift guard; do not hand-copy the tag list back in
either tree). Before computing exclusions, `test_helper.exs` attempts an
idempotent `Dynamo.create_table()` — the probe keys on the TABLE existing, and
the only other `create_table/0` callers are `:dynamo`-tagged setups that run
only when NOT excluded, a chicken-and-egg that silently excluded the whole
dynamo set on a fresh clone with the stack up (Phase 8.1 deviation D1).

Measured 2026-08-25 (Phase 8.1, standalone), both directions:

| DynamoDB | Result |
|---|---|
| up | `3 doctests, 600 tests, 0 failures`, **no** `Excluding tags` line |
| down (`DYNAMODB_ENDPOINT=http://127.0.0.1:9`) | `3 doctests, 600 tests, 0 failures, 20 excluded` + the operator message |

Note what this means for testing `exclusions/0` itself: ExUnit exits 0 whether it
excludes 0 or 20, so a mutant of it leaves a green suite. **The two-direction run
above is its only discriminating observable** — re-run the pair rather than
mutating it.

## 5. `test/` may not depend on host-installed application env

The compiler enforces the boundary for **names** in `lib/`. It is blind to
**runtime state**, and every leak found in Phase 1 came through the test tree:
`lock_test.exs` spent a batch asserting `Lock.impl() == Noop` while the host's
registry (`Amesbury.Pipelines`, in the umbrella era) was installing exactly
`Noop` at boot, so it observed the host's declaration and could not have seen
the framework's fallback change. The same shape exists standalone — the
installer is now `ALLM.Pipeline.TestSupport.Registry` from `test_helper.exs`,
and a test that observes what IT installs is observing the harness, not the
framework.

So: a package test that reads or writes `Application.get_env(:allm_pipeline,
…)` **establishes the value it depends on and restores it**, and is `async: false`
(the application env is global to the VM). The shape, in `setup`:

```elixir
use ExUnit.Case, async: false

setup do
  previous = Application.get_env(:allm_pipeline, Lock)
  on_exit(fn ->
    if previous,
      do: Application.put_env(:allm_pipeline, Lock, previous),
      else: Application.delete_env(:allm_pipeline, Lock)
  end)
  :ok
end
```

Reference implementations: `lock_test.exs`, `registry_test.exs`,
`executor_store_dispatch_test.exs`. The carve-out test when deciding whether an
assertion belongs here at all is *"does it depend on a value this tree does not
own?"* — not *"does it compile here?"*. Host-owned values live in the
**Amesbury umbrella repo**:
`apps/amesbury_scraper/test/amesbury/pipelines_declared_values_test.exs` there.

## 6. `Registry.__install__/1`'s `put_new` / `put` asymmetry is deliberate

The **seam** keys (`ALLM.Pipeline.Store` / `Artifacts` / `Lock` / `LLM`) are
written with `Keyword.put_new(existing, :impl, impl)`; `:repo`,
`:alert_on_empty` and `:lock_keys` are written unconditionally with
`Application.put_env`. Do not "simplify" it in either direction.

`llm:` is additionally **optional**, and an undeclared one installs nothing at
all — that is what leaves `ALLM.Pipeline.LLM.impl/0` raising. It is the only
seam with no package adapter to default to (there is no provider integration
the package could ship), so "unwired" must be loud rather than neutral.

Config files are applied before `Application.start/2`, so `install/0` is the last
writer. `put_new` on the seams keeps an env-specific `config :allm_pipeline,
ALLM.Pipeline.Artifacts, impl: …Filesystem` winning — which two moduledocs
document as the supported route — because a registry is one compile-time
declaration and cannot be env-specific, while adapter selection legitimately is.
The other three are not adapter selection, have no env-specific use, and their
failure mode is the opposite: a stale config line silently outranking the
declaration. `registry_test.exs`'s "a config-file `impl:` outranks the
declaration" describe pins both halves.

## 7. The pipeline DSL (`use ALLM.Pipeline`) — in-package rules

What the DSL *means* is `ALLM.Pipeline`'s moduledoc, and it is not restated
here. This section is only the things that bite when working **inside** the DSL's
own files and that the code does not make obvious. Re-derive the set rather than
trusting a count:

```bash
ls lib/allm/pipeline.ex \
   lib/allm/pipeline/dsl.ex \
   lib/allm/pipeline/dsl/*.ex \
   lib/allm/pipeline/lifecycle.ex
```

**A hook is quoted AST, not a value, and it has to stay that way.**
`Module.put_attribute/3` rejects anonymous functions, and `&local/2` written in
a module body requires the function to be defined *already* — which a
declaration block at the top of a module never satisfies. So every construct
accumulates a spec containing AST onto `@allm_pipeline_stages`, and
`ALLM.Pipeline.__before_compile__/1` splices it into the body of the generated
`__pipeline__(:stages)`, where every `def`/`defp` is defined. Consequences:

* `__pipeline__(:stages)` **builds its structs on every call**. It is not a
  cached attribute and cannot become one. Bind it once if you are iterating.
* An atom hook expands to a local capture, which is why a hook may be `defp` —
  and why the arity in `Dsl.__hook_arities__/0` is load-bearing twice over: it
  is what the capture is built at AND what `Dsl.__assert_hooks_defined__!/2`
  checks the module defines. Change one and you have silently changed the
  other. That attribute is the **single source** for every hook arity — 12
  (`MIX_ENV=test mix run --no-start -e 'IO.puts(length(ALLM.Pipeline.Dsl.__hook_arities__()))'`);
  do not restate one at a call site or in a doc table (`hook/2` looks it up),
  and `dsl_test.exs`'s "every hook option has exactly one declared arity" pins
  the set. A wrong row does not fail where you changed it — it fails as
  `"names finalize/3, which this module does not define"` against a correctly
  written hook, blaming the declaring module.
* Anything that is not an atom is spliced **verbatim**, so a `use`-level hook
  written as a capture must be a REMOTE one (`&Mod.fun/1`). A local capture
  there evaluates before the function exists.

**A `Dsl` validator whose result is destined for a `quote` must RETURN quoted
AST, not the term.** Both splice paths put a validated scalar straight back
inside a `quote`: `__stage_ast__/1`'s `{:%{}, [], fields}`, and
`ALLM.Pipeline.__before_compile__/1`'s `def __pipeline__(:concurrency)`. A real
3-element tuple is not a valid AST node, so returning one is
`** (CompileError) invalid quoted expression: {:opt, :concurrency, 2}` at the
**using** module, naming neither the option nor this file. `accumulate/1`'s
`Macro.escape/1` does **not** cover it — that escape runs BEFORE the splice, to
round-trip the spec through a module attribute. `validate_ms!/3` got this right
from the start; `validate_concurrency!/3` did not, and its `{:opt, …}` clause was
therefore **dead for every consumer** until Phase 4.4's `committee` port needed
it (`grep -rn 'concurrency: {:opt' apps` -> 0 hits before that). Any new
`{:opt, key, default}`-shaped option is the third instance. Pinned by
`dsl_test.exs`'s "`concurrency: {:opt, key, default}`", whose positive case
declares the form at BOTH levels in one module — a fix applied to one splice site
leaves the other a compile error.

**`stage/3` disambiguates on AST SHAPE (`{:__aliases__, _, _}`), never on
`is_atom/1`.** An alias *is* an atom once expanded, so an `is_atom` test treats
every Step module as a hook — and the failure is a `FunctionClauseError` at the
first live run, not a compile error. `dsl_test.exs`'s "an alias is the Step
form, never a hook" pins it.

**Validator argument order is `(module, opts)`.** `Dsl.__validate__!/2` matches
`Registry.__validate__!/2`, `LLMStep.__validate__!/2` and `Schema`'s
`validate_use!/2`. All four; keep it that way — two same-named
`__validate__!/2`s with opposite signatures in one package is the footgun
Phase 3 already paid for once.

**A rejection of a `use`-option PAIR belongs in `__validate__!/2`, not in
`__before_compile__/1`.** 4.1's D-6 routes the `use`-time *hooks* to
`__before_compile__` because `Module.defines?/2` cannot answer at `use` time;
that reason does not reach a scalar pair, whose presence is a literal fact about
the quoted opt list. Both pair rejections live there and sit adjacent —
`fetch_summary_type!/3` (`summary_type:` + `returns: :run`) and
`fetch_borrowed_run!/3` (`borrowed_run: true` + `dry_run:`). What each pair MEANS
is `ALLM.Pipeline`'s moduledoc and is not restated here.

**`Dsl.__validate__!/2` receives QUOTED opts, not terms.** It cannot evaluate
them (hooks must survive as AST), so scalars are validated as *literals*. A
`name:` computed from a module attribute is therefore a compile error, not a
feature request — and that is what makes a malformed scalar fail at the using
module's compile time rather than at its first run.

**The concurrent fan-out's compose check runs OUTSIDE the per-item `catch`.**
`Runtime.run_concurrent/7` returns `{item, acc_update}` from each task and
raises in the `Enum.map` afterwards. Raised inside, it would be caught by the
very `catch` that keeps the fan-out alive and degraded into three
`{:uncaught, :error, _}` items — turning a declaration bug into silent data
loss. Measured: that is exactly what the first implementation did, and
`runtime_test.exs`'s "a concurrent fan_out whose body folds the accumulator
raises" is the test that caught it.

**A stage's target is invoked in exactly one place: `Runtime.run_target/5`.**
Both kinds go through it — a `:stage` from `do_stage/5`, each `:fan_out` item
from `run_item_body/5` — and they differ only in what they do with the result
afterwards (`apply_result/3` vs `to_item/2`). `run_target/5` itself is the
Step-vs-body dispatch (a `step: nil` stage calls its body, else it routes through
`Executor.run_step/5`). Writing that dispatch a second time is how the kinds
silently diverge on one kind only, which is invisible until a port's step-log
tree differs. (Phase 5.10 removed `retry:`, which used to wrap this seam with an
`attempt_target/6` recursion; `run_target/5` is now the single non-recursive
dispatch.)

**The sequential and concurrent fan-out paths handle a raising item
differently, on purpose.** The SEQUENTIAL path calls `run_item/6` directly with
NO wrapping `catch`, so an uncaught infrastructure raise aborts the run. The
CONCURRENT path wraps every item in `Runtime.guarded_item/6` (which uses
`FanOut.guard/3`) **unconditionally** — that is link safety, not policy:
`Task.async_stream` links its children, so an uncaught raise or exit kills the
caller. Do not "simplify" them to one path. (Phase 5.10 removed the
`catch_item_failures:` option that could opt the sequential path into catching;
nothing consumed it.)

**The lifecycle guard is `ALLM.Pipeline.Lifecycle`, and it has TWO consumers.**
`Dsl.Runtime.execute/4` uses `guard/2` and `settle/4` separately — resource
teardown runs *between* them (D3) — while a hand-written entry point calls
`owned_run/4`, which composes create → guard → settle. Do not grow a third copy
of `try/rescue/catch` + `complete/2` + `fail_pipeline_run/2` anywhere: the tree
already paid for that, with four entry points that terminated their run on no
path and two orchestrators with no `rescue` at all. `guard/2` catches all three
kinds, always — `rescue` never sees an exit, and a Playwright teardown is one.

**It is not the only complete-or-fail tail, and the older one is what the host
docs point at.** `ALLM.Pipeline.Executor.finish_run/2` predates it and is still
correct for its case — a caller that already holds an owning handle, writes no
metadata, and is already inside somebody else's guard. It creates nothing and
**guards nothing**. An entry point that creates its own run wants
`owned_run/4`; the full boundary is the table in `ALLM.Pipeline.Lifecycle`'s
moduledoc, "Versus `Executor.finish_run/2`". Do not restate it here.

**`normalize_body/1` runs INSIDE `owned_run/4`'s guarded closure, and that is
load-bearing.** Its `ArgumentError` for an unsanctioned body shape is a contract
violation like any other raise, so it has to become a `{:raised, …}` settlement.
Evaluated around the guard — as it was until 4.3's fix pass — it escaped with
the run created and never terminated, i.e. the exact orphan-run defect the
module exists to close, on the one path whose test asserted the raise but not
the row. `Dsl.Runtime` does not share the shape: its `settlement/1` sees only
`work/6`'s framework-controlled returns.

**Teardown-error metadata is ONE rule written twice, and the reason is Ecto.**
`Lifecycle` merges `"resource_teardown_errors"` into the metadata `complete/2`
receives as an ARGUMENT, but onto the run STRUCT's metadata for
`fail_pipeline_run/2`, which has no metadata parameter. The struct channel is
not available to `complete/2`: when the merged map equals the struct's own
metadata, Ecto sees no change and **silently drops the field**. Measured — a
teardown failure under a `complete_metadata:` returning `%{}` wrote nothing to
the row, while the identical code path with a non-empty map wrote it. `fail/2`
always adds its `"error"` key, so it always changes.

**The self-owned `run/1` lifts `:parent_run_id` out of `opts` into
`create_pipeline_run/3`'s ATTRS.** A ported pipeline invoked as a child (with
`parent_run_id:` in its opts) sets the queryable `pipeline_runs.parent_run_id`
FK COLUMN through here; without the lift the opt would reach the child's
generated `run/1` and stop there, leaving the column `nil` while the metadata
carried an unqueried key. `Runtime.run_owned/3` is where the lift happens; it
mirrors what the hand-written consumers do. (Phase 5.10 removed the
`child_pipeline` construct, which relied on this lift — the lift itself has
always been on the self-owned path and stays. `runtime_test.exs`'s "self-owned
parent_run_id lift" is its regression coverage.)

**A `resource`'s `start` is guarded too, and `acquire/2` returns a PAIR.** On a
failing `start` the fold halts and hands back the resources acquired *so far*,
so the caller can release them. Returning only the failure would leak exactly
the handles the construct exists to manage.

**Tests are DB-backed and split by half.** `dsl_test.exs` is the compile-time
half and touches no database; `dsl/runtime_test.exs` is the runtime half and
checks the sandbox out per §3. Pipeline fixtures live as module definitions at
the top of the runtime file — `use ALLM.Pipeline` runs at compile time, so a
declaration inside a `test` block would be re-evaluated per run. The
compile-time rejection tests build throwaway modules through
`Code.eval_string/1` under `System.unique_integer/1` names: a reused name is a
redefinition, and the second run would observe the FIRST module.

**`test/support/target_declaration.ex` is the acceptance spec, not a fixture of
convenience.** It transcribes the design doc's target declaration — what the
`meeting_agenda` port will write — against stub Steps, so the hardest pipeline
in the tree drives the construct set. It is on `elixirc_paths(:test)`
deliberately: a construct silently dropped from the DSL becomes a **compile**
failure, which is the strongest gate available. Its module name is a package
name because this app names no host module (§1); the shape is what is proven,
not the names.

**An option that accepts the `{:opt, key, default}` form must be exercised by a
compile-time test declaring it at EVERY splice level, in one module.** The form
is spliced back into a `quote`, so a validator returning the real 3-tuple
instead of the quoted one produces `invalid quoted expression` — and a fix
applied at one splice site leaves the other broken. `concurrency:` shipped dead
at both levels for three subphases with its own sibling comment asserting the
opposite; the first production declaration is what found it, not the tests.
Corollary for closing a subphase: record per construct whether a **production**
declaration exists — and production declarations live in the CONSUMER's repo,
so run the census from the Amesbury umbrella root:
`grep -rn '<option>:' apps --include '*.ex' | grep -v /test/` there returning
`0` is a finding to state, not a pass — four constructs shipped green here
because nothing consumed them.

## 8. Releasing (`scripts/release.exs`)

The script is the ALLM one (`~/Projects/ALLM/scripts/release.exs`) ported:
two-phase, **never publishes and never pushes**. Phase A (`<bump>`) runs the
gates and rewrites `@version "…"` in `mix.exs` by regex — keep that literal on
its own line; Phase B (`--finalize`) commits + tags after the manual
`mix hex.publish`. Why it cannot publish itself: Mix archives (Hex) are not
loaded into `mix run`'s runtime, and Hex's device-flow auth crashes headless.
Do not "fix" that with `--yes` — the prompts are the safety story.

Things specific to this package, not inherited from ALLM:

* The gates are exactly `mix precommit`'s three plus `dialyzer` and
  `hex.build`; there is no credo dep. `mix test` with the stack down exits 0
  with the `:dynamo` set **excluded** (§4), so the script greps the test
  output for `Excluding tags` and WARNS — a green gate with that warning is a
  weaker gate, not a pass.
* The image-touch warning became a **migration-touch** warning:
  `priv/test_repo/migrations/` is parity-checked against the host, so a change
  there since the last tag means re-running that check before publishing.
* `--dry-run` performs **no** rollback `git checkout -- mix.exs` (ALLM's does).
  Dry-run never writes, and under `--allow-dirty` that checkout discarded
  uncommitted `mix.exs` edits (caught by reading the code while porting).
* A release changes nothing for the umbrella, which is a **path** dep
  consumer; `mix.exs` there switches to a Hex requirement only when the user
  decides to (the "second consumer, or the user asks" trigger at the top).
* `CHANGELOG.md` is required (`## [REL] vX.Y.Z — …` heading, the
  `/changelog` skill's format) and ships in the tarball; `HISTORY.md`/`ASKS.md`
  do not.
