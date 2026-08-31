# Multi-Consumer + Hex Release Prep — Design

**Goal.** Retire the single-consumer debts recorded across `CLAUDE.md` and the
moduledocs — the `:amesbury_scraper` config namespace, the host-internal
hexdocs prose, the missing consumer-onboarding story — and publish
`allm_pipeline` v0.1.0 to Hex, so the second and third consumers wire against a
clean public package instead of a private extraction.

**Measurable outcome.** `grep -rni 'amesbury' lib/ config/` returns 0 (positive
controls in each subphase), both repos' gates are green, `allm_pipeline 0.1.0`
is live on Hex with a host-wiring guide and canonical DDL in the tarball, and
the Amesbury umbrella still runs unchanged on the path dep.

**Spec/plan lineage.** This is not a phase of an existing phasing doc; it
executes the recorded triggers ("the rename trigger is a second consumer",
"Publishing trigger: a second consumer, or the user asks" — `CLAUDE.md` §1 and
header) left by the extraction plan
(`steering/2026-08-25_ALLM_PIPELINE_PHASE_8.md` in the Amesbury repo).

**Layers touched.** Package config seam (`lib/`), both repos' `config/`, test
trees, hexdocs (`mix.exs` docs/package + one NEW guide), release tooling usage,
agent docs. No schema change, no new behaviour, no new seam.

---

## Status

| Subphase | Concern | Status |
|---|---|---|
| 1 | Package-side namespace rename + Dynamo default table | Complete |
| 2 | Umbrella lockstep seam-key move | Complete (2026-08-31, landed host-side from the umbrella checkout) |
| 3 | Hexdocs-facing `lib/` prose sweep | Complete |
| 4 | Consumer onboarding guide + DDL shipping | Complete |
| 5 | v0.1.0 release | Deferred — user-gated (public remote + Hex auth preconditions) |
| 6 | Multi-consumer agent-doc updates | Complete |

Overall Progress: 5/6 (subphase 5 deferred to the user)

Per-subphase records (deviations, verification transcripts) go to
`steering/2026-08-31_MULTI_CONSUMER_HEX_PREP_RECORDS.md`, created on first
need.

---

## Overview

### Deliverables

- The framework reads all configuration under `:allm_pipeline` (contract C1),
  in both repos, with the Mix boot notice gone.
- `lib/` prose is host-neutral: no `Amesbury`/`amesbury_scraper` names reach
  hexdocs; pointer-worthy host facts relocate to `CLAUDE.md`.
- A `guides/host_wiring.md` hexdocs page and the parity-checked test-harness
  migration ship in the tarball as the consumer-onboarding path.
- `allm_pipeline` v0.1.0 published via the existing two-phase
  `scripts/release.exs` flow.
- `CLAUDE.md`/`agent-spec/` updated for the multi-consumer reality.

### Out of scope (each with justification)

- **Renaming the shared test MinIO bucket `amesbury-artifacts-test`**
  (`config/test.exs:34`) — the sharing with the umbrella suite is deliberate
  ("either stack serves this suite", `CLAUDE.md` §2) and test-only; nothing
  ships to Hex.
- **`Filesystem`'s coded default root** — already host-neutral:
  `Keyword.get(:root, Path.join(System.tmp_dir!(), "allm_pipeline_artifacts"))`
  (`lib/allm/pipeline/artifacts/filesystem.ex:187`). Only its moduledoc
  *example* (`filesystem.ex:13`) is host-named; that is subphase 3.
- **Sweeping `test/` moduledocs of Amesbury mentions** — the test tree is not
  hexdocs-rendered and its host pointers (e.g. `lock_test.exs:30`) are
  load-bearing history for maintainers.
- **Switching the umbrella to the Hex dep** — recorded as the user's call
  (`CLAUDE.md` §8: "`mix.exs` there switches to a Hex requirement only when
  the user decides"); the path dep keeps working after publish.
- **Building consumers 2 and 3** — this design ends where their onboarding
  begins; each consumer's port gets its own design (including its
  production-declaration census, `CLAUDE.md` §7 corollary).
- **Dropping `CLAUDE.md` from the tarball** — it stays in `package.files`; the
  repo goes public at the same moment (subphase 5 precondition), so the
  tarball adds no exposure the GitHub remote doesn't.

### Non-obvious decisions

- **Hard rename, not dual-read.** The only consumer is a path dep in a sibling
  checkout under the same owner; a compatibility shim that reads both
  namespaces would outlive its one-commit usefulness and become the third
  place the namespace is spelled. Both repos land in the same sitting
  (subphases 1+2), which is the same lockstep every cross-repo change here
  already requires.
- **Keep the per-module hardcoded atom; do not centralize into an accessor.**
  Alternative considered: one `otp_app/0` every seam module calls.
  Rejected: it churns 40+ call sites into a new shape for zero behavioral
  gain, and the house style already treats singleton accessors with suspicion
  (`behaviours_test.exs` pins `repo/0` to exactly `[ALLM.Pipeline.Config]` —
  `CLAUDE.md` §1). The rename is one mechanical atom substitution; a future
  rename has no trigger left (the namespace becomes the package's own name).
- **`:allm_pipeline` as the namespace**, i.e. the package's own OTP app name —
  the conventional Elixir shape, and it is what kills the Mix "configured
  application `:amesbury_scraper` … not available" boot notice (the configured
  app is now a loaded one).
- **Ship the test-harness migration as the canonical DDL** rather than inlining
  DDL in the guide. `priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs`
  is already the parity-checked transcription of the host's frozen migrations
  (its moduledoc, lines 2–32); inlining a second copy in a guide would create
  the exact two-sources-of-truth its moduledoc warns about. The guide points
  at the file; the file ships in the tarball.
- **Release as explicit `0.1.0`, no bump.** `mix.exs:@version` is already
  `"0.1.0"` and unpublished; `scripts/release.exs` accepts an explicit semver
  (`compute_new_version/2`, `scripts/release.exs:306-314` — parses and returns
  it, no equality check against current), and the `@version` regex rewrite is
  idempotent for an equal value. `CHANGELOG.md:1` already carries the required
  `## [REL] v0.1.0` heading.

### Review lanes

- `/code-review`: applies (subphases 1–4 touch `lib/`).
- `/security-review`: N/A — no new runtime input handling, no new
  dependency, no auth/crypto surface; the changes are an atom rename and
  prose. Trigger to revisit: any subphase deviating into new runtime behavior.
- `/design-review` (visual): N/A — no frontend.

---

## Contracts

### C1 — The config namespace (single normative home)

The framework reads and writes ALL of its application configuration under the
package's own OTP app:

```elixir
Application.get_env(:allm_pipeline, key)
```

`ALLM.Pipeline.Registry`'s `@otp_app` becomes `:allm_pipeline`
(today `:amesbury_scraper`, `lib/allm/pipeline/registry.ex:154`). The key set
is unchanged — only the app atom moves:

| Key | Kind | Writer | Package read site (today) |
|---|---|---|---|
| `ALLM.Pipeline.Store` | seam (module) | registry `put_new` / config file | `store.ex:197` |
| `ALLM.Pipeline.Artifacts` | seam (module) | registry `put_new` / config file | `artifacts.ex:166` |
| `ALLM.Pipeline.Lock` | seam (module) | registry `put_new` / config file | `lock.ex:76` |
| `ALLM.Pipeline.LLM` | seam (module, optional) | registry `put_new` / config file | `llm.ex:114` |
| `:repo` | top-level | registry, unconditional | `config.ex:110` |
| `:alert_on_empty` | top-level | registry, unconditional | `config.ex:160` |
| `:lock_keys` | top-level | registry, unconditional | `config.ex:198` |
| `:dynamo` | top-level adapter config | config files only | `dynamo.ex:65,420,513` |
| `ALLM.Pipeline.ArtifactStore` | module config | config files | `artifact_store.ex:163` |
| `ALLM.Pipeline.LLMCallLog` | module config | config files | `llm_call_log.ex:55` |
| `ALLM.Pipeline.Artifacts.{Filesystem,S3,Tiered}` | adapter config | config files | `filesystem.ex:186`, `s3.ex:60,103,287`, `tiered.ex:128` |

The `put_new`-vs-unconditional asymmetry (`CLAUDE.md` §6) is untouched.

A host's own app keys do NOT move: `:amesbury_scraper` remains the umbrella's
real application with its own non-pipeline config. Only lines whose key
appears in this table migrate (subphase 2).

### C2 — Dynamo default table name

`Artifacts.Dynamo`'s coded fallback becomes `"allm_pipeline_artifacts"`
(today `Keyword.get(:table_name, "amesbury_artifacts")`, `dynamo.ex:66`).
Consumers name their production table via `config :allm_pipeline, :dynamo,
table_name: …`; the umbrella sets it explicitly in every environment that
matters (prod: `config/runtime.exs:449` reads `env!("DYNAMODB_TABLE",
:string!)` — verified by grep in the Sites list, subphase 2), so the default
never fires there.

### C3 — Raise-message namespace

Every framework raise that names the config namespace says `:allm_pipeline`.
Pinned today by `config_test.exs:69,81,91,119,156`
(`assert message =~ ":amesbury_scraper"` — these assertions flip with the
rename, same lines).

### C4 — The onboarding guide

NEW file `guides/host_wiring.md`, a hexdocs extra. Required sections (content
assembled from the cited normative homes, not restated):

1. **Registry wiring** — the `use ALLM.Pipeline.Registry` declaration,
   `install/0` from the host's `Application.start/2`, seam-key semantics
   (source: `registry.ex` moduledoc).
2. **The optional `llm:` seam** — undeclared means `LLM.impl/0` raises by
   design (source: `llm.ex` moduledoc).
3. **Production DDL adoption** — copy
   `priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs` into
   the host's migrations; table names are contract; the host owns and freezes
   them thereafter.
4. **Artifact infrastructure** — DynamoDB table (`:dynamo` config +
   `Dynamo.create_table/0`), S3 bucket, the Tiered default.
5. **Consumer test-suite pattern** — a host test registry, sandbox checkout
   via `Config.repo/0`, and `Artifacts.Dynamo.exclusions/0` as the shared
   stack-down probe (the cross-repo drift guard, `CLAUDE.md` §4).

`mix.exs` changes: `docs.extras` gains the guide; `package.files` gains
`guides` and `priv/test_repo/migrations` (today
`~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE CLAUDE.md)`).

### Error contract table

N/A — no validator-shaped module is added or changed; the only error-text
change is C3's namespace substitution.

### DDL

No schema change anywhere. The migration file receives a moduledoc addition
(subphase 4), and its own rule applies: "After ANY edit to this file, re-run
the schema-parity queries" (migration moduledoc, lines 27–31) — that re-run is
in subphase 4's verification.

---

## Module tree

No NEW lib modules. NEW files: `guides/host_wiring.md` (subphase 4; `ls` of
the repo root confirms no `guides/` exists today) and the records companion
(on first need).

**MODIFY — subphase 1 (package rename).** The 14 `lib/` files holding the 43
atom sites — re-derive, don't trust this list if stale:

```bash
grep -rln ':amesbury_scraper' lib/
# lib/allm/pipeline/{llm,registry,store,artifacts,config,artifact_store,
#   llm_call_log,lock}.ex
# lib/allm/pipeline/artifacts/{dynamo,filesystem,s3,tiered}.ex
# (measured 2026-08-31: 43 atom sites in lib/, 137 in test/+config/)
```

plus `config/test.exs`, the test tree (same grep over `test/`), `README.md`,
`CLAUDE.md`, `agent-spec/CODE_REVIEW.md`.

**MODIFY — subphase 2 (umbrella, sibling repo `~/Projects/amesbury`).**
Config: `config/config.exs:52-55,62,116`, `config/dev.exs:80,89`,
`config/test.exs:43,51`, `config/runtime.exs:51,81,449,461`,
`config/eval.exs:27`. App code:
`apps/amesbury_scraper/test/amesbury/pipelines_test.exs:90`,
`apps/amesbury_scraper/lib/amesbury/pipelines.ex:66` (comment),
`apps/amesbury_scraper/eval/eval_helper.exs:186`. (Measured 2026-08-31; the
re-derive grep is in subphase 2's checklist.)

**MODIFY — subphase 3 (prose sweep).** The 27 `lib/` files with non-atom
mentions — re-derive with
`grep -rli 'amesbury' lib/` (measured 2026-08-31: 100 case-insensitive
mentions total, of which 43 are the atom removed by subphase 1).

**MODIFY — subphase 4.** `mix.exs`,
`priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs`
(moduledoc only), `README.md`.

**MODIFY — subphase 6.** `CLAUDE.md`, `agent-spec/DESIGN.md`,
`agent-spec/CODE_REVIEW.md`, `README.md`.

Test files: no new test files. Changed test files are exactly the rename
grep's hits plus `test/allm/pipeline/registry_test.exs:458` (fixture value
`dynamo_table: "amesbury_artifacts"` → renamed with C2).

---

## Subphase 1 — Package-side namespace rename + Dynamo default

One concern: every package read/write of the config namespace moves to
`:allm_pipeline` (C1), the Dynamo fallback table renames (C2), and the docs
this falsifies are corrected in the same commit. Behavior-preserving
otherwise: no seam, arity, or return shape changes.

**Test plan (first).** The existing suite IS the spec — it exercises every
seam through the renamed namespace. Deltas only:

- `config_test.exs:69,81,91,119,156` — message assertions flip to
  `":allm_pipeline"` (C3).
- `registry_test.exs:458` — fixture table name follows C2.
- The boot notice's disappearance is asserted by observation, not a new test:
  `mix test 2>&1 | grep -c 'but the application is not available'` → `0`
  (positive control: the same grep today returns non-zero — the notice is why
  README.md:129-135 exists).
- `CLAUDE.md` §4's rule: the two-direction dynamo pair is the only
  discriminating observable for `exclusions/0`-adjacent changes — re-run it.

**Checklist.**

- [ ] Substitute `:amesbury_scraper` → `:allm_pipeline` at all `lib/` sites
      (43 today; re-derive), including `Registry.@otp_app`
      (`registry.ex:154`) and the moduledoc `config …` examples in the same
      files.
- [ ] `dynamo.ex:66`: default table name → `"allm_pipeline_artifacts"` (C2).
- [ ] `config/test.exs`: the three `config :amesbury_scraper, …` blocks
      (lines 25, 33, 46) → `:allm_pipeline`; delete the now-false
      namespace-non-goal comment (lines 16–20); keep the table-name and
      shared-bucket notes.
- [ ] Test tree: substitute the atom everywhere (`grep -rl ':amesbury_scraper'
      test/`), flip the C3 assertions, rename the `registry_test.exs:458`
      fixture.
- [ ] Rewrite the namespace-rationale prose the rename falsifies:
      `registry.ex:143-153` ("`:amesbury_scraper` is the config namespace in
      Phase 1" section + the `@otp_app` comment), `config.ex:48`,
      `agent-spec/CODE_REVIEW.md:41`.
- [ ] `README.md:129-135`: delete the boot-notice paragraph (the notice is
      gone); `CLAUDE.md`: rewrite the §1 namespace sentence (line 46) and the
      §5 setup example (lines 198–221) to `:allm_pipeline`.

**Verification (uniform + subphase-specific).**

```bash
mix precommit
grep -rn ':amesbury_scraper' lib/ test/ config/ | wc -l       # expect 0
grep -rc ':allm_pipeline' config/test.exs                     # positive control — expect non-zero
mix test 2>&1 | grep -c 'but the application is not available' # expect 0
mix test                                                      # stack UP: no "Excluding tags"
DYNAMODB_ENDPOINT=http://127.0.0.1:9 mix test                 # stack DOWN: excluded, exit 0
```

Success: all of the above, with the two-direction pair matching `CLAUDE.md`
§4's table (0 failures both directions, 20 excluded only when down).

---

## Subphase 2 — Umbrella lockstep seam-key move

One concern: every umbrella line whose key is in C1's table moves to
`config :allm_pipeline, …` / `Application.get_env(:allm_pipeline, …)`.
`:amesbury_scraper` lines carrying the umbrella's OWN keys stay. Lands in the
same working session as subphase 1 — the path dep means the umbrella is red
between the two.

**Test plan (first).** The umbrella's own suite is the spec;
`apps/amesbury_scraper/test/amesbury/pipelines_declared_values_test.exs` and
`pipelines_test.exs:90` pin the declared values through the new namespace.

**Checklist.**

- [ ] Move the config sites listed in the Module tree (re-derive from the
      umbrella root:
      `grep -rn -E 'amesbury_scraper, (ALLM\.Pipeline|:dynamo|:repo|:alert_on_empty|:lock_keys)' config/ apps --include='*.ex' --include='*.exs'`).
- [ ] Confirm every environment that reaches DynamoDB sets `:dynamo`
      `table_name:` explicitly (prod already does:
      `config/runtime.exs:449` `env!("DYNAMODB_TABLE", :string!)`) so C2's new
      default never silently repoints a table.
- [ ] Update the wiring prose at `config/config.exs:52-55` and the comment at
      `apps/amesbury_scraper/lib/amesbury/pipelines.ex:66`.
- [ ] Update the umbrella's root `CLAUDE.md` / `apps/amesbury_scraper/CLAUDE.md`
      lines that spell the old namespace (re-derive:
      `grep -rn 'amesbury_scraper, ALLM' CLAUDE.md apps/*/CLAUDE.md`).

**Verification (from the umbrella root).**

```bash
mix precommit           # the umbrella's own gate
mix deps.compile allm_pipeline --force > /tmp/allm-compile.log 2>&1; echo "exit: $?"   # expect: exit: 0
grep -c 'Compiling' /tmp/allm-compile.log   # positive control — expect non-zero
grep -c 'warning:' /tmp/allm-compile.log    # expect 0
grep -rn -E "amesbury_scraper, (ALLM\.Pipeline|:dynamo|:repo|:alert_on_empty|:lock_keys)" config/ apps --include='*.ex' --include='*.exs' | wc -l   # expect 0
grep -rn 'config :amesbury_scraper' config/ | wc -l   # positive control — the umbrella's OWN keys remain, expect non-zero
```

Success: all green/zero as annotated; `pipelines_declared_values_test.exs`
passes untouched except namespace lines.

---

## Subphase 3 — Hexdocs-facing `lib/` prose sweep

One concern: no `Amesbury`-derived name reaches hexdocs. ~57 non-atom mentions
across 27 files today (re-derive; subphase 1 removes the other 43).

**Sweep policy** (pre-decided, so the implementer doesn't re-litigate per
site):

- A host module named as an *example* (`AmesburyScraper.Pipelines.LLM`,
  `llm.ex:18`) → a neutral `MyApp.*` example.
- A host module named as *evidence* for a design claim (the census pairs in
  `llm_step.ex:36-40`, `executor.ex:704-706`, `fan_out.ex:43-48`; the
  drift-guard note in `dynamo.ex:391-396`) → rewrite as "a consumer repo's
  census/twin test"; the concrete Amesbury pointer moves to `CLAUDE.md` if
  not already there (§1, §5, §7 already carry most — verify per site, add the
  missing ones to `CLAUDE.md`, never restate in both).
- Operator-facing strings (`s3.ex:109`, `dynamo.ex:426`: "Start the local
  stack — in the Amesbury umbrella repo…") → point at THIS repo's
  `docker-compose.yml` (which exists since Phase 8 and serves the same
  stack — `CLAUDE.md` §2).
- Host-named doc examples: `filesystem.ex:13` root, `s3.ex:27` bucket →
  neutral values.
- Comment-only mentions ("cannot `alias Amesbury.Repo` — compile error by
  design", `metrics.ex:219`, `step_log.ex:756`, `pipeline_run.ex:471`,
  `lock/advisory.ex:131`, and the house-shape cites `schema.ex:585`,
  `json_schema.ex:166`) → "a host repo module" phrasing.

**Test plan (first).** `fan_out_test.exs:124-133` already `refute`s a stale
scope line — the sweep satisfies it. Any test asserting moduledoc CONTENT is
caught by `mix precommit`; no new tests (a grep criterion, not a test, pins
the sweep — a doc-content test would duplicate it and rot).

**Checklist.**

- [ ] Apply the sweep policy to every hit of `grep -rni 'amesbury' lib/`
      (27 files today), relocating pointer-worthy facts to `CLAUDE.md`.
- [ ] Re-check `mix.exs:docs.skip_code_autolink_to` still matches reality —
      the sweep may delete a prose reference an entry exists for ("delete the
      entry rather than letting it mask a real broken reference", the list's
      own comment).

**Verification.**

```bash
mix precommit
grep -rni 'amesbury' lib/ | wc -l          # expect 0
grep -rci 'pipeline' lib/allm/pipeline.ex  # positive control — expect non-zero
mix docs 2>&1 | tail -5                    # builds clean, no autolink warnings
mix test                                   # stack UP
DYNAMODB_ENDPOINT=http://127.0.0.1:9 mix test   # stack DOWN (dynamo.ex message touched → §4 pair)
```

---

## Subphase 4 — Consumer onboarding guide + DDL shipping

One concern: a new consumer can wire a host and create the tables from the
tarball alone.

**Test plan (first).** The deliverable is docs + packaging; the observables
are `mix docs` rendering the guide and `mix hex.build` packing the files. The
migration moduledoc edit triggers its own standing rule: re-run the
schema-parity check (moduledoc lines 27–31; host twin
`AmesburyScraper.Pipeline.FrameworkBoundaryGuardsTest`).

**Checklist.**

- [ ] Write `guides/host_wiring.md` per C4 (sections 1–5; cite, don't
      restate, the moduledocs).
- [ ] `mix.exs`: add the guide to `docs.extras`; add `guides` and
      `priv/test_repo/migrations` to `package.files`.
- [ ] Migration moduledoc: add the sentence naming this file as the canonical
      DDL reference for new consumers (adoption mechanics live in the guide,
      not here).
- [ ] `README.md` "Host consumption" section: generalize to consumers-plural
      and point at the guide for new hosts.
- [ ] Re-run the schema-parity check in the umbrella (host twin above) since
      the migration file was edited.

**Verification.**

```bash
mix precommit
mix docs 2>&1 | tail -5                                    # guide renders, no warnings
mix hex.build 2>&1 | tail -20                              # succeeds
tar -tf allm_pipeline-0.1.0.tar 2>/dev/null || ls *.tar    # then:
tar -xOf allm_pipeline-*.tar contents.tar.gz | tar -tzf - | grep -E 'guides/|priv/test_repo' 
                                                           # expect both paths present
cd ~/Projects/amesbury && mix test apps/amesbury_scraper/test/amesbury_scraper/pipeline/framework_boundary_guards_test.exs
```

Success: guide + migration in the tarball listing; parity twin green.

---

## Subphase 5 — v0.1.0 release

One concern: execute `CLAUDE.md` §8's two-phase flow for the first publish.

**Preconditions (blocking, in order).**

1. Subphases 1–4 complete; `CHANGELOG.md`'s `## [REL] v0.1.0` entry updated to
   cover them — the namespace is a public-API fact and gets its own line.
2. The repo is pushed to the public remote `mix.exs:@source_url` names
   (`https://github.com/cykod/ALLM.Pipeline`) — hexdocs links and
   `package.links` dangle otherwise.
3. Hex auth per `CLAUDE.md` §8 (`~/.hex/hex.config` or `HEX_API_KEY`).
4. Service stack UP — a stack-down run makes the script's `Excluding tags`
   warning fire, which is "a weaker gate, not a pass" (`CLAUDE.md` §8).

**Test plan (first).** The release script's own gates are the test plan
(`mix precommit`'s three + `dialyzer` + `hex.build`,
`scripts/release.exs:74-76`). Expected non-failure: the migration-touch
warning WILL fire (subphase 4 edited `priv/test_repo/migrations/`,
`release.exs:381-410`) — it is satisfied by subphase 4's already-run parity
check; record that in the RECORDS file, don't suppress it.

**Checklist.**

- [ ] `mix run scripts/release.exs 0.1.0 --dry-run` — gates only
      (explicit-version path: `release.exs:306-314`; equal-to-current is
      accepted and the `@version` rewrite is a no-op).
- [ ] `mix run scripts/release.exs 0.1.0` (Phase A).
- [ ] `mix hex.publish` — by hand, real terminal (the prompts are the safety
      story; no `--yes`).
- [ ] `mix run scripts/release.exs --finalize` (Phase B: commit + tag).
- [ ] `git push origin main v0.1.0`.
- [ ] Umbrella decision recorded: stays on the path dep (see Out of scope);
      no umbrella change in this subphase.

**Verification.** Phase A output shows all gates green with only the expected
migration-touch warning; `mix hex.info allm_pipeline` returns 0.1.0;
https://hexdocs.pm/allm_pipeline renders the guide.

---

## Subphase 6 — Multi-consumer agent-doc updates

One concern: the agent docs stop describing a one-consumer world. Doc-only;
may land any time after subphase 2.

> CORRECTED 2026-08-31: this checklist's "the package is now published", the
> plural "consumer list", and "the 'Publishing trigger' sentence retires" (below)
> assumed subphases 2 and 5 had landed. In the as-built run they had NOT — publish
> (subphase 5) and umbrella lockstep (subphase 2) are DEFERRED to the host, and no
> second consumer exists. Writing "published"/plural-consumers into the governed
> docs would be a false claim, so the edits were phrased for the true current
> state (publish-ready, still one consumer, trigger REFINED not retired). Full
> reconciliation in `..._RECORDS.md` → "Subphase 6" → "KEY RECONCILIATION".

**Checklist.**

- [ ] `CLAUDE.md` header: "its one consumer" → the consumer list (and that the
      package is now published; the "Publishing trigger" sentence retires).
- [ ] `CLAUDE.md` §7 corollary: the production-declaration census runs from
      EVERY consumer repo, not "the Amesbury umbrella root" — the census
      itself is each consumer port's obligation, named in that port's design
      (not deferred to any subphase here; consumers 2/3 are out of scope).
- [ ] `agent-spec/DESIGN.md:40-41`: "the host-side production migration
      (which lives in the Amesbury repo)" → per-consumer phrasing that names
      the canonical DDL file from C4 as the source of truth.
- [ ] `README.md` intro: "remains the production consumer" → consumers-plural
      once a second consumer actually lands (leave a `TODO` only if this
      subphase closes before then — otherwise phrase it now).
- [ ] Re-run `/consolidate-agent-docs`' spirit manually: one pass over
      `CLAUDE.md` for any remaining sentence the rename or publish falsified
      (re-derive: `grep -n 'amesbury_scraper\|not published\|one consumer' CLAUDE.md`).

**Verification.**

```bash
grep -n 'amesbury_scraper' CLAUDE.md README.md agent-spec/*.md | grep -v 'was\|history\|formerly' | wc -l
# expect 0 modulo deliberate historical mentions — list survivors in RECORDS
mix precommit   # docs-only, but the gate is uniform
```

---

## Definition of Done

- All six Status rows Complete; Overall Progress 6/6.
- This repo's full gate green (`mix precommit`), plus the two-direction
  dynamo pair matching `CLAUDE.md` §4's table.
- The umbrella's gate green AND the fail-closed dep-compile check green under
  its toolchain (subphase 2's command block).
- Grep criteria hold with their positive controls: no `:amesbury_scraper` in
  this repo's `lib/ test/ config/`; no case-insensitive `amesbury` in `lib/`;
  no seam-key `amesbury_scraper` lines in the umbrella.
- `allm_pipeline 0.1.0` on Hex; hexdocs renders `guides/host_wiring.md`; the
  tarball contains the guide and the migration.
- `CHANGELOG.md` v0.1.0 entry names every public-API change (the namespace
  rename, the Dynamo default table, the shipped DDL/guide).
- `/code-review` run over subphases 1–4; security/design-review N/A per
  Overview.

## Assumptions

- The second and third consumers are new Elixir hosts wiring via
  `use ALLM.Pipeline.Registry` (not forks of the umbrella) — the guide is
  written for that shape.
- Nothing outside the two sibling checkouts consumes the package today
  (`CLAUDE.md` header: path dep, readonly mount, `vendor/` staged by
  `deploy.sh` — all the same source tree).
- Production deploys of the umbrella pick up both repos' changes together via
  `scripts/deploy.sh`'s vendor staging, so no dual-namespace window exists in
  prod.
- The GitHub remote `cykod/ALLM.Pipeline` can be made public; if it must stay
  private, subphase 5 blocks on the user (Hex docs links would dangle).
