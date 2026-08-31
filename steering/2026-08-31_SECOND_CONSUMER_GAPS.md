# Second-Consumer Gaps — Design

**Goal.** Close the framework gaps the second consumer's prerequisite list
raised that `steering/2026-08-31_MULTI_CONSUMER_HEX_PREP.md` did not receive
(P4–P9), plus a class of tarball-facing dangling reference that design's
`amesbury`-keyed sweep could not see, so the next consumer onboards from the
published package with no pointers it cannot follow and no version constraint
it did not ask for.

**Measurable outcome.** `mix deps.tree` shows no LLM-provider library;
`ALLM.Pipeline.LLM.result/0` declares the provider-usage channel and a test
pins that an envelope carrying it survives `LLMStep`; `retry_count`'s only
writer path has a test; the shipped tree names no path that does not exist in
it; and every gap the framework is not closing has a standing record naming its
trigger, in `CLAUDE.md` and in `guides/host_wiring.md`.

**Spec/plan lineage.** This is not a phase of an existing phasing doc. It
receives the second consumer's nine-item prerequisite table (measured against
`5a10b40`, transcribed in Subphase 6's response doc) for the six items
`2026-08-31_MULTI_CONSUMER_HEX_PREP.md` did **not** design: that doc's
subphases 1, 3 and 4 already closed P1, P2 and P3 (verified below), its
subphase 2 (umbrella lockstep) landed host-side 2026-08-31, and only its
subphase 5 (the v0.1.0 publish) remains, **user-gated** on the public-remote
and Hex-auth preconditions. Nothing here disturbs any of them.

**Layers touched.** `mix.exs` deps + package metadata, the `LLM` seam typespec,
`lib/` prose, one `Executor` comment, `test/`, `guides/`, `README.md`,
`CHANGELOG.md`, `CLAUDE.md`. **No schema change, no DDL change, no new seam, no
new public function.**

---

## Status

| Subphase | Concern | Status |
|---|---|---|
| 1 | Drop the unused hard `allm` dependency (P9) | Not Started |
| 2 | The LLM seam carries the provider's usage (P6) | Not Started |
| 3 | Correct the retry mechanism's prose and pin its live path (P5) | Not Started |
| 4 | Tarball-facing dangling-reference sweep (new finding) | Not Started |
| 5 | Standing records for the gaps NOT being closed (P4, P7, P8) | Not Started |
| 6 | Response doc back to the second consumer | Drafted (re-verify at close) |

Overall Progress: 0/6

Per-subphase records (deviations, verification transcripts) go to
`steering/2026-08-31_SECOND_CONSUMER_GAPS_RECORDS.md`, created on first need.

---

## Baseline — measured 2026-08-31 in this devcontainer, start-green

Run before writing this design, full service stack up:

```
$ mix compile --warnings-as-errors 2>&1 | tail -20; echo "exit: ${PIPESTATUS[0]}"
exit: 0

$ DATABASE_HOST=host.docker.internal DATABASE_USER=pascalrettig mix test 2>&1 \
    | grep -E 'Excluding tags|doctests,|failures'; echo "exit ${PIPESTATUS[0]}"
3 doctests, 600 tests, 0 failures
exit 0
```

No `Excluding tags` line — the "DynamoDB up" row of `CLAUDE.md` §4's table
(600 tests, 0 excluded), so the two-direction pair is available as a
verification observable throughout.

### What the prerequisite list already got

Re-measured against `a10d672` (the list was measured against `5a10b40`, six
commits earlier), so these need no subphase here:

| Item | Command | Result |
|---|---|---|
| P1 config namespace | `grep -rn ':amesbury_scraper' lib/ config/ test/ \| wc -l` | `0` |
| P1 (prose) | `grep -rni 'amesbury' lib/ \| wc -l` | `0` |
| P2 DDL ships | `grep -n 'files:' -A 1 mix.exs` | `~w(lib guides priv/test_repo/migrations …)` |
| P3 wiring guide | `ls guides/` | `host_wiring.md` (168 lines, 5 sections) |

---

## Overview

### Deliverables

- `mix.exs` declares no LLM-provider library (C1); `README.md` and
  `CHANGELOG.md` stop claiming one.
- `ALLM.Pipeline.LLM.result/0` declares an optional `usage:` key (C2), with a
  test pinning that `LLMStep.__call_llm__/3` passes an envelope carrying it.
- `executor.ex`'s retry comment describes the mechanism that exists (C3), and
  the caller-supplied `is_retry:` path gains its first test.
- No file shipped in the tarball names a path absent from the tarball (C4).
- `guides/host_wiring.md` gains a "Known gaps and their consumer-side answers"
  section; `CLAUDE.md` gains the matching standing records with triggers.
- `steering/2026-08-31_SECOND_CONSUMER_GAP_RESPONSE.md` — the item-by-item
  reply the user sends to the second consumer.

### Out of scope (each with justification)

- **Persisting LLM cost (P6, second half).** The user chose "widen the seam
  only". Cost columns would be a DDL change to three tables the existing host
  has already migrated, so it needs a *second* versioned migration plus a
  schema-parity re-run against the host twin — a host-side task, not an
  unavailable one (`…_HEX_PREP_RECORDS.md` → Subphase 2 records that re-run
  discharged green on 2026-08-31). It is out of scope because of the user's
  "widen the seam only" decision and the two-migration cost, not the
  environment. Recorded in subphase 5 with its trigger.
- **A DSL `retry:` construct (P5, second half).** User decision: correct the
  comment only. Reintroducing it needs a consumer production-declaration census
  (`CLAUDE.md` §7) and four constructs have already shipped green here with
  zero consumers. The caller-opt path (`Executor.run_step/5` `opts`) already
  works and gets its first test in subphase 3.
- **Resume-from-log (P4) and a run budget ceiling (P7).** User decision: record,
  don't build. Each is multi-subphase, neither blocks the second consumer, and
  each has a working consumer-side answer already named in that consumer's
  decisions (D19, D20). Subphase 5 gives each a standing record.
- **Sweeping the 90 bare `Phase N` markers in 24 `lib/` files.** They are
  maintainer provenance, not reader instructions — none tells the reader to go
  open something. Subphase 4 defines the term once in `README.md` instead, and
  the sweep's grep criterion is anchored to dangling **paths**, which is the
  class that actually breaks. (Re-derive: `grep -rn 'Phase [0-9]' lib/ | wc -l`
  → `90`, in `grep -rl 'Phase [0-9]' lib/ | wc -l` → `24` files.)
- **Removing `retry_count` from the schema/DDL.** It is a column on a table the
  host has frozen; "table names are contract" extends to not silently dropping
  columns under a live consumer. It has a live writer path (C3).
- **Changing `test/` prose.** Not hexdocs-rendered, not in `package.files`;
  its host pointers are load-bearing maintainer history (the same carve-out
  `…_HEX_PREP.md` → Out of scope already made).
- **The second consumer's own devcontainer (P8).** The readonly mount is
  declared in *that* repo's `.devcontainer/devcontainer.json`; this repo cannot
  edit it. Subphase 5 documents the constraint and the two ways out.

### Non-obvious decisions

- **Drop `{:allm, …}` rather than widen it.** Measured: `grep -rnP
  '\bALLM\.(?!Pipeline)' lib/ test/` returns **3 hits, all comments**
  (`step_log.ex:596`, `step_log.ex:609`, `encodable.ex:59` — each describing a
  `%ALLM.Engine{}` struct that arrives *from the host* inside metadata, never
  one this package builds). There is no call into the library. A hard
  requirement therefore dictates a provider-library version to every consumer
  in exchange for nothing, and widening it to `~> 0.4.2 or ~> 0.5` buys one
  release before the same edit is needed again. The dep comment's stated reason
  — "the reason for the namespace" (`mix.exs:128-129`) — is a **naming** fact,
  and a namespace is not a dependency. The `llm:` seam, which deliberately has
  no package default (`llm.ex` moduledoc, "There is no package default"), is
  the actual and only channel to a provider.
- **The usage widening is a contract change, not a behaviour change.**
  `LLMStep.__call_llm__/3` matches `{:ok, %{parsed: parsed, tokens: tokens}}`
  (`llm_step.ex:327`) — a map pattern, so an envelope with extra keys **already**
  passes today. The value of C2 is converting that accidental tolerance into a
  declared, pinned one: the regression it prevents is somebody tightening the
  pattern (an exact-map match, or a `map_size/1` guard) and breaking every host
  that started sending `usage:`. So the subphase is a typespec + doc + one test,
  and `mix dialyzer` is its extra gate because a `@type` moves.
- **The package still ignores `usage:`, and says so.** Nothing in `lib/` reads
  it. Cost stays recoverable exactly where it is recoverable today — the host
  adapter `LLMCallLog.record/1`s the full call entry, `Executor` drains it to
  the step's LLM artifact and sums `%{total_tokens: t}` out of the entries'
  `:usage` maps (`executor.ex:644-650`). C2 sanctions that channel in the
  typedoc rather than inventing a second one.
- **Dangling *paths* are the sweep criterion, not host *names*.**
  `…_HEX_PREP.md` subphase 3 swept `grep -rni 'amesbury' lib/` to zero, and
  that is still zero. It could not see this class: `steering/2026-08-10_ALLM_PIPELINE_EXTRACTION.md`,
  `.work/HANDOFF.md` and `scripts/nilability_predict.py` contain no host name,
  yet a reader of the published package cannot open any of them. Anchoring on
  the path form catches all three at once and will not rot the way a name list
  does.
- **`scripts/nilability_predict.py` does not exist in this repo at all.**
  `ls scripts/` → `release.exs`. Four `lib/` sites cite it (`schema.ex:575`,
  `allm_pipeline.nilability.ex:42,103,212`), and one of them makes it a
  load-bearing claim: the nilability task's drift-guard story calls it "a third
  copy" of the rule. That claim is unverifiable in this repo, which makes it
  the most important single fix in subphase 4.
- **The migration moduledoc's standing re-run rule gets narrowed.** It says
  "After ANY edit to this file, re-run the schema-parity queries" — which fires
  on a prose edit that cannot change a column. Subphase 4 narrows it to edits
  **inside `change/0`**, which is what the guard is actually for, and which
  stops the rule from crying wolf every time the onboarding prose improves.

### Review lanes

- `/code-review`: applies (subphases 1–4 touch `mix.exs`, `lib/` and `test/`).
- `/security-review`: **N/A** — no new runtime input handling, no auth/crypto
  surface, and the one dependency movement is a **removal**. Trigger to
  revisit: any subphase that adds a dep or reads a new external input.
- `/design-review` (visual): N/A — no frontend.

---

## Contracts

### C1 — The dependency list after subphase 1

`deps/0` declares exactly these, and no LLM-provider library:

```elixir
defp deps do
  [
    {:ecto, "~> 3.13"},
    {:ecto_sql, "~> 3.13"},
    {:postgrex, ">= 0.0.0", only: :test},
    {:jason, "~> 1.2"},
    {:telemetry, "~> 1.0"},
    {:ex_aws, "~> 2.5", optional: true},
    {:ex_aws_dynamo, "~> 4.2", optional: true},
    {:ex_aws_s3, "~> 2.5", optional: true},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:ex_doc, "~> 0.34", only: :dev, runtime: false}
  ]
end
```

The line removed is `{:allm, "~> 0.4.2"}` (`mix.exs:130`) and the three-line
comment above it (`mix.exs:128-129`). What that comment asserted stays true and
moves, rephrased, to the `llm:` seam's story: the package's centre of gravity
is LLM pipelines and that is where the **name** comes from; the **library** is
the host's choice, reached through `ALLM.Pipeline.LLM.impl/0`.

`mix.lock` loses `allm` and whichever transitives nothing else needs. Do not
carry that list here — re-derive:

```bash
git stash && mix deps.tree --format plain > /tmp/tree-before.txt; git stash pop
# after the edit:
mix deps.get && mix deps.tree --format plain > /tmp/tree-after.txt
diff /tmp/tree-before.txt /tmp/tree-after.txt
```

Note `ex_aws` declares `req` as `optional: true` (`mix.lock:10`), so `req` is
pulled today only by `allm` — expect it and `finch` to leave, and expect
`jason`, `telemetry` and `mime` to stay (direct dep, direct dep, `ex_aws`
non-optional respectively).

**No consumer breaks.** A host that uses `allm` declares it itself; a host that
does not is no longer made to resolve it. The package is unpublished
(`CLAUDE.md` header), so this is an edit to the v0.1.0 entry, not a breaking
change to a released version.

### C2 — The LLM seam's success envelope

```elixir
@typedoc """
The host's structured-output envelope.

`parsed` is the decoded JSON object with **string** keys —
`ALLM.Pipeline.LLMStep`'s `coerce/2` reads it by wire property name.
`tokens` is the call's total token count.

`usage` is OPTIONAL and the sanctioned channel for anything richer the
provider reports — per-direction token counts, USD cost, a served model.
The package does **not** read it: nothing in `lib/` inspects the key, and
`LLMStep.__call_llm__/3` forwards only `parsed` and `tokens` to `coerce/2`.
It is declared so a host adapter can carry provider usage through the seam
without the envelope becoming an undeclared shape, and so this envelope
stays open to extra keys by contract rather than by accident.

Where richer usage actually becomes durable: a host adapter passes the same
information to `ALLM.Pipeline.LLMCallLog.record/1`, which the `Executor`
drains into the step's LLM artifact and sums for
`step_logs.llm_total_tokens`. There is no cost COLUMN — see
`guides/host_wiring.md`, "Known gaps".
"""
@type result ::
        {:ok,
         %{
           :parsed => map(),
           :tokens => non_neg_integer(),
           optional(:usage) => map()
         }}
        | {:error, term()}
```

`@callback generate_structured/4`'s return is unchanged (`:: result()`), and no
function body changes. `resolve_engine/1`, `impl/0` and every raise message are
untouched.

**Error contract table.** N/A for this design — no validator-shaped module is
added or changed, and no function gains or loses an error reason. The only
error-adjacent edit is C3's comment.

### C3 — What `is_retry:` actually is

`executor.ex:505-515` currently asserts:

> `ALLM.Pipeline.Dsl.Runtime` sets it from the second attempt of a `retry:`
> declaration (Phase 4 D11) …

Measured false: `grep -rn 'is_retry' lib/ test/` returns **3 hits, all readers**
— `executor.ex:511` (the comment), `executor.ex:525` (`opts[:is_retry]` handed
to the store), `step_log.ex:271` (`retry_count + if(opts[:is_retry], do: 1, else: 0)`).
There is no writer, in `lib/` or `test/`, and the `retry:` DSL option was
removed in Phase 5.10.

What IS true, and what the corrected comment must say:

- `is_retry:` is a **caller-supplied** option. `Executor.run_step/5` takes
  `opts` (`executor.ex:153`) and threads it unchanged to `execute_step/5` →
  `handle_failure/3` → `store().log_step_failure/3`.
- Therefore `step_logs.retry_count` is `0` for every in-tree caller, and a
  consumer that re-invokes a step with `is_retry: true` is the only thing that
  moves it. That is the documented consumer-side answer, and it belongs in the
  guide (subphase 5), not only in a comment.
- The column is kept, not dropped: it has a live writer path, and it is on a
  frozen host table.

### C4 — Nothing shipped names a path absent from the tarball

`package.files` is
`~w(lib guides priv/test_repo/migrations .formatter.exs mix.exs README.md CHANGELOG.md LICENSE CLAUDE.md)`
(`mix.exs:56-57`). After subphase 4, for the tarball-shipped tree **excluding**
`CLAUDE.md` (which is the maintainer's file and deliberately names the
originating host):

```bash
grep -rnE '(^|[^A-Za-z0-9_/])(steering|\.work|scripts)/[A-Za-z0-9_.-]+' \
     lib guides priv/test_repo/migrations mix.exs README.md CHANGELOG.md | wc -l
# expect 0 — except `scripts/release.exs`, which README.md documents and which
# exists in the repo (it is dev tooling, not tarball content; the criterion in
# subphase 4 excludes it explicitly and pastes the exclusion).
```

Current measurement (2026-08-31, `a10d672`), by class:

| Class | Sites | Files | Command |
|---|---|---|---|
| A1 — `steering/*.md` | 9 | 4 | `grep -rn 'steering/' lib/` |
| A2 — `.work/*` | 6 | 4 | `grep -rn '\.work/' lib/` |
| A3 — `scripts/nilability_predict.py` (**absent from the repo**) | 4 | 2 | `grep -rn 'nilability_predict' lib/` |
| B — bare `LLMEngine.*` (a host module, unqualified) | 4 | 4 | `grep -rn 'LLMEngine' lib/ \| grep -v MyApp` |
| C — "root `CLAUDE.md`" (means the **host's**, not this repo's) | 4 | 4 | `grep -rn 'root .CLAUDE.md.' lib/` |
| D — `amesbury` in shipped non-`lib` files | 5 + 4 | `mix.exs`, the migration | `grep -ni amesbury mix.exs priv/test_repo/migrations/*` |

**Sweep policy, pre-decided per class** (so the implementer re-litigates
nothing):

- **A1/A2** — the path is provenance for a design claim. Inline the claim's
  load-bearing fact, drop the path. Where the fact is already in `CLAUDE.md`,
  point there ("this repo's `CLAUDE.md`") and drop the path; never restate in
  both.
- **A3** — the strongest case. `schema.ex:575` and
  `allm_pipeline.nilability.ex:42` build the deliberate-mirror argument on a
  file that does not exist here. Rewrite both to the mirrors that DO exist and
  are pinned: `Schema`'s private copy, the task's `nilable_tail?/1`, and
  `Schema.JsonSchema.strip_nil/1` — three, all in-tree, all covered by the
  "drift guard" describe in `test/mix/tasks/allm_pipeline_nilability_test.exs`.
  Correct the count in the same edit ("a fourth" → the in-tree set).
- **B** — `LLMEngine` unqualified reads as a package module and autolinks to
  nothing. Rewrite to "the host's LLM engine" (or `MyApp.LLMEngine` where the
  site is an example), matching what `llm.ex:7` already does.
- **C** — inline the quoted rule; drop the pointer. Each of the four sites
  quotes a one-line house rule already.
- **D** — the migration's four are the priority: it is the file a new consumer
  **copies**, and it tells them to compare against
  `apps/amesbury/priv/repo/migrations/`, a path they do not have. Rewrite as
  "the originating host's frozen migrations" with the four migration names kept
  (they are the transcription's provenance and are meaningful as names).
  `mix.exs:30`'s `AmesburyScraper.Application` reference is host history with no
  external meaning — rewrite. `mix.exs:95-99` **stays**: it is the compile-
  boundary rule stated with a concrete example, the same shape `CLAUDE.md` §1
  ships deliberately.

### DDL

**No schema change.** `priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs`
receives moduledoc edits only (subphase 4, class D and the narrowed re-run
rule). Its standing rule fires on the letter of "ANY edit"; subphase 4 both
defers the re-run **to the next host-side session** (the sibling
`~/Projects/amesbury` is not mounted in this devcontainer) and narrows the rule
so a prose edit stops triggering it. Precedent, not hope:
`…_HEX_PREP_RECORDS.md` → Subphase 2 → "Deferred subphase-4 parity re-run —
DISCHARGED" records the identical moduledoc-only edit re-run green host-side.
Safe by construction: `change/0` is not touched, verified by the diff criterion
in subphase 4's Verification block.

---

## Module tree

No NEW `lib` modules, no NEW test files except one.

**NEW**
- `steering/2026-08-31_SECOND_CONSUMER_GAP_RESPONSE.md` (— 6). `ls steering/`
  → the two `…_HEX_PREP*` files only; the name is free.
- `steering/2026-08-31_SECOND_CONSUMER_GAPS_RECORDS.md` (— on first need).
- `test/allm/pipeline/llm_seam_test.exs` (NEW — 2) — the C2 pin. `ls
  test/allm/pipeline/` before locking the name in; if a suitable home already
  exists (`llm_step_test.exs` holds the `__call_llm__/3` cases), fold the
  describe in there instead and record the choice. Prefer folding: one seam,
  one file.

**MODIFY — subphase 1**
- `mix.exs` — `deps/0` (C1), the comment at `:128-129`.
- `README.md:26-28` — "on top of [`allm`](https://hex.pm/packages/allm)" is
  now false for the package's dep list; rephrase to the `llm:` seam.
  (`README.md:89`, the release-script reference to the ALLM repo, is a
  provenance link about tooling and stays.)
- `CHANGELOG.md:16` — "`use ALLM.Pipeline.LLMStep` … on top of `allm`" → the
  seam phrasing; add the dep-list line (see Definition of Done).

**MODIFY — subphase 2**
- `lib/allm/pipeline/llm.ex` — the `result` typedoc + `@type` (C2). The
  moduledoc's "The success shape is the host's, unchanged" section gains the
  `usage:` sentence.
- `test/allm/pipeline/llm_step_test.exs` (or the NEW file) — the pin.

**MODIFY — subphase 3**
- `lib/allm/pipeline/executor.ex:505-515` — the comment (C3).
- `lib/allm/pipeline/step_log.ex:258-260` — `log_failure/3`'s `@doc` gains one
  sentence naming `is_retry:` as a caller opt (it currently documents neither
  the option nor the column).
- `test/allm/pipeline/executor_test.exs` — the first `is_retry:` test.

**MODIFY — subphase 4** — re-derive the file set, don't trust this list:

```bash
grep -rlE '(steering|\.work|scripts)/[A-Za-z0-9_.-]+|LLMEngine|root .CLAUDE\.md.' lib/
grep -lni amesbury mix.exs priv/test_repo/migrations/*
```

Measured today that is `lib/allm/pipeline/{text,pipeline_metric,executor,step_log,context,pipeline_run,encodable,schema,llm_call_log,dsl,store,llm}.ex`,
`lib/allm/pipeline.ex`, `lib/allm/pipeline/dsl/resource.ex`,
`lib/allm/pipeline/schema/json_schema.ex`,
`lib/mix/tasks/allm_pipeline.nilability.ex`, plus `mix.exs` and the migration.
`README.md` gains the one-paragraph provenance note defining "Phase N".

**MODIFY — subphase 5**
- `guides/host_wiring.md` — NEW section 6, "Known gaps and their consumer-side
  answers" (the guide has 5 sections today, `grep -n '^#' guides/host_wiring.md`).
- `CLAUDE.md` — the standing records with triggers.
- `README.md` — the readonly-mount operator note (P8).

**MODIFY — subphase 6**
- `steering/2026-08-31_MULTI_CONSUMER_HEX_PREP.md` — nothing. Its Status table
  is that design's; this design does not edit it.

---

## Subphase 1 — Drop the unused hard `allm` dependency

One concern: the package stops constraining a consumer's provider-library
version (C1). Behaviour-preserving by construction — there is no call site to
break.

**Test plan (first).** The existing 600-test suite is the spec: if any code
path reached `allm`, removing the dep fails compilation or a test. The
discriminating observable is the **positive control** — the grep that proves
the three surviving mentions are comments, run before and after.

**Checklist.**

- [ ] Confirm the premise fail-closed, and paste the output:
      `grep -rnP '\bALLM\.(?!Pipeline)' lib/ test/` → expect exactly 3 lines,
      each inside a `#` comment or a `@moduledoc`/`@doc` (read them; do not
      count).
- [ ] Capture `mix deps.tree --format plain` BEFORE the edit (C1's command).
- [ ] Remove `{:allm, "~> 0.4.2"}` and its comment (`mix.exs:128-130`); fold
      the namespace rationale into the neighbouring prose without leaving a
      dangling "the reason for the namespace" claim on a dep that is gone.
- [ ] `mix deps.get` (prunes `mix.lock`); diff the two dep trees and record the
      pruned set in RECORDS — do not assert a list in this design.
- [ ] `README.md:26-28` and `CHANGELOG.md:16`: replace "on top of `allm`" with
      the `llm:`-seam phrasing (the host names its own provider library).
- [ ] Re-read `mix.exs`'s `application/0` and `docs/0` for any `:allm`
      assumption (`grep -n 'allm[^_]' mix.exs`, expecting only `allm_pipeline`
      and `AllmPipeline` hits).

**Verification.**

```bash
mix precommit
mix dialyzer                                             # dep graph moved
grep -rnP '\bALLM\.(?!Pipeline)' lib/ test/ | wc -l      # expect 3 (all comments — read them)
grep -c '{:allm,' mix.exs                                # expect 0
grep -c '"allm":' mix.lock                               # expect 0
grep -c '"ecto":' mix.lock                               # positive control — expect 1
mix deps.tree --format plain | grep -c '^allm '          # expect 0
mix test                                                 # stack UP: 600 tests, no "Excluding tags"
DYNAMODB_ENDPOINT=http://127.0.0.1:9 mix test            # stack DOWN: 20 excluded, exit 0
```

Success: gate green, both dynamo directions matching `CLAUDE.md` §4's table,
and a fresh `rm -rf deps _build && mix deps.get && mix test` green (proves the
lock prune is coherent, not just the warm build).

---

## Subphase 2 — The LLM seam carries the provider's usage

One concern: the envelope's openness to provider usage becomes a declared,
tested contract (C2). No function body changes.

**Test plan (first) — written before the typespec.** One describe, three cases,
against a stub adapter installed and restored per `CLAUDE.md` §5 (`async:
false`, save/restore `Application.get_env(:allm_pipeline, ALLM.Pipeline.LLM)`):

1. **An envelope carrying `usage:` reaches `coerce/2` unchanged.** A stub
   returning `{:ok, %{parsed: %{"name" => "x"}, tokens: 7, usage: %{total_cost: 0.002}}}`
   drives `LLMStep.__call_llm__/3` to `{:ok, %{"name" => "x"}, 7}`. This is the
   regression pin: it fails the moment somebody tightens `llm_step.ex:327` to
   an exact-map match.
2. **An envelope WITHOUT `usage:` is still valid.** The key is optional; the
   existing shape must not become a dialyzer error for a host that never sends
   it.
3. **The package does not leak `usage:` into the Output.** The generated
   `coerce/2` receives `(parsed, tokens)` only, so the key must not appear in
   the resulting Output struct — asserted, because the alternative reading
   ("usage flows through to the step") is the one a reader would guess.

**Checklist.**

- [ ] Decide the test home: fold into `test/allm/pipeline/llm_step_test.exs` if
      its `__call_llm__/3` describes exist (check first); otherwise the NEW
      file. Record the choice.
- [ ] Write the three cases; watch case 1 pass on today's code (the map pattern
      already tolerates it) — that is expected, and the test's job is the
      FUTURE tightening, so state that in the describe name.
- [ ] Apply C2's `@typedoc` + `@type` to `lib/allm/pipeline/llm.ex`.
- [ ] Add the `usage:` sentence to the moduledoc's "The success shape is the
      host's, unchanged" section — it currently says the seam "relocates the
      call; it does not redefine it", which the optional key must not appear to
      contradict.
- [ ] `mix dialyzer` — a `@type` in a `@callback`'s return moved; this is the
      subphase where it can actually fail.
- [ ] Cross-reference: `guides/host_wiring.md` §2 (the `llm:` seam) gains one
      line pointing at the typedoc for the envelope; the cost story itself goes
      in subphase 5's §6, not here.

**Verification.**

```bash
mix precommit
mix dialyzer                                        # expect: done (no warnings)
mix docs 2>&1 | tail -5                             # typedoc renders, no autolink warnings
grep -n 'optional(:usage)' lib/allm/pipeline/llm.ex # expect 1
grep -c 'parsed:' lib/allm/pipeline/llm.ex          # positive control — expect non-zero
mix test test/allm/pipeline/llm_step_test.exs
mix test
```

Success: all green; the three new cases pass; dialyzer clean.

---

## Subphase 3 — Correct the retry prose and pin its live path

One concern: `retry_count`'s mechanism is described accurately and exercised
once (C3). No behaviour change.

**Test plan (first).** `grep -rn 'is_retry' test/` returns **0** today — the
option has never been tested. Two cases, DB-backed (sandbox checkout per
`CLAUDE.md` §3):

1. A failing step run via `Executor.run_step/5` with `is_retry: true` writes
   `retry_count: 1` on its step log.
2. The same step run **without** the option writes `retry_count: 0`.

Two cases rather than one, because case 1 alone passes against a hypothetical
`retry_count: 1` hardcode; the pair is the discriminating observable for
`step_log.ex:271`'s conditional.

**Checklist.**

- [ ] Write both cases against an existing failing-step fixture in
      `test/allm/pipeline/executor_test.exs` (reuse; do not add a Step module
      if one already fails on demand).
- [ ] Rewrite `executor.ex:505-515` per C3: `is_retry:` is a caller option, no
      in-tree writer, `retry_count` is `0` for every in-tree caller, and the
      `retry:` DSL construct that the old text named was removed in Phase 5.10.
      Do not restate the consumer-side pattern here — it goes in the guide
      (subphase 5); name the guide instead.
- [ ] Add one sentence to `StepLog.log_failure/3`'s `@doc` naming `:is_retry`
      and `:llm_info` as the two options it reads (it documents neither today).
- [ ] Re-derive the claim after the edit: `grep -rn 'is_retry' lib/ test/` must
      now show the two new test writers alongside the three readers.
- [ ] Check no other `lib/` comment repeats the removed-`retry:` claim:
      `grep -rn 'retry' lib/ | grep -iv 'retry_count\|is_retry\|retry policy'`.

**Verification.**

```bash
mix precommit
grep -rn 'is_retry' test/ | wc -l                    # expect non-zero (was 0)
grep -rn 'Dsl.Runtime sets it' lib/ | wc -l          # expect 0 — the false claim is gone
grep -rn 'is_retry' lib/ | wc -l                     # positive control — expect 3
mix test test/allm/pipeline/executor_test.exs
mix test
```

Success: gate green; the pair of retry cases discriminates (flip
`step_log.ex:271`'s `if` to a constant locally and confirm one of the two goes
red, then revert — record the transcript).

---

## Subphase 4 — Tarball-facing dangling-reference sweep

One concern: nothing shipped names a path the reader does not have (C4).
Doc-only, no code change — but it touches `lib/` moduledocs, so `mix precommit`
and `mix docs` are both real gates.

**Test plan (first).** The criterion is a grep, not a test — a doc-content test
would duplicate it and rot (the same reasoning `…_HEX_PREP.md` subphase 3 used).
Every emptiness check below ships its positive control. The one behavioural
observable is `mix docs` building with no autolink warnings after class B's
`LLMEngine` references are rewritten.

**Checklist.**

- [ ] **Class A3 first** (the load-bearing one): rewrite `schema.ex:575` and
      `allm_pipeline.nilability.ex:42,103,212` to the in-tree mirror set, and
      correct the count. Verify the corrected set against
      `test/mix/tasks/allm_pipeline_nilability_test.exs`'s drift-guard describe
      — the doc must name what the test actually compares.
- [ ] Classes A1 + A2: relocate or inline each of the 15 sites per the policy;
      where `CLAUDE.md` already carries the fact, point at it and delete the
      path.
- [ ] Class B: the 4 bare `LLMEngine.*` sites → host-engine phrasing.
- [ ] Class C: the 4 "root `CLAUDE.md`" sites → inline the quoted rule.
- [ ] Class D: the migration moduledoc's 4 sites (priority — it is the copied
      file) and `mix.exs:30`. Leave `mix.exs:95-99`.
- [ ] Narrow the migration's standing re-run rule to edits inside `change/0`,
      and carry the deferral: the schema-parity re-run needs the sibling host
      repo, absent from this devcontainer. Discharge it in the next host-side
      session, the way `…_HEX_PREP_RECORDS.md` → Subphase 2 discharged the
      identical one.
- [ ] `README.md`: add the one-paragraph provenance note defining what "Phase
      N" refers to, so the 90 markers left in place resolve for a reader.
- [ ] Re-check `mix.exs:docs.skip_code_autolink_to` — the sweep may delete a
      prose reference an entry exists for ("delete the entry rather than
      letting it mask a real broken reference", the list's own comment).

**Verification.**

```bash
mix precommit
mix docs 2>&1 | tail -10                             # no autolink / broken-ref warnings

# C4's criterion, with scripts/release.exs excluded (it exists and is documented).
# Executed 2026-08-31 at a10d672 BEFORE the sweep: returns 15 (the 9 + 6 of
# classes A1/A2), so the criterion is discriminating, not vacuously empty.
grep -rnE '(^|[^A-Za-z0-9_/])(steering|\.work)/[A-Za-z0-9_.-]+' \
     lib guides priv/test_repo/migrations mix.exs README.md CHANGELOG.md | wc -l   # expect 0
grep -rn 'nilability_predict' lib/ | wc -l                                          # expect 0
grep -rn 'LLMEngine' lib/ | grep -v MyApp | wc -l                                   # expect 0
grep -rn 'root .CLAUDE.md.' lib/ | wc -l                                            # expect 0
grep -ni amesbury priv/test_repo/migrations/* | wc -l                               # expect 0

# positive controls — these must stay non-zero, or the greps are matching nothing.
# Executed 2026-08-31 at a10d672: 5, non-zero, 5 respectively.
grep -rn 'scripts/release.exs' README.md | wc -l      # expect non-zero (documented, exists)
grep -rnc 'CLAUDE.md' lib/ | wc -l                    # expect non-zero (in-repo pointers remain)
grep -c 'Phase 8' CLAUDE.md                           # expect non-zero

# DDL untouched, proving the parity deferral is safe by construction:
git diff priv/test_repo/migrations/ | grep -E '^[+-]' | grep -vE '^[+-][+-]' \
  | grep -vE '^[+-]\s*(#|\*|\||$)' | grep -E 'add |create |alter |table\(' | wc -l   # expect 0
# (Executed on the clean tree at a10d672: 0. Confirm it is still 0 with the
#  moduledoc edits staged — that is the whole point of the check.)

mix test
DYNAMODB_ENDPOINT=http://127.0.0.1:9 mix test         # dynamo.ex prose touched → §4 pair
```

Success: every zero holds with its control non-zero; the DDL-body diff is
empty; both dynamo directions match `CLAUDE.md` §4.

---

## Subphase 5 — Standing records for the gaps NOT being closed

One concern: every gap this design declines to build has one written home with
a trigger, so the next consumer finds the answer instead of re-measuring it.
Doc-only; may land any time after subphase 3.

**Test plan (first).** No test. The observables are `mix docs` rendering the new
guide section and the grep criteria below. The correctness criterion is
**non-duplication**: each fact lives in exactly one of `guides/host_wiring.md`
(consumer-facing) or `CLAUDE.md` (maintainer-facing), with the other pointing.

**Checklist.**

- [ ] `guides/host_wiring.md` §6, "Known gaps and their consumer-side answers"
      — one short subsection each, consumer-facing:
      - **Resume does not replay** (P4). `Executor.resume/2` validates the step
        and sets `:running`; it restores no output and skips no step, and its
        handle is non-owning (both already in its `@doc`). Consumer answer:
        detect the gap and re-drive, calling
        `PipelineRun.assume_ownership/1` before finishing.
      - **No run budget ceiling** (P7). Consumer answer: enforce it in a
        fan-out body against the running token total.
      - **Cost is not a column** (P6). Consumer answer: carry it on the
        `LLMCallLog` entry (which reaches the step's LLM artifact); the seam's
        `usage:` key from subphase 2 is the envelope channel.
      - **`retry_count` has no in-tree writer** (P5). Consumer answer: override
        `execute/2` and pass `is_retry: true` to `Executor.run_step/5`.
- [ ] `CLAUDE.md` — the maintainer half: each gap's **trigger** for becoming
      work here (resume-from-log: a consumer needs replay; budget: a second
      consumer wants it, matching the §7 "four constructs shipped green with
      zero consumers" lesson; cost columns: a consumer needs USD *queryable*,
      which is a second migration plus a parity re-run).
- [ ] `README.md` — the P8 operator note: a consumer that bind-mounts this repo
      **readonly** into its own devcontainer cannot run this suite there
      (`_build` is unwritable) and cannot fix anything upstream from it. The
      two ways out: drop `readonly` from that mount (a container **rebuild**,
      not a restart) or work from this repo's own devcontainer. Frame it as a
      constraint of the consuming container, not a bug here — this repo does
      not declare that mount.
- [ ] Verify non-duplication: each fact in one file, the other pointing.

**Verification.**

```bash
mix precommit
mix docs 2>&1 | tail -5
grep -n '^## ' guides/host_wiring.md                  # expect a 6th section
grep -c 'readonly' README.md                          # expect non-zero
grep -c 'resume' guides/host_wiring.md                # expect non-zero
grep -c 'resume' CLAUDE.md                            # expect non-zero (the trigger half)
```

Success: guide renders with 6 sections; each gap findable from both the
consumer's and the maintainer's entry point, stated once.

---

## Subphase 6 — Response doc back to the second consumer

One concern: the second consumer gets one document answering all nine items
with a disposition and, where the answer is "not building it", the reason and
the trigger. Doc-only.

> **DRAFTED AHEAD, 2026-08-31.** The user asked for the response doc at design
> time, so `steering/2026-08-31_SECOND_CONSUMER_GAP_RESPONSE.md` already exists
> and is sendable now. Its P1/P2/P3 rows are facts (re-measured at `a10d672`,
> output pasted); its P5/P6/P9 rows are **decisions with a named landing
> subphase**, and the doc says so rather than claiming them done. This
> subphase's checklist therefore becomes a **re-verification pass** run when
> subphases 1–5 close: flip the three "landing in subphase N" rows to "landed
> in commit X", re-run the Verification block, and confirm nothing in the doc
> is now false.

**Test plan (first).** No test. The criterion is **coverage and honesty**: nine
items in, nine dispositions out, each carrying the commit or the subphase that
delivered it, and each "done" claim re-measured at write time rather than
copied from a checklist.

**Checklist.**

- [x] Write `steering/2026-08-31_SECOND_CONSUMER_GAP_RESPONSE.md`: one row per
      P1–P9, columns *item / disposition / where it landed / what the consumer
      does now*. (Done 2026-08-31 at `a10d672`.)
- [x] Re-measure each "done" claim at write time and paste the command output —
      P1/P2/P3 against the current HEAD, not against `5a10b40`.
- [ ] **At close:** flip the P5/P6/P9 rows from "new design subphase N" to the
      commit that landed each, and re-run every command in the Verification
      block below against the new HEAD.
- [ ] State plainly what is **not** being built and why (P4, P7, cost columns,
      a `retry:` construct), each with the trigger that would change the
      answer. A deferral with no named trigger is an oversight.
- [ ] Restate the one thing the consumer flagged as "not a bug" — `LLM.impl/0`
      raising when unwired — as confirmed deliberate, so the next reader does
      not reopen it.
- [x] Name the one row of `…_HEX_PREP.md` still open — subphase 5, the v0.1.0
      Hex publish, **user-gated** (subphase 2's umbrella lockstep landed
      host-side 2026-08-31) — so the consumer knows the package is still a path
      dep, not a Hex release.
- [ ] Close on the publishing trigger: `CLAUDE.md`'s header says "a second
      consumer, or the user asks" — the second consumer now exists, so the
      response asks the user to schedule the publish rather than assuming it.

**Verification.**

```bash
# Every "done" claim re-measured, output pasted into the doc:
grep -rn ':amesbury_scraper' lib/ config/ test/ | wc -l   # P1 — expect 0
grep -rni 'amesbury' lib/ | wc -l                         # P1 prose — expect 0
grep -n 'files:' -A 1 mix.exs                             # P2 — guides + priv/test_repo/migrations
ls guides/                                                # P3 — host_wiring.md
grep -c '{:allm,' mix.exs                                 # P9 — expect 0 after subphase 1
grep -n 'optional(:usage)' lib/allm/pipeline/llm.ex       # P6 — expect 1
grep -rn 'is_retry' test/ | wc -l                         # P5 — expect non-zero
```

Success: nine dispositions, each verified at write time; no claim in the
response doc that a command above contradicts.

---

## Definition of Done

- All six Status rows Complete; Overall Progress 6/6.
- `mix precommit` green, plus `mix dialyzer` clean (subphases 1 and 2 move the
  dep graph and a `@type`).
- The two-direction dynamo pair matches `CLAUDE.md` §4's table (600 tests /
  0 failures up; 0 failures + 20 excluded + the operator message down) — re-run
  after subphases 1 and 4, both of which touch code the probe path reaches.
- A cold build is green: `rm -rf deps _build && mix deps.get && mix test`.
- Every grep criterion in the Verification blocks holds **with its positive
  control non-zero**.
- `mix docs` builds with no autolink or broken-reference warnings, and
  `guides/host_wiring.md` renders 6 sections.
- `@spec` + doc on every new public function: **N/A — none is added.** The one
  `@type` change (C2) carries a `@typedoc`.
- Round-trip test per serializable struct: **N/A — no struct changes.**
- `CHANGELOG.md`'s v0.1.0 entry names every public-API change this design
  makes: the dropped `allm` dependency, the widened `LLM.result/0` envelope.
  (It is a pre-publish edit to an unreleased entry, not a new version.)
- `/code-review` run over subphases 1–4; security/design-review N/A per
  Overview.
- The response doc exists and every "done" claim in it was re-measured at write
  time.

## Assumptions

- The second consumer's nine-item table was measured against `5a10b40`; this
  design re-measured P1/P2/P3 against `a10d672` and found them closed. If the
  consumer re-measures against an older checkout it will disagree — the
  response doc names the commit.
- The sibling host repo (`~/Projects/amesbury`) is **not** reachable from this
  devcontainer, so subphase 4's schema-parity re-run is deferred to a host-side
  session. Subphase 4 does not touch `change/0` and its DDL-body diff criterion
  proves it — which is why the identical deferral in the prior design came back
  green (`…_HEX_PREP_RECORDS.md` → Subphase 2).
- Nothing outside the two sibling checkouts consumes the package today, so
  removing the `allm` dependency cannot break a released consumer — the package
  is unpublished.
- The second consumer writes its own LLM adapter (its D17) and is not waiting
  on a package default; `LLM.impl/0` raising when unwired stays deliberate.
