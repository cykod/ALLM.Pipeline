# ALLM.Pipeline — response to the second consumer's prerequisite list

**To.** The `life-skills` / second-consumer port.
**From.** `ALLM.Pipeline`, measured at `a10d672` (2026-08-31).
**Re.** "Upstream prerequisites — what ALLM.Pipeline must ship first", nine
items measured against `5a10b40`.

Your list arrived three commits before
`steering/2026-08-31_MULTI_CONSUMER_HEX_PREP.md` finished landing, so **all
three of your BLOCKING framework items (P1, P2, P3) are already closed** —
re-measured below at `a10d672`, not recalled. The remaining six have
dispositions, and where the answer is "we are not building it", the trigger
that would change that answer is named.

Two things you should carry into your phasing before anything else:

1. **P1–P3 are done.** Phase `life-skills` against `:allm_pipeline`, the shipped
   DDL, and `guides/host_wiring.md` — not against the state your table
   measured.
2. **The package is still unpublished and still a path dep.** `…_HEX_PREP.md`
   is 5/6: subphase 2 (the umbrella's lockstep config move) landed host-side on
   2026-08-31 with the umbrella's gate green, and the only remaining row is
   subphase 5, the v0.1.0 Hex publish — **user-gated**, on a public remote and
   Hex auth, not blocked on any engineering. You are the second consumer whose
   existence is the publishing trigger, so it is now a scheduling question.
   Until it runs, `life-skills` consumes a path dep, same as the umbrella.

---

## Dispositions

| # | Item | Disposition | Where | What you do now |
|---|---|---|---|---|
| **P1** | Config namespace was `:amesbury_scraper` | **DONE** | commit `2deb2c4`, `…_HEX_PREP.md` subphase 1 | Write every `life-skills` config line under `:allm_pipeline`. Framework raise messages now name it too. |
| **P2** | No production DDL ships | **DONE** | commit `ebf68aa`, subphase 4 | `priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs` is in `package.files`; copy it into your `priv/repo/migrations/` and freeze the table names. Its moduledoc prose is being de-host-ified (new design, subphase 4) — the DDL body is final. |
| **P3** | No host-wiring guide | **DONE** | commit `ebf68aa`, subphase 4 | `guides/host_wiring.md`, 5 sections: registry wiring, the optional `llm:` seam, DDL adoption, artifact infrastructure, the consumer test-suite pattern. A 6th, "Known gaps", is coming (below). |
| **P9** | `{:allm, "~> 0.4.2"}` excludes your 0.5.0 | **ACCEPTED — going further than you asked** | new design subphase 1 | The dep is being **removed**, not widened. Measured: zero code references in `lib/` or `test/` (see below). Declare whatever `allm` version you want; the package will not constrain it. Until it lands, a recorded `override:` in your `mix.exs` is correct. |
| **P6** | LLM seam discards cost | **ACCEPTED, seam only** | new design subphase 2 | `LLM.result/0` gains `optional(:usage) => map()` — the sanctioned channel for provider usage through the seam. **No cost column.** Keep recording cost onto the `LLMCallLog` entry; that is the durable path and it stays the answer. |
| **P5** | No retry, and a comment says otherwise | **ACCEPTED, comment only** | new design subphase 3 | The comment is being corrected and `is_retry:` gains its first test. Your workaround is confirmed correct and is being written into the guide: override `execute/2`, pass `is_retry: true` to `Executor.run_step/5`. No `retry:` DSL construct is returning. |
| **P4** | `Executor.resume/2` does not replay | **DECLINED for now, recorded** | new design subphase 5 | Your D19 stays the answer. Resume-from-log (step fingerprints, replaying a `:success` log) is unbuilt and stays unbuilt. |
| **P7** | No run-level budget ceiling | **DECLINED for now, recorded** | new design subphase 5 | Your D20 stays the answer — enforce it in a fan-out body. |
| **P8** | The mount is readonly | **NOT OURS TO FIX, documented** | new design subphase 5 | The `readonly` flag is declared in **your** `.devcontainer/devcontainer.json`, not ours. Drop it there (needs a container **rebuild**, not a restart), or work from this repo's own devcontainer. `README.md` will state the constraint. |

---

## The measurements, re-run at `a10d672`

Not copied from a checklist — executed while writing this.

```
$ git rev-parse --short HEAD
a10d672

$ grep -rn ':amesbury_scraper' lib/ config/ test/ | wc -l
0                                     # P1 — was 43 in lib/ alone

$ grep -rni 'amesbury' lib/ | wc -l
0                                     # P1 prose — hexdocs is host-neutral

$ grep -n 'files:' -A 1 mix.exs       # P2
56:      files:
57-        ~w(lib guides priv/test_repo/migrations .formatter.exs mix.exs README.md CHANGELOG.md LICENSE CLAUDE.md)

$ ls guides/                          # P3
host_wiring.md

$ grep -c '^## ' guides/host_wiring.md
5
```

And the evidence behind the P9 decision — the reason we are removing the dep
rather than widening it:

```
$ grep -rnP '\bALLM\.(?!Pipeline)' lib/ test/
lib/allm/pipeline/encodable.ex:59:  and `%ALLM.Engine{}` (the most plausible carrier) holds no `:api_key` in its
lib/allm/pipeline/step_log.ex:596:  # - `:engine` — a transient `%ALLM.Engine{}` injected into some extractor
lib/allm/pipeline/step_log.ex:609:  # `__meta__` and `%NotLoaded{}` placeholders, `%ALLM.Engine{}`), and the depth
```

Three hits, all comments, all describing a struct that arrives **from the
host** inside step metadata. The package never calls into `allm`. A hard
requirement was therefore dictating a provider-library version to every
consumer in exchange for nothing. The dep comment's stated reason — "the reason
for the namespace" — is a naming fact; a namespace is not a dependency. The
`llm:` seam is the actual and only channel to a provider.

Your P5 measurement, confirmed and sharpened:

```
$ grep -rn 'is_retry' lib/ test/
lib/allm/pipeline/step_log.ex:271:      retry_count: step_log.retry_count + if(opts[:is_retry], do: 1, else: 0)
lib/allm/pipeline/executor.ex:511:  # here: `:is_retry`, which `StepLog.log_failure/3` turns into `retry_count`.
lib/allm/pipeline/executor.ex:525:           is_retry: opts[:is_retry]
```

Three readers, zero writers, zero tests — you had this right. One correction to
your framing, in your favour: the option is **caller-supplied and live**.
`Executor.run_step/5` accepts `opts` (`executor.ex:153`) and threads it
unchanged to `handle_failure/3`, so your override-`execute/2` workaround needs
nothing from us to work today. What was wrong was only the comment's
attribution to a `Dsl.Runtime` mechanism deleted in Phase 5.10.

---

## One gap you did not find, which affects your onboarding

Your list keyed on the host's name; that sweep is complete
(`grep -rni 'amesbury' lib/` → 0). It could not see a second class: **paths in
shipped files that do not exist in the shipped tree.** Measured at `a10d672`:

| Class | Sites | Files |
|---|---|---|
| `steering/*.md` references | 9 | 4 |
| `.work/*` references | 6 | 4 |
| `scripts/nilability_predict.py` — **absent from the repo entirely** | 4 | 2 |
| bare `LLMEngine.*` (a host module, unqualified) | 4 | 4 |
| "root `CLAUDE.md`" (meaning the *host's*, not this repo's) | 4 | 4 |
| `amesbury` in the shipped **migration moduledoc** | 4 | 1 |

The last row is the one that touches you directly: the canonical DDL file we
told you to copy currently instructs the reader to compare it against
`apps/amesbury/priv/repo/migrations/` — a path you do not have. That is being
fixed in the new design's subphase 4 (the migration's `change/0` body is
**not** touched, so the DDL you copy today is already final).

The `scripts/nilability_predict.py` row is worth flagging because it makes a
shipped claim unverifiable: `mix allm_pipeline.nilability`'s moduledoc builds
its deliberate-mirror argument on a file that is not in this repo. If you read
that task's docs while porting, ignore the "third copy" claim until subphase 4
lands.

We are **not** sweeping the 90 bare `Phase N` markers across 24 `lib/` files —
they are maintainer provenance, none instructs a reader to open anything, and
`README.md` will define the term once instead.

---

## Confirmed deliberate — do not treat as a gap

You already flagged this and you were right: **`ALLM.Pipeline.LLM.impl/0`
raises when no `llm:` is declared, and there is no package default.** Confirmed
deliberate and staying that way. An LLM adapter is a provider integration with
credentials and a retry policy; a default that quietly does nothing would let a
step report success having called no model. `llm.ex`'s moduledoc, "There is no
package default, and `impl/0` raises", is the normative statement. `life-skills`
writes the adapter (your D17); nothing is owed here.

---

## What we need from you / the user

1. **Nothing blocking.** Phase `life-skills` now. P1–P3 are closed; P4–P9 have
   either a landing subphase or a confirmed consumer-side answer.
2. **The publish is a scheduling call.** `CLAUDE.md`'s trigger is "a second
   consumer, or the user asks". You are the second consumer, so
   `…_HEX_PREP.md` subphase 5 is unblocked on merit — every other row of that
   design is Complete. It needs the user to run it (the release script
   deliberately never publishes or pushes itself; Hex's device-flow auth needs
   a real terminal). Until then, path dep.
3. **Tell us if you want cost queryable.** Adding a cost **column** is a second
   versioned migration against tables the existing host has already migrated,
   plus a schema-parity re-run against the host twin. Both are doable — the
   parity re-run was discharged green host-side on 2026-08-31 — we are just not
   doing them on spec. If `life-skills` needs USD in a `WHERE` clause rather
   than in an artifact, say so and it becomes a real subphase.
4. **Same for resume-from-log and a budget ceiling.** Both are recorded with
   triggers. `CLAUDE.md` §7 already carries the lesson we are applying here:
   four DSL constructs shipped green with zero consumers because nothing
   declared them. We would rather build these when you can name the
   declaration site.

---

## Pointers

- New design: `steering/2026-08-31_SECOND_CONSUMER_GAPS.md` (six subphases,
  contracts C1–C4, per-subphase verification blocks).
- Prior design: `steering/2026-08-31_MULTI_CONSUMER_HEX_PREP.md` — 5/6:
  subphases 1, 2, 3, 4, 6 Complete; **5 (the v0.1.0 publish) Deferred,
  user-gated**.
- Consumer onboarding: `guides/host_wiring.md`.
- Canonical DDL:
  `priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs`.
- Working references for the test-suite pattern: this repo's
  `test/test_helper.exs` and `test/support/test_registry.ex`.
