# Hexdocs Overhaul — Implementation Guide, History Purge, Durable Rule

**Goal.** Make the published hexdocs a description of *what the framework does
now* — not a litigated record of how it got here. Three deliverables: (1) a new
"build a real pipeline" guide, (2) a sweep that removes development-phase and
consumer-specific history from every published page, and (3) an agent-spec rule
+ a publish-time check that keep the hexdocs history-free going forward.

**Measurable outcome.** After the sweep: the **hard** banned-pattern grep over
the regenerated `doc/*.md` returns **zero** (positive control: `Pipeline` still
matches); the **soft advisory** grep (host-framing words the hard grep
deliberately excludes) is read down to nothing by the code-review lane; `mix
docs` still emits **zero warnings** (today's baseline — verified below); `mix
precommit` stays green; and a new `guides/building_a_pipeline.md` renders in
hexdocs with live autolinks.

> **The hard grep is a floor, not a completeness oracle.** It catches an
> *enumerable* token set (a phase number, a `batch N`, an ISO-dated rationale,
> an Amesbury-domain proper noun). It **cannot** catch host-framing paraphrase —
> an "umbrella lends its run" sentence reworded generically, a rationale whose
> date was dropped. Two independent findings proved this at design time:
> `doc/readme.md` and `doc/ALLM.Pipeline.Metrics.md` each returned **zero** hits
> under the *first-draft* pattern while still carrying "Phases 1–8" / "batch 1.C"
> / "extraction plan" / "umbrella" narrative. The extended C2 pattern closes the
> enumerable gap; the residual (host framing, `umbrella`) is the **code-review
> lane's** charge, stated in C1's "What the grep can't see". Grep-zero is
> necessary, not sufficient.

**Spec sections covered.** `agent-spec/DESIGN.md` (structure, evidence
discipline); the docs surface enumerated in `mix.exs` `docs/0` (`main: "readme"`,
`extras:` README + `guides/host_wiring.md` + CHANGELOG, plus every `@moduledoc`).

**Layers touched.** Documentation only — `@moduledoc`/`@doc` strings in `lib/`,
`README.md`, `CHANGELOG.md`, `guides/`, `mix.exs` `docs/0`, `scripts/release.exs`,
and `agent-spec/` + `CLAUDE.md`. **No behavioral code changes.**

---

## Status

| Subphase | Concern | Status |
|---|---|---|
| 1 | Agent-spec rule + verification harness (the contract the sweep applies) | Complete |
| 2 | Sweep batch A — the DSL / lifecycle / executor cluster (Phase-heavy) | Complete |
| 3 | Sweep batch B — remaining modules + README + CHANGELOG | Not Started |
| 4 | New guide — `guides/building_a_pipeline.md` | Not Started |

**Overall Progress: 2/4**

Per-subphase records (deviations, closure ledger, verification transcripts) go
to `steering/2026-08-31_DOC_UPDATES_RECORDS.md`, created on first need.

---

## Overview

### Deliverables

1. **`agent-spec/DOCS.md`** (NEW) — the durable rule: hexdocs state current
   functionality in the present tense; no development-phase numbering, no
   "used to / no longer" narrative, no consumer-specific names. Carries the
   decision table (§ Contracts) and the verification recipe. Referenced from
   `CLAUDE.md` and `agent-spec/CODE_REVIEW.md`.
2. **A publish-time guard** in `scripts/release.exs` — a WARN (matching the
   script's existing advisory tone) when the regenerated hexdocs still contain
   banned patterns. Its positive control is the pre-sweep tree itself (it fires
   today; it goes silent after subphases 2–3).
3. **The sweep** — every `@moduledoc`/`@doc` in `lib/`, plus `README.md` and
   `CHANGELOG.md`, rewritten so the published surface is history-free and
   host-neutral, preserving *rationale* while deleting *narrative*.
4. **`guides/building_a_pipeline.md`** (NEW) — an end-to-end tutorial: define a
   `Step` with `Schema` Input/Output, add an `LLMStep`, compose them with
   `use ALLM.Pipeline` (stages, fan-out, metrics, summarize), run it, and read
   back step logs / lineage / artifacts. Complements `host_wiring.md` (which is
   boot plumbing) and points at it for wiring.

### Out of scope (each a deliberate exclusion, not an oversight)

- **`CLAUDE.md`'s own phase history.** `CLAUDE.md` ships in the tarball but is
  **not** in `docs/0` `:extras`, so ExDoc never renders it — it is the *agent
  guide*, and its phase/deviation record is load-bearing for agents working in
  the repo. It stays. (This is the whole reason the history has a home to move
  *out of* the hexdocs *to*.)
- **`steering/`, `agent-spec/*`, `.work/`, `HISTORY.md`, `ASKS.md`** — dev-only,
  none in `docs/0` `:extras` or the hex tarball `files:` (except `CLAUDE.md`).
  Untouched except the two agent-spec files we add/reference.
- **The `skip_code_autolink_to:` list in `mix.exs`** — those name current
  private/`@doc false` internals the moduledocs deliberately reference; not
  history.
- **Behavioral code, tests, `@spec`s** — a moduledoc rewrite changes no
  behavior; `mix test` is a regression check, not a change target.
- **New ExUnit test that scans moduledoc strings** — rejected as brittle
  (a test that `File.read!`s source and regexes attributes); the release-script
  grep over generated output is the executable guard, the agent-spec rule + code
  review is the durable one. See Alternatives A3.

### Non-obvious decisions

- **The verification greps the *generated* `doc/*.md`, never `lib/*.ex`.** ExDoc
  renders only `@moduledoc`/`@doc`; `#` code comments never reach hexdocs. A grep
  over source conflates the two — `lib/` has 34 files with a history hit, but many
  are in comments that are correctly staying. The generated markdown is the
  literal published surface, so it is the only honest oracle. (Evidence: the
  source grep flagged 34 files; the `doc/*.md` grep flagged ~30 pages with the
  *comment* noise removed — see § Evidence.)
- **`doc/` is gitignored** (`.gitignore:4` → `/doc/`; `git ls-files doc/` → 0).
  So the deliverable is source edits; the verification *regenerates* `doc/` with
  `mix docs` and greps the fresh output. Nothing under `doc/` is committed.
- **Rationale is preserved; only narrative is deleted.** Most historical
  sentences in these moduledocs exist to explain a *current, non-obvious
  constraint* (why teardown precedes the terminal write; why `post_process/2`
  takes no `@impl`). The rule rewrites those to present tense — it does not
  delete the explanation. Over-stripping (losing the "why") is the failure mode
  the grep **cannot** catch; the review lane must (§ Contracts, "What the grep
  can't see").
- **`api-reference.md` and `search.html` are auto-derived** from moduledoc
  first-lines; fixing the moduledocs fixes them with no separate edit. (Evidence:
  `doc/api-reference.md:24` reproduces `Context`'s "since Phase 4" first line
  verbatim.)

### Review lanes

- **Code review (`agent-spec/CODE_REVIEW.md`)** — APPLIES. This change *adds* a
  review-lane rule (subphase 1) and is itself the first thing that rule reviews.
  The reviewer checks the sweep preserved rationale and introduced no
  host-specific leakage.
- **Behavioral review (`agent-spec/REVIEW.md`)** — N/A trigger: no behavioral
  code changed. The only executable artifacts are the release-script grep and
  the `mix docs` / `mix precommit` gates, verified by running them.
- **Design review / security review** — N/A: no front-end, no attack surface.

---

## Contracts

These are stated **once here**; every subphase references this section.

### C1 — The categorization decision rule (the heart of the sweep)

Every historical or host-specific fragment in a published doc falls into exactly
one of four categories. The action is fixed per category. This table is the
normative rule and is transcribed verbatim into `agent-spec/DOCS.md`.

| # | Category | Recognizer | Action | Worked example (real, from this tree) |
|---|---|---|---|---|
| A | **Narrative history** | "Before Phase 4…", "used to carry", "X ported it until Phase Y", "widened from … to …", "As of 2026-08-13", any **ISO-dated rationale** ("Measured 2026-…", "Corrected 2026-…", "widened on 2026-…"), "predates", "retired", a **`batch N`** or **`extraction plan §…`** reference, a **`steering/20…` file reference** | **Delete the narrative.** If it was the only statement of a *current* fact, restate that fact in the present tense. The history itself lives in git + CHANGELOG + `steering/` — do not relocate it into the doc. | `pipeline.ex` moduledoc: *"Before Phase 4 an orchestrator was a plain module, and every one hand-wrote the same skeleton… its variations were the defects"* → *"The DSL owns the run skeleton — run creation, lineage-threaded step sequencing, the guard that fails-and-reraises, metrics, terminal complete — so a pipeline declares stages, not boilerplate. Hand-writing that skeleton is what produces the classic defects: a run that never terminates, steps passed `nil` lineage, an orchestrator with no rescue."* |
| B | **Phase / deviation tag on a still-true rule** | a parenthetical `(Phase 4 D3)`, `(Phase 4.5 Alternatives)`, `(Phase 4 D6)` appended to a sentence that is otherwise present-tense | **Delete the tag only;** keep the sentence. | `dsl/resource.ex`: *"## Why teardown runs BEFORE the terminal write (Phase 4 D3)"* → *"## Why teardown runs before the terminal write"* |
| C | **Consumer-specific example / name** | `meeting_agenda`, `MeetingAgendaPipeline`, `MeetingListScraper`, `MeetingImportanceScorer`, `MeetingsPipeline`, `CommitteePipeline`, `committee`, `Government`, `Ordinance`/`ordinance`, `Amesbury`/`amesbury`, `transform_ordinance`, `scrape_committee_list` and any other host proper noun (grep each swept page for `[A-Z][a-z]+[A-Z]` module-looking names and confirm each is either a package `ALLM.Pipeline.*` module or a generic `MyApp.*`) | **Genericize** to a host-neutral name (`MyApp.*`, a self-contained illustrative pipeline). The example must still read as *plausibly compilable*, not a fragment. Drop any "actually ships as of…" framing. | `pipeline.ex`'s flagship `MeetingAgendaPipeline` example → a generic `MyApp.ReportPipeline` (or similar) with the same construct coverage but no host domain. |
| D | **Live status framed historically** | "No production consumer as of Phase 4.5 — deadlined to Phase 5", "the guard is inert on every live path" | **Restate as present-tense status,** dropping the phase deadline; keep the substance (that the construct/guard has no in-tree consumer today). | `dsl/resource.ex`: *"No production consumer as of Phase 4.5 — deadlined to Phase 5…"* → *"No in-tree pipeline declares a `resource` yet; it exists for hosts whose steps hold external handles (a browser session, a DB connection) that must be released even when a run raises."* |

**What the grep can't see (review-lane obligation).** The hard grep (C2a) is a
floor over an *enumerable* token set. Two blind spots are the review lane's, not
the grep's:

- **Over-stripping.** A category-A rewrite that deleted the rationale instead of
  restating it. The reviewer diffs each rewritten moduledoc against its pre-sweep
  version and confirms every *current constraint* survived; a page that got
  materially shorter with no corresponding removed-narrative is the smell.
- **Host-framing paraphrase.** A sentence like `PipelineRun`'s "an umbrella
  lending its run to an inner pipeline" or `Metrics`'s "the sole completer for
  umbrella/borrowed runs" is host-specific but reworded generically it leaves no
  banned token. The **soft advisory grep (C2b)** surfaces the `umbrella` /
  host-framing lines with line numbers; the reviewer reads each to zero.

**`umbrella` is soft-advisory, not a hard ban.** "Umbrella" is a legitimate
generic Elixir term, and every *current* occurrence refers to *the* Amesbury
umbrella (host-specific → genericize or drop) while a future host-neutral
sentence may legitimately say "umbrella application". So `umbrella` (with
`extraction plan` and `batch N`, which the hard grep now also bans as unambiguous
history) is surfaced by the **soft advisory grep (C2b)** for line-by-line review
rather than gated — keeping the hard grep false-positive-free while still
mechanically flagging the host framing for the reviewer.

### C2 — The verification grep (banned patterns + positive control)

The published-surface check. Run after `mix docs` regenerates `doc/`. Emptiness
is success, so it ships with a positive control per `agent-spec/DESIGN.md`.

Two greps: a **hard** one that gates (must reach zero), and a **soft advisory**
one that surfaces host-framing for review (does not gate). The hard pattern is
anchored to structural forms — a phase number, a `batch N`, an ISO date, a
history verb, an Amesbury-domain proper noun — never a bare substring the new
prose could match. `HARD` is defined once here and reused by every subphase.

```bash
# Regenerate the literal published surface.
mix docs >/dev/null

# The single source of truth for the hard pattern (reused by subphases + release).
HARD='[Pp]hases? [0-9]|\(D[0-9]|used to |no longer|predates|retired|Before Phase|As of 20[0-9][0-9]|20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]|batch [0-9]|extraction plan|steering/20|meeting_agenda|MeetingAgenda|MeetingList|MeetingImportance|MeetingsPipeline|CommitteePipeline|committee|Government|Scorer|Ordinance|ordinance|Amesbury|amesbury'

# (a) HARD — must return zero.
grep -rInE "$HARD" doc/*.md
echo "banned hits: $?"        # grep exit 1 (no match) == success

# (b) POSITIVE CONTROL — must return NON-zero. Proves the grep + corpus work
#     (a typo'd pattern or empty doc/ would make (a) falsely pass).
grep -rIl 'Pipeline' doc/*.md | head -1   # expect at least one file

# (c) SOFT ADVISORY — host-framing the hard grep deliberately excludes; NOT a
#     gate. Read to zero by the code-review lane, page by page (C1 "What the
#     grep can't see"). Some 'umbrella' lines may legitimately survive as
#     generic "umbrella application"; the reviewer decides per line.
grep -rInE 'umbrella|host application' doc/*.md   # advisory — review, do not gate
```

**Design-time baseline (pre-sweep, verified 2026-08-31):** the hard grep matches
today — `[Pp]hase [0-9]` alone returned **~85 hits** (`Phase 4`×21, `Phase 4.5`×10,
`Phase 5`×7, `Phase 7.4`×5, …); consumer identifiers **~35** (`committee`×12,
`meeting_agenda`×11, `ordinance`×4, `MeetingListScraper`×3, …). The extended
`HARD` pattern adds the forms a first draft missed, each verified present:
`extraction plan`×9, `batch 1.C`×6, `Measured 2026`/`Corrected 2026`/`widened on
2026` (ISO-dated rationale), plus `MeetingImportanceScorer` (`LLMStep.md:102`)
and `Government.resolve_step_log/1` (`Query.md:112`). **Why the extension is
load-bearing:** under the first-draft pattern `doc/readme.md` (the hexdocs main
page) and `doc/ALLM.Pipeline.Metrics.md` each returned **zero** hits while still
carrying `Phases 1–8` / `batch 1.C` / `extraction plan §3.8a` / `umbrella`
narrative (`Metrics.md:6,69,75,89`). The extended `HARD` catches all but the
`umbrella` framing, which C2b/the review lane owns. This non-empty baseline is
the positive control that the check fires; the sweep drives the hard grep to
zero.

### C3 — The `mix docs` zero-warning invariant

`mix docs` emits ExDoc warnings on broken autolinks. The invariant:

```bash
mix docs 2>&1 | grep -iE 'warning|error'    # expect: no output
```

**Design-time baseline (verified 2026-08-31):** `timeout 60 mix docs 2>&1 | grep
-iE 'warning|error'` produced **no output**, exit 0. The sweep must keep it at
zero.

**Where the warning actually comes from (verified empirically at design time).**
ExDoc warns only on a **resolvable module with an unresolvable member** — a
backticked `ALLM.Pipeline.Text.no_such_fun/9` warns; a fully **invented** name
does *not*, whether fenced or inline (`` `MyApp.NonExistent` `` and
`` `MyApp.NonExistent.foo/1` `` both produced no warning on test). `mix.exs:76-77`
corroborates: ExDoc "warns when the target is private or hidden" — i.e. a known
module, an unknown/hidden member. So the real hazard of the sweep is **not** the
invented `MyApp.*` names (safe anywhere); it is a genericized example that
**retains a real `ALLM.Pipeline.*.fun/arity` reference whose arity no longer
matches**, or a leftover backticked host module (`MeetingImportanceScorer.Output`)
that once resolved against a host but never against the package. Verification:
after each rewrite, confirm every retained backticked `Mod.fun/arity` resolves,
and run the zero-warning check above.

### C4 — The new guide's scope contract

`guides/building_a_pipeline.md` follows `host_wiring.md`'s discipline exactly
(its own preamble, lines 6–9: *"It points at the normative moduledocs rather than
duplicating them"*). Boundaries:

- **Covers (the application):** authoring a `Step` via `use ALLM.Pipeline.Schema`
  Input/Output; an `LLMStep`; composing with `use ALLM.Pipeline` (a `stage`, a
  declarative `fan_out` over a Step, `metrics`, `summarize`); invoking the
  generated `run/1`; reading back a run's step logs, lineage tree, and artifacts.
- **Defers to `host_wiring.md`** for registry/repo/adapter/DDL wiring — links,
  does not restate.
- **Defers to each module's moduledoc** for the normative contract — every
  section names the module whose `@moduledoc` is the source of truth (same rule
  as `host_wiring.md`).
- **`MyApp` stands for the host app** throughout (identical convention to
  `host_wiring.md:11`).
- Registered in `mix.exs` `docs/0` `:extras` with `title: "Building a pipeline"`.

---

## File-change manifest

`ls`-confirmed paths. NEW paths verified absent; MODIFY paths verified present.

**NEW**
- `agent-spec/DOCS.md` — the durable rule (C1 + C2 recipe). *(subphase 1)*
- `guides/building_a_pipeline.md` — the tutorial. *(subphase 4)*
- `steering/2026-08-31_DOC_UPDATES_RECORDS.md` — records companion, on first need.

**MODIFY — infra / spec (subphase 1)**
- `mix.exs` — add the new guide to `docs/0` `:extras`; add to hex `package`
  `files:` `~w(...)` is already `guides` (whole dir) so no `files:` change needed
  — **verify:** `files:` lists `guides` not individual files (it does:
  `~w(lib guides priv/test_repo/migrations …)`). Only `docs/0` `:extras` changes.
- `scripts/release.exs` — add a `defp hexdocs_history_warning/0` that runs
  `System.cmd("mix", ["docs"], ...)` then greps `doc/*.md` (excluding
  `changelog.md`, per Q1) for the C2 `HARD` pattern, WARNing (not aborting) on a
  hit. **This adds the *first* `mix docs`
  run to the release path** — the script currently has none (verified: no
  `mix docs` in `scripts/release.exs`; cost is ~1s per C3 baseline). Call it from
  the same place as `migration_touch_warning/1` (defined near `scripts/release.exs:383`,
  called near `:254`), and emit through the same advisory channel as the existing
  `Excluding tags` warning (near `:447`) — same non-aborting tone, so a release
  is never blocked by a doc grep, only flagged.
- `CLAUDE.md` — one pointer line to `agent-spec/DOCS.md` under a docs-discipline
  note (do not restate the rule; CLAUDE.md keeps its own phase history).
- `agent-spec/CODE_REVIEW.md` — one review-lane bullet: flag category-A/B/C
  patterns in `@moduledoc`/`@doc`, cite `agent-spec/DOCS.md`.

**MODIFY — sweep batch A (subphase 2): the Phase-heavy DSL/lifecycle/executor cluster**
(source ↔ generated page. The parenthetical counts are *indicative* — they come
from the source-file grep, which includes `#` comments ExDoc never renders. The
**authoritative per-page target is the C2 `HARD` grep over the regenerated
`doc/*.md` reaching zero**, plus the C2b soft-advisory read-down. A page can carry
history the source count understates: `Metrics` showed 0 hits under the
first-draft pattern yet had 4 host-history lines — do not trust a low count to
mean "little to do".)
- `lib/allm/pipeline.ex` (`ALLM.Pipeline`, 38 hits — the flagship, incl. the
  `meeting_agenda` example)
- `lib/allm/pipeline/llm_step.ex` (`LLMStep`, 13 — "used to carry… Phase 2… Phase 3.1")
- `lib/allm/pipeline/executor.ex` (`Executor`, 6)
- `lib/allm/pipeline/dsl.ex` (`Dsl`, 6)
- `lib/allm/pipeline/fan_out.ex` (`FanOut`, 5 — "ported committee pipeline… Phase 4.4")
- `lib/allm/pipeline/context.ex` (`Context`, 8 — "since Phase 4", `meeting_agenda`)
- `lib/allm/pipeline/dsl/resource.ex` (`Dsl.Resource`, 7 — category-D status note)
- `lib/allm/pipeline/lifecycle.ex` (`Lifecycle`, 3)
- `lib/allm/pipeline/dsl/item.ex` (`Dsl.Item`, 3)
- `lib/allm/pipeline/dsl/stage.ex` (`Dsl.Stage`, 2)
- `lib/allm/pipeline/dsl/runtime.ex` (`Dsl.Runtime`, 2)

**MODIFY — sweep batch B (subphase 3): remaining modules + top-level docs**
- `lib/allm/pipeline/pipeline_run.ex` (`PipelineRun`, 10 — "As of 2026-08-13 …inert")
- `lib/allm/pipeline/step_log.ex` (`StepLog`, 8)
- `lib/allm/pipeline/encodable.ex` (`Encodable`, 5)
- `lib/allm/pipeline/config.ex` (`Config`, 5)
- `lib/allm/pipeline/artifacts.ex` (`Artifacts`, 5)
- `lib/allm/pipeline/schema.ex` (`Schema`, 4)
- `lib/allm/pipeline/query.ex` (`Query`, 4)
- `lib/allm/pipeline/lock/advisory.ex` (`Lock.Advisory`, 4)
- `lib/allm/pipeline/artifact_store.ex` (`ArtifactStore`, 3)
- `lib/allm/pipeline/text.ex` (`Text`, 2)
- `lib/allm/pipeline/store.ex` (`Store`, 2)
- `lib/allm/pipeline/step.ex` (`Step`, 2)
- `lib/allm/pipeline/metrics.ex` (`Metrics`, 2)
- `lib/allm/pipeline/artifacts/dynamo.ex` (`Artifacts.Dynamo`, 2)
- `lib/allm/pipeline/registry.ex` (`Registry`, 1)
- `lib/allm/pipeline/lock.ex` (`Lock`, 1)
- `lib/allm/pipeline/store/ecto.ex` (`Store.Ecto`, 1)
- `lib/allm/pipeline/artifacts/tiered.ex` (`Artifacts.Tiered`, 1)
- `lib/mix/tasks/allm_pipeline.names.ex` (`Mix.Tasks…Names`, 1)
- `lib/mix/tasks/allm_pipeline.nilability.ex` (`Mix.Tasks…Nilability`, 1)
- `README.md` — strip the "Extracted from … Phases 1–8" narrative (lines 7–12)
  and the host-specific "path-dep umbrella" section entirely (Q1 = Option A);
  keep current-functionality and consumption prose host-neutral, the consumption
  *mechanism* described generically.
- `CHANGELOG.md` (Q1 = Option A) — **carved out of the hard grep** (a changelog
  records the rename it performed). **Keep** line 5's
  `(previously the host's :amesbury_scraper)` migration note; **reword only**
  line 13's `extraction plan Phases 1–8` clause to describe the change without
  internal phase vocabulary. The whole-surface hard grep therefore runs
  `--exclude=changelog.md`.

**DELIBERATELY UNTOUCHED**
- `guides/host_wiring.md` — already history-free and host-neutral (§ Evidence:
  zero banned hits). The new guide links to it.
- `CLAUDE.md` phase history — the agent guide (see Out of scope).

> The batch-A/batch-B split is by review batch size, not by concern — both apply
> the identical C1 rule and share the C2/C3 verification. Kept apart so each
> subphase stays reviewable (≤~12 files, grouped checkboxes).

---

## Subphase 1 — Agent-spec rule + verification harness

**One concern:** establish the rule the sweep applies and the executable check it
is measured by, before touching a single moduledoc.

**Test Plan (a docs/spec subphase — the "tests" are the executable checks):**
- The C2 `HARD` grep, run against **today's** (un-swept) `doc/*.md`, returns
  non-zero (positive control that the pattern fires — ~85 phase + ~35 consumer +
  the extended `extraction plan`/`batch N`/dated hits).
- The C2 positive-control grep (`Pipeline`) returns non-zero.
- The new `hexdocs_history_warning/0` fires on today's tree and does not abort.
  Test it directly (`mix docs >/dev/null && grep -rlE "$HARD" doc/*.md`) rather
  than through a full `mix run scripts/release.exs --dry-run`, which drags in the
  whole Phase-A gate (compile + `mix test`, needing Postgres/Dynamo/MinIO) just to
  observe a doc WARN.
- `mix precommit` stays green (spec/script edits don't affect compile/test).

**Checklist:**
- [ ] Write `agent-spec/DOCS.md`: the C1 decision table verbatim, the C2 grep
      recipe (banned + positive control), the C3 zero-warning invariant, and the
      "what the grep can't see" review obligation. State the rule once; do not
      duplicate C1 into CLAUDE.md.
- [ ] Add `defp hexdocs_history_warning/0` to `scripts/release.exs`: run
      `System.cmd("mix", ["docs"], ...)` (the script's first docs run — none
      exists today), then grep `doc/*.md` (`--exclude=changelog.md`) for the C2
      `HARD` pattern; on a hit,
      warn through the same channel as the `Excluding tags` advisory (near
      `:447`) with the count and "hexdocs still contain development-history
      references — see agent-spec/DOCS.md" (WARN, not abort). Wire the call
      beside `migration_touch_warning/1` (near `:254`).
- [ ] Add one pointer line to `CLAUDE.md` (docs-discipline note): "Published
      hexdocs are present-tense and history-free — `agent-spec/DOCS.md`."
- [ ] Add one review-lane bullet to `agent-spec/CODE_REVIEW.md` under Heuristics
      or a new "Docs" note: flag category-A/B/C patterns in `@moduledoc`/`@doc`,
      cite `agent-spec/DOCS.md`.
- [ ] Confirm `mix.exs` hex `files:` already ships `guides/` wholesale (it does —
      no change needed for subphase 4's new guide to reach the tarball).

**Verification:**
```bash
mix docs >/dev/null
grep -rIlE "$HARD" doc/*.md | wc -l        # >0 today — hard pattern fires (control)
grep -rIl 'Pipeline' doc/*.md | head -1    # non-empty (positive control)
grep -rInE 'umbrella' doc/*.md | wc -l     # >0 today — soft advisory fires (control)
mix precommit
```
**Success criteria:** `DOCS.md` exists and carries the C1 table + C2 (hard +
advisory) recipe; `hexdocs_history_warning/0` fires on the pre-sweep tree (direct
grep, per Test Plan); `mix precommit` green.

---

## Subphase 2 — Sweep batch A (DSL / lifecycle / executor cluster)

**One concern:** apply C1 to the 11 Phase-heavy files (§ manifest, batch A),
including the flagship `ALLM.Pipeline` moduledoc and its consumer-specific
example.

**Test Plan:**
- C2 banned grep over `doc/*.md`, **restricted to the batch-A pages**, returns
  zero (the batch-B pages may still match until subphase 3).
- C3: `mix docs` warnings for the batch-A pages: zero new vs. baseline.
- `mix precommit` green (doctests, if any moduledoc carries one, still pass).

> **Flagship mini-spec — `pipeline.ex`'s moduledoc example.** This is not a
> decorative sketch; its 38 lines (`lib/allm/pipeline.ex:20-64`) demonstrate the
> DSL's *hardest* mechanics, the ones `CLAUDE.md` §7 flags as silently
> mis-portable. A mechanical find-replace to `MyApp.*` that garbles any of these
> produces a WRONG example that misteaches. The generic replacement **must
> retain, structurally**: (1) an **external-`defp` atom hook** stage
> (`stage :x, :body_fun` with `defp body_fun/2` defined *outside* the module
> body — the reason hooks are AST, §7); (2) a `FanOut.reduce/5` body returning
> the lineage-transparent `{{:ok, items}, acc}` 2-tuple; (3) an **escape-hatch
> stage** that writes no step log / does not move the lineage parent, with that
> property stated; (4) the `{item_result, acc}` **accumulator write-channel**
> contract; (5) `metrics` + `summarize`. The code-review lane diffs construct
> coverage pre/post — every one of the five must survive genericization. This is
> the single most important application of the C1 over-strip guard.

**Checklist:**
- [ ] `pipeline.ex`: rewrite the "Before Phase 4…" motivation (cat. A) to
      present tense; replace the `MeetingAgendaPipeline`/`meeting_agenda`/
      `MeetingListScraper` flagship example (cat. C) with a self-contained
      host-neutral pipeline **per the Flagship mini-spec above** (retain all five
      constructs); drop "actually ships as of Phase 4.5" framing; strip remaining
      `Phase N` tags (cat. B).
- [ ] `llm_step.ex`: rewrite "An LLM step used to carry… Phase 2… Phase 3.1"
      (cat. A) to state what the macro generates now; genericize the
      `transform_ordinance`/`ordinance` example (cat. C).
- [ ] `context.ex`: "since Phase 4" / "Phase 4 widened context/0 from a bare map"
      (cat. A→present); `Phase 4 D5`/`D2` tags (cat. B); `meeting_agenda` stats
      example (cat. C).
- [ ] `dsl/resource.ex`: `Phase 4 D3`/`D6` tags (cat. B); the "No production
      consumer as of Phase 4.5 — deadlined to Phase 5" note (cat. D → present).
- [ ] `fan_out.ex`: "One ported committee pipeline… until Phase 4.4" (cat. A/C);
      `Phase 4.5`/`Phase 4 D2` tags (cat. B).
- [ ] `executor.ex`, `dsl.ex`, `lifecycle.ex`, `dsl/item.ex`, `dsl/stage.ex`,
      `dsl/runtime.ex`: strip cat.-B tags; rewrite any cat.-A sentence to present
      tense; genericize any cat.-C name.
- [ ] For every rewrite: confirm the *current constraint* the sentence explained
      still appears (over-strip guard, C1 "what the grep can't see").

**Verification:**
```bash
mix docs >/dev/null
BATCH_A='doc/ALLM.Pipeline.md doc/ALLM.Pipeline.LLMStep.md doc/ALLM.Pipeline.Executor.md \
  doc/ALLM.Pipeline.Dsl.md doc/ALLM.Pipeline.FanOut.md doc/ALLM.Pipeline.Context.md \
  doc/ALLM.Pipeline.Dsl.Resource.md doc/ALLM.Pipeline.Lifecycle.md doc/ALLM.Pipeline.Dsl.Item.md \
  doc/ALLM.Pipeline.Dsl.Stage.md doc/ALLM.Pipeline.Dsl.Runtime.md'
grep -InE "$HARD" $BATCH_A            # expect: no output ($HARD from C2)
grep -InE 'umbrella' $BATCH_A        # advisory: read each surviving line in review
mix docs 2>&1 | grep -iE 'warning|error'   # expect: no output
mix precommit
```
**Success criteria:** batch-A pages return zero `HARD` hits; the advisory
`umbrella`/host-framing lines are reviewed to zero (or justified generic); zero
new `mix docs` warnings; `mix precommit` green; each rewritten moduledoc's current
constraints verified present in code review.

---

## Subphase 3 — Sweep batch B (remaining modules + README + CHANGELOG)

**One concern:** apply C1 to the remaining ~20 module pages and the top-level
`README.md` / `CHANGELOG.md`. After this subphase the **whole** C2 grep returns
zero.

**Test Plan:**
- C2 `HARD` grep over `doc/*.md` **except `doc/changelog.md`** returns zero
  (batch A + B done; the CHANGELOG is carved out per Q1 = Option A — run
  `grep … --exclude=changelog.md doc/*.md`).
- C2b advisory (`umbrella`/host-framing) read to zero (or justified generic) by
  review across the whole surface.
- C2 positive control (`Pipeline`) still non-zero.
- C3 zero `mix docs` warnings.
- `mix precommit` green.
- `hexdocs_history_warning/0` now goes **silent** on the swept tree.

**Checklist:**
- [ ] `pipeline_run.ex`: rewrite "As of 2026-08-13 the guard is inert on every
      live path… 28 fail / 17 complete sites" (cat. A/D) to a present-tense
      statement of what the completion token guards; strip the borrowed-run
      "umbrella lending its run" host framing (cat. C → generic "an outer
      pipeline lending its run").
- [ ] `metrics.ex` — **the grep-invisible page.** Under the first-draft pattern
      it showed 0 hits yet carries `umbrella` (`Metrics.md:6`), `batch 1.C moved
      it` (`:69`), `extraction plan §3.8a` (`:75`), `Phases 1-6` (`:89`). The
      extended `HARD` now catches all but the `umbrella`; apply C1 to every line
      and read the advisory `umbrella` line down.
- [ ] `config.ex` (`Decided in batch 1.B` / dated narrative), `query.ex`
      (`Government.resolve_step_log/1`), `llm_step.ex`
      (`MeetingImportanceScorer.Output`, in batch A) — genericize the proper
      nouns per C1-C.
- [ ] Remaining batch-B modules (`step_log`, `encodable`, `artifacts`,
      `schema`, `lock/advisory`, `artifact_store`, `text`, `store`,
      `step`, `artifacts/dynamo`, `registry`, `lock`, `store/ecto`,
      `artifacts/tiered`, both mix tasks): apply C1 per hit.
- [ ] `README.md` (Q1 = Option A): delete the "Extracted from … Phases 1–8"
      narrative (lines 7–12) and the "path-dep umbrella" section; make the
      consumption prose host-neutral (this is the hexdocs main page).
- [ ] `CHANGELOG.md` (Q1 = Option A): reword only the "extraction plan Phases
      1–8" clause (line 13); **keep** line 5's `:amesbury_scraper` migration
      note. The CHANGELOG is carved out of the hard grep (`--exclude=changelog.md`).
- [ ] Re-confirm `guides/host_wiring.md` still clean (no regression).

**Verification:**
```bash
mix docs >/dev/null
grep -rInE "$HARD" --exclude=changelog.md doc/*.md   # expect: NO OUTPUT (CHANGELOG carved out; $HARD from C2)
grep -rIl 'Pipeline' doc/*.md | head -1     # positive control: non-empty
grep -rInE 'umbrella' doc/*.md              # advisory: expect only justified generic uses, reviewed
mix docs 2>&1 | grep -iE 'warning|error'    # expect: no output
mix precommit
```
**Success criteria:** whole-surface `HARD` grep zero; advisory read to zero or
justified; positive control non-empty; zero `mix docs` warnings; `mix precommit`
green.

---

## Subphase 4 — New guide `guides/building_a_pipeline.md`

**One concern:** the end-to-end "implement a pipeline in a real project" tutorial
(C4), registered in hexdocs.

**Test Plan:**
- `mix docs` renders the guide as an extra with title "Building a pipeline";
  zero new warnings (every retained backticked `ALLM.Pipeline.*.fun/arity`
  resolves — C3; invented `MyApp.*` names are safe regardless).
- The guide contains no C2 `HARD` pattern (new prose — must be born clean).
- `mix precommit` green.

**Checklist:**
- [ ] Write `guides/building_a_pipeline.md` per C4: `MyApp` convention;
      Step-with-Schema → LLMStep → `use ALLM.Pipeline` composition → `run/1` →
      reading step logs / lineage / artifacts; every section names the normative
      moduledoc; links to `host_wiring.md` for wiring rather than restating it.
- [ ] Add to `mix.exs` `docs/0` `:extras`:
      `"guides/building_a_pipeline.md": [title: "Building a pipeline"]`.
- [ ] Cross-link: add a one-line pointer from `README.md` ("Host consumption"
      section) and from `guides/host_wiring.md`'s intro to the new guide.
- [ ] Confirm every retained backticked real `Mod.fun/arity` in the guide
      resolves (no ExDoc warning); invented `MyApp.*` names need no special
      handling (C3 — safe fenced or inline).

**Verification:**
```bash
mix docs 2>&1 | grep -iE 'warning|error'                 # expect: no output
test -f doc/building_a_pipeline.md && echo rendered       # ExDoc emits the extra
grep -InE "$HARD" doc/building_a_pipeline.md              # expect: none ($HARD from C2)
mix precommit
```
**Success criteria:** guide renders in hexdocs with live autolinks and zero
warnings; born free of C2 patterns; cross-links land; `mix precommit` green.

---

## Definition of Done

- All four Status rows **Complete**; `Overall Progress: 4/4`.
- C2 `HARD` grep over the regenerated `doc/*.md` (`--exclude=changelog.md`, per
  Q1 = Option A) returns **zero**; the C2b advisory (`umbrella`/host-framing) is
  read to zero or justified-generic; positive control (`Pipeline`) non-empty —
  all pasted into the RECORDS companion.
- `mix docs` emits **zero** warnings (baseline preserved).
- `mix precommit` green; `mix dialyzer` unaffected (no `@spec` touched — note in
  RECORDS, do not run unless a spec changed).
- `agent-spec/DOCS.md` exists and is referenced from `CLAUDE.md` and
  `agent-spec/CODE_REVIEW.md`; `hexdocs_history_warning/0` is silent on the swept
  tree and its positive-control firing (pre-sweep) is recorded.
- `guides/building_a_pipeline.md` renders as a hexdocs extra with live autolinks.
- CHANGELOG line for the public-doc change (the guide is a public-API-adjacent
  addition; the history purge is a doc-quality change — one `## [DOC]` entry per
  `/changelog` format covers both).
- Code review lane run on the sweep (confirms rationale preserved, no host leak);
  behavioral review N/A (recorded, no code changed).

---

## Assumptions

1. **`doc/` is disposable build output**, regenerated by `mix docs` and gitignored
   (verified: `.gitignore:4`, `git ls-files doc/` → 0). The verification
   regenerates it; nothing under `doc/` is committed or reviewed as a deliverable.
2. **ExDoc renders only `@moduledoc`/`@doc`**, never `#` comments — so history in
   comments is out of scope and correctly stays (it documents *why the code is
   this way* for repo maintainers, same role as CLAUDE.md).
3. **`CLAUDE.md` stays in the tarball but out of hexdocs** (`files:` includes it;
   `docs/0` `:extras` does not) — so it remains the home for the phase/deviation
   history the hexdocs shed. Verified against `mix.exs` `package/0` and `docs/0`.
4. **One moduledoc being swept carries a live doctest — `ALLM.Pipeline.Text`**
   (`test/allm/pipeline/text_test.exs:4` → `doctest ALLM.Pipeline.Text`; `iex>`
   prompts at `text.ex:80,104,107`). Its banned hits (`Phase 7.2`, `Phase 8`) are
   at `text.ex:11,13`, well away from the doctest blocks, so the rewrite is safe —
   **but the rewriter must preserve the `iex>` blocks verbatim.** No other swept
   moduledoc carries a doctest (the consumer-specific examples are illustrative
   fenced blocks without `iex>`). `mix precommit`'s `mix test` is the backstop.
5. **The toolchain runs `mix docs` in <60s** (verified: `timeout 60 mix docs`
   exited 0 today) — so folding a `mix docs` regen into `scripts/release.exs` adds
   proportionate time to a gate that already runs the full test suite.

## Alternatives Considered

- **A1 — New guide vs. expanding `host_wiring.md`.** Chosen: a separate guide.
  `host_wiring.md` is deliberately scoped to boot *plumbing* (registry, seams,
  DDL, test harness) and says so; the requested "implement in a real project"
  content is the *application* layer (authoring steps, composing a pipeline,
  reading results). Two focused guides that cross-link beat one that does both
  jobs at half depth. Rejected because folding them dilutes host_wiring's
  wiring-reference role.
- **A2 — README fully host-neutral vs. keeping current internal status.** The
  README is the hexdocs **main page** (`main: "readme"`). Default (Q1): make it
  host-neutral — drop the Amesbury / `~/Projects/ALLM.Pipeline` / path-dep-umbrella
  / `deploy.sh` specifics, since naming a private internal consumer on the public
  landing page is the exact host-leakage this exercise removes. The consumption
  *mechanism* (path dep vs. Hex) stays, described generically. **Resolved as
  Option A (user, 2026-09-01)** — see Q1; the CHANGELOG is carved out of the hard
  grep so its concrete `:amesbury_scraper` migration note survives.
- **A3 — Enforcement strength.** Options: (a) agent-spec rule only; (b) rule +
  release-script WARN; (c) rule + an ExUnit test scanning moduledoc source.
  Chosen: **(b)**. (a) alone regresses silently; (c) is a brittle test that
  `File.read!`s `lib/` and regexes attribute strings, and duplicates what ExDoc
  already renders — the generated-doc grep is the truthful oracle and belongs at
  publish time, where hexdocs correctness is the concern. The house strongly
  prefers an executable guard (CODE_REVIEW.md "hand-mirrored sets need membership
  guards"); the release-script grep is that guard without slowing `mix precommit`.
  A hard-fail (vs. WARN) was considered and rejected to match the script's
  advisory tone for its other doc/stack checks — the durable "always" enforcement
  is the agent-spec rule + the code-review lane, not a brittle publish-time block.
- **A4 — Delete history vs. relocate it.** Chosen: delete narrative, preserve
  rationale in present tense. The history is already recorded three times over
  (git log, `CHANGELOG.md`, `steering/`); relocating it into a doc appendix would
  just move the litigation. `CLAUDE.md` already carries the phase record agents
  need, so there is nothing to preserve that is not already preserved elsewhere.

## Open decisions (defaults set; candidates for user confirmation)

- **Q1 — Public-facing host-neutrality: README *and* CHANGELOG (A2 + review
  finding). RESOLVED — Option A (user, 2026-09-01).** *README* (hexdocs main
  page): **fully host-neutral** — drop the named-Amesbury path-dep-umbrella
  section; keep the consumption *mechanism* (path dep vs. Hex) described
  generically. *CHANGELOG*: **carve `doc/changelog.md` out of the hard grep** (a
  changelog legitimately records the rename it performed) and **keep** line 5's
  `(previously the host's :amesbury_scraper)` migration note; reword only line
  13's "extraction plan Phases 1–8" clause. This preserves the one piece of
  actionable consumer migration info while clearing phase/history from the
  landing page.
- **Q2 — New guide's example depth (C4).** *Default:* illustrative-but-compilable
  `MyApp.*` example (mirrors `host_wiring.md`, which shows compilable snippets and
  points at `test/support/` as the working reference). *Alternative:* a fully
  runnable copy-paste app skeleton (heavier; risks staleness — the DESIGN spec
  warns against verbatim bodies that go stale).
- **Q3 — Release guard: WARN vs. hard-fail (A3).** *Default:* WARN. *Alternative:*
  hard-fail on any C2 hit at release (stronger, but can block a release on a
  future legitimate-but-matching string).
