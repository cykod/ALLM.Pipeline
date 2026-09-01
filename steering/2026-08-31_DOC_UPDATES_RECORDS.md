# DOC_UPDATES — Records (deviations, closure ledger, verification transcripts)

Companion to `steering/2026-08-31_DOC_UPDATES.md`. Per-subphase records live here;
the design doc's Status table and checkboxes are the orchestrator's to tick.

---

## Subphase 1 — Agent-spec rule + verification harness

**Status: Completed.** (Code review: ship as-is, 1 Medium F1 closed via reciprocal
cross-references; security: no issues; functional/design: N/A. Gates green.)

### Files created / modified

**NEW**
- `agent-spec/DOCS.md` — the durable rule: C1 decision table (verbatim), C2 grep
  recipe (HARD + positive control + soft advisory), C3 zero-warning invariant +
  the ExDoc "resolvable module / unresolvable member" note, and the "What the
  grep can't see" review-lane obligation. States the rule once (not duplicated
  into CLAUDE.md).
- `steering/2026-08-31_DOC_UPDATES_RECORDS.md` — this file.

**MODIFY**
- `scripts/release.exs`:
  - Added `@hexdocs_history_pattern` module attribute (near the other attrs,
    ~:113) — an Elixir `~r/.../` sigil mirroring the C2 `HARD` literal byte-for-byte.
  - Added `defp hexdocs_history_warning/0` (after `migration_touch_warning/1`,
    step-6c region). Runs `System.cmd("mix", ["docs"], stderr_to_stdout: true)`
    — the script's FIRST `mix docs` run (verified: none existed) — then greps the
    regenerated `doc/*.md` (excluding `changelog.md`) for the pattern in-process
    (`Path.wildcard` + `Regex.match?`, not shelling to `grep`, to avoid the
    `[`/`(`/`|`/`/` shell-escaping trap). On a hit it WARNs through the same
    `IO.puts(:stderr, ...)` advisory channel as the `Excluding tags` /
    migration-touch warnings, with the count and the text "hexdocs still contain
    development-history references — see agent-spec/DOCS.md", then lists the
    `file:line: line` hits. Never aborts.
  - Wired the call as `log_step("step 6c", ...)` beside `migration_touch_warning`
    (~:256).
- `CLAUDE.md` — one pointer line after the intro block: "Published hexdocs are
  present-tense and history-free — see `agent-spec/DOCS.md`." (Rule not restated;
  CLAUDE.md keeps its own phase history.)
- `agent-spec/CODE_REVIEW.md` — one review-lane bullet under Heuristics
  ("Published-doc history"): flag category-A/B/C patterns in touched
  `@moduledoc`/`@doc`, cite `agent-spec/DOCS.md`.

**CONFIRMED, no edit** — `mix.exs` hex `package` `files:` already ships `guides`
wholesale (`mix.exs:63` → `~w(lib guides priv/test_repo/migrations …)`). Subphase
4's new guide reaches the tarball with no `files:` change.

### Deviations

- **D1 — In-process grep instead of shelling to `grep`.** The design says the
  guard "greps `doc/*.md`". Implemented with `Path.wildcard/1` + `Regex.match?/2`
  rather than `System.cmd("grep", …)`. Reason: the `HARD` pattern contains `[`,
  `(`, `|`, `/` — shell-quoting it correctly through `System.cmd` argv is a trap,
  and an in-process regex is the same pattern with no escaping surface. The
  pattern literal is kept byte-for-byte in step with `agent-spec/DOCS.md` C2 (a
  header comment on `@hexdocs_history_pattern` says so). Behaviour is identical:
  WARN-not-abort, `--exclude=changelog.md` semantics preserved by
  `Enum.reject(basename == "changelog.md")`.

### Verification transcripts (run 2026-09-01, pre-sweep tree)

`mix docs` regenerates the gitignored `doc/`; greps run against that fresh output.

```
mix docs >/dev/null                                  # exit 0
grep -rIlE "$HARD" doc/*.md | wc -l          -> 33   # >0: hard pattern fires (control)
grep -rIl 'Pipeline' doc/*.md | head -1      -> doc/ALLM.Pipeline.Artifacts.Tiered.md   # non-empty (positive control)
grep -rInE 'umbrella' doc/*.md | wc -l       -> 29   # >0: soft advisory fires (control)
grep -rlE "$HARD" --exclude=changelog.md doc/*.md | wc -l  -> 32   # release-guard scope: >0 today
```

Release guard's exact Elixir logic (`@hexdocs_history_pattern` +
`Path.wildcard`/`Regex`), run standalone against the regenerated docs:

```
hit lines: 174        # guard fires; sample:
  doc/ALLM.Pipeline.ArtifactStore.md:33: ## Tiering is an adapter choice (Phase 7)
  doc/ALLM.Pipeline.ArtifactStore.md:35: This module no longer routes by size ...
  doc/ALLM.Pipeline.Executor.build_envelope/3 no longer truncates ...
```

So `hexdocs_history_warning/0` fires on today's (pre-sweep) tree and WARNs — its
positive control. It will go silent after subphases 2–3 drive the hard grep to
zero.

`scripts/release.exs` parses/compiles clean (`elixir -e 'Code.compile_file(...)'`
— the module fully evaluated before `main` hit the expected arg-parse
`System.halt(1)`; the `~r` sigil is valid).

### `mix precommit`

Green. Environment: run from inside the devcontainer, so per CLAUDE.md §2 the
host Postgres was reached with `DATABASE_HOST=host.docker.internal
DATABASE_USER=pascalrettig` (the default `postgres` role does not exist on the
host DB — a bare `mix precommit` fails with `role "postgres" does not exist`).

```
DATABASE_HOST=host.docker.internal DATABASE_USER=pascalrettig mix precommit
  ...
  3 doctests, 600 tests, 0 failures        # no "Excluding tags" line — :dynamo set ran
  PLT is up to date! ... Total errors: 0   # dialyzer clean
  precommit exit: 0
```

The `[error] Refusing to … pipeline run …` log lines during `store_test` are the
designed ownership-refusal log noise, not failures (0 failures).

`mix dialyzer` was exercised (it is in `precommit` since 2026-08-31) and passed;
no `@spec` was touched — spec/script/doc edits only.

---

## Subphase 2 — Sweep batch A (DSL / lifecycle / executor cluster)

**Status: Completed.** (Applied the C1 rule to the 11 batch-A
`@moduledoc`/`@doc`/`@typedoc` strings. Code review: ship as-is, 0 findings —
over-strip guard clean (every current constraint survived in present tense), all
5 flagship constructs verified present, host-framing genericized, autolinks safe;
security/functional/design N/A. Gates green — see transcripts.)

Only `@moduledoc`/`@doc`/`@typedoc` strings were edited. No `#` code comment, no
`@spec`, no function body, no `iex>` block was touched (no batch-A moduledoc
carries a doctest — confirmed by grep). Several `#` comments in these files carry
`Phase N` / `used to` history and were **deliberately left** — ExDoc never
renders them (they are maintainer notes, per DOCS.md Scope).

### Per-file summary (categories applied)

- **`lib/allm/pipeline.ex`** (flagship) — **A**: rewrote the "Before Phase 4…"
  motivation to present tense (the DSL owns the run skeleton; hand-writing it
  produces the classic defects). **C**: replaced the whole `MeetingAgendaPipeline`
  / `meeting_agenda` / `MeetingListScraper` example with a self-contained
  `MyApp.ReportPipeline` (all five flagship constructs retained — see map below);
  genericized `poi_thumbnails` → `thumbnails`, the `ProjectEnrichmentPipeline`/
  `ProjectRefreshPipeline` child-run example, and the four-row host `--dry-run`
  table → a two-meaning generic table (present-tense: framework's `dry_run:`
  implements "skip everything", `skip_when:` expresses "skip only the write").
  **B**: dropped `(D2)`/`(D3)`/`Phase N` tags throughout (skip-log, lineage,
  resource, section-log paragraphs). Host-framing: `umbrella pipeline lends its
  run` → `outer pipeline` / `lender` / `owner` (borrowed-run section).
  Over-strip guard: every current constraint (accumulator write-channel, flat vs
  chained lineage, sequential-vs-concurrent catch, teardown-before-terminal,
  dry+borrowed mutual exclusion, ownership no-third-mint) verified still present.
- **`lib/allm/pipeline/llm_step.ex`** — **A**: rewrote "An LLM step used to carry
  four parallel artifacts… Phase 2… Phase 3.1" → present-tense "the Output
  declaration is the single authority". **C**: `transform_ordinance`/`ordinance`
  → `transform_record`/`record`; `MeetingImportanceScorer.Output` →
  "an Output that omits it"; `OrdinanceTransformer`/`KeyProvision`/
  `parse_provisions` host nouns genericized (`Provision.t()`), `projects.scale`
  → "a string column". **A**: dropped `Measured 2026-08-19` / `widened on
  2026-08-19` / `bill_number` narrative, keeping the current fact (the list-level
  rules cover `[String.t()]`; a malformed payload fails the step). Reworded three
  `no longer` / `used to` sentences to present tense (they name current
  behaviour, but the token is hard-banned).
- **`lib/allm/pipeline/executor.ex`** — **C**: moduledoc `CommitteePipeline,
  MeetingsPipeline` → "Specific pipelines". **A/B**: `(Subphase 2)` tag dropped;
  `resume/2` `@doc` stripped of `steering/…` refs, dated user-decision, and
  "Phase 7 (§3.11)" (kept: does-not-replay, non-owning-handle,
  assume-ownership-explicitly, no-production-callers). Host-framing: borrowed_run
  `@doc` `umbrella` → `outer pipeline`/`lender`. (The `store_test` runtime error
  message still says "umbrella" — it is a function body, not a doc, and never
  reaches `doc/*.md`.)
- **`lib/allm/pipeline/dsl.ex`** — **B**: `(Phase 4 D6)`, `(Phase 4 D3)` tags
  dropped. **C**: `MeetingListScraper` → `MyApp.ListScraper`,
  `CommitteeDetailScraper` → `MyApp.DetailScraper`, `committee_cache` →
  `warm_cache`. **A**: `fan_out` `@doc` "body:-mode form was removed in Phase
  4.5" → present-tense "to fold a body over items, call `FanOut.reduce/5`". (The
  `(Phase 4 D10)` in the `metrics` macro's `raise` message is a function body,
  not swept, and does not reach docs.)
- **`lib/allm/pipeline/fan_out.ex`** — **A**: dropped `Measured 2026-08-13 (n=8…)`
  and "a consumer's rescale service" → "measured behaviour of `Task.async_stream`";
  deleted the "One ported committee pipeline… until Phase 4.4" paragraph (its
  current fact — the single framework site — is already in the Sites table).
  **B**: `(Phase 4.5 Alternatives)`, `Phase 4.5 removed`, `Phase 4 D2` tags
  dropped. Fixed a now-dangling `ProjectRefreshPipeline` cross-reference in
  `reduce/5`'s `@doc` (the moduledoc it pointed at is now generic).
- **`lib/allm/pipeline/context.ex`** — **A→present**: "since Phase 4" and "Phase 4
  widened context/0 from a bare map" → present-tense (`context/0` is this struct).
  **B**: `(Phase 4 D5)`, `(Phase 4 D4)`, `(Phase 4 D2)` tags dropped; the
  `resources` table row lost its `Phase 4.3`/`4.1` parenthetical. **C**:
  `meeting_agenda`'s nine-key stats example → "a multi-key stats map".
- **`lib/allm/pipeline/dsl/resource.ex`** — **B**: `(Phase 4 D6)`, `(Phase 4 D3)`
  (heading + body) tags dropped. **D**: the "No production consumer as of Phase
  4.5 — deadlined to Phase 5" blockquote → present-tense "No in-tree consumer
  yet… exists for hosts whose steps hold an external handle". `Phase 4 exists to
  close` → "the lifecycle guard exists to close". (`Playwright`/`GenServer` kept
  — generic tech names, not in HARD; the `OpenGov` in a `#` comment untouched.)
- **`lib/allm/pipeline/lifecycle.ex`** — **A**: "Before Phase 4 the tree carried
  four orchestrator entry points…" → present-tense hazard statement; `guard/2`'s
  "two orchestrators in this tree had only a `rescue`" → present-tense ("a
  `rescue` never sees an exit or a throw"); `finish_run/2` "the defect that put
  four such entry points in the tree" → "the orphan-run defect this module exists
  to close". **B**: two `(Phase 4 D3)` tags + one `D3's ordering` reference
  dropped.
- **`lib/allm/pipeline/dsl/item.ex`** — **C**: `committee`'s `ok_items/1` and the
  `committee` chaining example → generic (`ok_items/1` filter; "a chained tree").
  **B**: `(Phase 4 D2)` dropped. **A**: "The field was named `value` through
  4.1's implementation…" → present-tense rationale for the `result`/`input`
  naming.
- **`lib/allm/pipeline/dsl/stage.ex`** — **B**: `(Phase 4 D6)`, `(D4)`,
  `(removed in Phase 4.5.3)` tags dropped. **A**: `carry:`-on-`fan_out` rejection
  reworded to present tense; the `carry:` miss-warning's "(user decision,
  2026-08-21 — …)" parenthetical → present-tense rationale.
- **`lib/allm/pipeline/dsl/runtime.ex`** — host-framing only: two `umbrella`
  occurrences (moduledoc Ownership + `run/3` `@doc`) → `lending pipeline` /
  `lender`. (All other runtime.ex `Phase`/`D`/`umbrella` hits are `#` comments —
  untouched.)

### Flagship five-construct map (`pipeline.ex` `MyApp.ReportPipeline`)

1. **External-`defp` atom hook stage** — `stage :record, :fan_out_records` with
   `defp fan_out_records(ctx, prev)` defined *outside* the module body. ✓
2. **`FanOut.reduce/5` returning the lineage-transparent 2-tuple** — body returns
   `{{:ok, items}, acc}`. ✓
3. **Escape-hatch stage** — `stage :tally, :tally_run`, with the property stated:
   "writes no step log and does not move the lineage parent, so a
   structural-identity gate does not see it". ✓
4. **`{item_result, acc}` accumulator write-channel** — stated in the `:tally`
   comment and in the "only write channel" section. ✓
5. **`metrics` + `summarize`** — `metrics "records", from: :funnel` /
   `summarize :finalize`. ✓

Confirmed present in the rendered `doc/ALLM.Pipeline.md` (grep hit lines 36, 42,
44, 45, 51–53, 61).

### Deviations

- **D2 — genericized host proper nouns beyond the HARD token set.** DOCS.md C1-C
  says "any other host proper noun". Several names not in the HARD grep
  (`ProjectRefreshPipeline`, `ProjectEnrichmentPipeline`, `PoiThumbnailPipeline`,
  `VideoPipeline`, `RvcsPipeline`, `OrdinanceTransformer`, `KeyProvision`,
  `bill_number`, `projects.scale`) were genericized or dropped, because they are
  host-domain examples the same rule targets. The grep alone would have passed
  them; the review-lane "host-framing paraphrase" obligation is why they went.
- **D3 — reworded present-tense `no longer` / `used to` sentences.** Three
  sentences in `llm_step.ex` (and one each in `context.ex`, `fan_out.ex`) used
  "no longer" / "used to" to state *current* behaviour, but those are hard-banned
  tokens. Reworded to plain present tense with the same meaning rather than
  deleted (over-strip guard).
- **No behavioral / spec change**, so `agent-spec/REVIEW.md` (behavioural) is N/A
  and `mix dialyzer` needed no separate run beyond precommit's.

### Verification transcripts (run 2026-09-01, inside devcontainer)

`doc/` is gitignored — regenerated with `mix docs`, greps run against the fresh
output; nothing under `doc/` committed.

```
mix docs >/dev/null                                    # exit 0
# BATCH_A HARD grep ($HARD from C2) over the 11 batch-A pages:
grep -InE "$HARD" $BATCH_A                              # NO OUTPUT (grep exit 1)
# umbrella advisory over batch-A pages:
grep -InE 'umbrella' $BATCH_A                           # NO OUTPUT (grep exit 1)
# positive control:
grep -rIl 'Pipeline' $BATCH_A | head -1                # doc/ALLM.Pipeline.LLMStep.md
# C3 zero-warning:
mix docs 2>&1 | grep -iE 'warning|error'               # NO OUTPUT (grep exit 1)
# whole-surface (batch-B still expected non-zero — subphase 3's job):
grep -rIlE "$HARD" --exclude=changelog.md doc/*.md \
  | grep -E 'ALLM.Pipeline.md|LLMStep|Executor|Dsl.md|FanOut|Context|Dsl.Resource|Lifecycle|Dsl.Item|Dsl.Stage|Dsl.Runtime'
                                                        # (empty — no batch-A page regressed)
grep -rInE "$HARD" --exclude=changelog.md doc/*.md | wc -l   # 72 (all batch-B)
```

Pre-sweep the batch-A pages carried **101** HARD hits and **10** `umbrella`
advisory lines; post-sweep both are **zero**.

### `mix precommit`

Green. Per CLAUDE.md §2 (run inside the devcontainer) with
`DATABASE_HOST=host.docker.internal DATABASE_USER=pascalrettig`.

```
DATABASE_HOST=host.docker.internal DATABASE_USER=pascalrettig mix precommit
  ...
  3 doctests, 600 tests, 0 failures        # no "Excluding tags" — :dynamo set ran
  PLT is up to date! ... Total errors: 0   # dialyzer clean
  precommit exit: 0
```

The `[error] Refusing to … pipeline run …` log lines during `store_test` are the
designed ownership-refusal log noise, not failures (0 failures). No `@spec` was
touched — doc-string edits only.

---

## Subphase 3 — Sweep batch B (remaining modules + README + CHANGELOG)

**Status: Completed.** (Applied the C1 rule to the 20 batch-B
`@moduledoc`/`@doc`/`@typedoc` strings, plus `README.md` (Q1 = Option A, fully
host-neutral) and `CHANGELOG.md` (Q1 = Option A, `:amesbury_scraper` note kept,
phase clause reworded). Code review: ship as-is; its one Low note was elevated to
deviation D6 and fixed (two un-manifested files, `json_schema.ex` +
`llm_call_log.ex`, carried host-specific refs via non-HARD tokens — genericized).
Security/functional/design N/A. Gates green. After this batch the WHOLE published surface's HARD grep
is zero (CHANGELOG carved out). Local gates green — see transcripts. Review lanes
not yet run — the orchestrator ticks the design's Status table.)

Only `@moduledoc`/`@doc`/`@typedoc` strings were edited. No `#` code comment, no
`@spec`, no function body, no `iex>` block was touched. `text.ex`'s two live
doctests (`normalize/1`, `truncate/2`) were preserved verbatim — its banned hits
sat in the moduledoc, well away — and `mix precommit`'s `3 doctests` confirms
they still run. Many `#` comments in these files carry `Phase N` / `used to` /
dated history and were **deliberately left** — ExDoc never renders them
(maintainer notes, per DOCS.md Scope).

### Per-file summary (categories applied)

- **`pipeline_run.ex`** — **A/D**: "As of 2026-08-13 the guard is inert on every
  live path… 28 fail / 17 complete sites" → present-tense "a membership guard
  against the next call site; every live site holds a `create/3` handle, so none
  trips it today" (the completion-token guard's *what it prevents* preserved).
  "`fail/2` … which it no longer is" → "`fail/2` is ownership-guarded like the
  other terminal writers". **C** (host-framing): every borrowed-run "umbrella
  lending its run" / "the umbrella's aggregate metadata" → "outer pipeline" /
  "owner" / "lender" (matching batch A). Dropped the `VideoSummaryPipeline` lends
  to `MeetingSummaryPipeline` production example and the "user decision,
  2026-08-13" parenthetical. `"video_summary"` slug examples in `list/1` → generic
  `"daily_report"`.
- **`metrics.ex`** (the grep-invisible page) — **C**: "sole completer for
  umbrella/borrowed runs" → "the owner is the sole completer, so metrics are
  emitted once per run, on the owning handle" (role preserved). **A**: "batch 1.C
  moved it off a hardcoded `@expects_data_pipelines`" dropped (declaration is now
  the whole story); "the two namespaces do not line up (extraction plan §3.8a)" →
  namespace sentence kept, cite dropped; "structural-identity property from
  Phases 1-6" → "structural-identity property".
- **`config.ex`** — **A**: "_(Decided in batch 1.B, 2026-08-14 … see
  `2026-08-10_ALLM_PIPELINE_PHASE_1.md` §5.1.)_" blockquote deleted (the `repo/0`
  single-handle rationale that follows it — four consumers, two outside `Store` —
  is untouched); "landed in batch 1.C" (×2) reworded to present; "extraction plan
  §1.3c" / "moved onto the registry in batch 1.C" → "host facts, declared on the
  host's registry"; "(added by the Phase 1 polish pass)" tag dropped. `lock_keys`
  example `[project_refresh: :project]` → `[some_refresh: :some]` (the file's own
  other examples' convention).
- **`query.ex`** — **A**: "the host cutover (Phase 7.2)" / "since Phase 7.1 … an
  in-umbrella dep then, the Phase 8 path dep now" → present-tense "a host routes
  its reads through this module … keeps the host depending on the package and
  never the reverse". **C + C3 autolink**: `Government.resolve_step_log/1`
  (unresolvable host module, ExDoc hazard) removed — reworded to "a host resolves
  a step log's identity through here"; "(7.2)" cites on `llm_artifact_url/2`
  dropped ("how deep to walk is host policy").
- **`step_log.ex`** — **A**: dropped "subphase 2.2's tuple clause turned …",
  "measured 2026-08-14", the `refsweep.py` "→ 1 hit" dated re-derive block, the
  "closed once, by tracing … `.work/security-reviews/2026-08-14-allm-p2c.md`,
  Informational 4 … since Phase 5.10" trace, "through Phase 6", "wired … in Phase
  7.4" — every current constraint preserved (the changeset silent-write hazard,
  the `prepare_changes/2` raise, the standing `%Ecto.Changeset{}`-clause fix,
  `create_skipped/4`'s zero-duration `:skipped` behaviour). **C**: `meeting_agenda_scrape`
  ~2600-row / measured-2026-08-21 figure → "a large scrape can reach a few
  thousand rows / several MB"; "the video↔meeting match-decision log" → "a
  match-decision log".
- **`encodable.ex`** — **A**: the whole "Two divergent copies used to exist —
  `Executor.normalize_metadata/1` and `PipelineRun.stringify_keys/1`" origin story
  and its "Came from" table column collapsed to a present-tense "the metadata
  create path applies encoding twice … one implementation that is a fixed point".
  "Phase 2.2 converged the leaves" → "the two serializers converge on the leaves";
  two "(Corrected 2026-08-14 … code review F3)" parentheticals deleted; "used to
  raise now serializes silently" → "instead of raising, such a struct serializes
  silently" (the credential-leak constraint preserved); "the global-by-name wart
  Phase 2 removed from `StepLog`" → "the wart per-field `log:`/`redact:` flags
  exist to remove"; "in subphase 2.3" cite dropped.
- **`artifacts.ex`** — **A**: "Batch 1.C moved *which module* onto …" → "*Which
  module* is chosen at a host's compile time by its registry"; "(Phase 7.5)" /
  "Since Phase 7.5 … no longer discards … no longer drops bodies" → present-tense
  "`Tiered` gives an oversize artifact a real home … does not drop bodies";
  `gc/1`'s "no Phase 1 caller … the Phase 7 item (extraction plan §3.6)" →
  "nothing in the framework dispatches to it yet — it exists for a host that wants
  retention/TTL". (tiering-is-adapter-choice rule preserved.)
- **`schema.ex`** — **C**: `values: Schemas.Ordinance.fiscal_impacts()` →
  `values: MyApp.Schemas.impacts()`; `projects.scale` string-column example →
  "a field backed by a string column". **A/D**: `redact:` "Four paths … subphase
  2.3 closed the second … they used to `inspect/1`" → present-tense "four paths
  lie outside its reach; one … is closed in code; three remain" (all four still
  enumerated). "(extraction plan Phase 3.2)" cite dropped.
- **`lock/advisory.ex`** — **A**: "batch 1.C moved it onto the host's registry" /
  "batch 1.C moved it off two hardcoded clauses" → present-tense "host domain
  knowledge, declared on the host's registry"; "a consumer repo's
  registry-declared-values test" kept as the host-side guard. **C**: "an ordinance
  pipeline still grinding through PDFs" → "a document pipeline".
- **`artifact_store.ex`** — **B**: heading "## Tiering is an adapter choice
  (Phase 7)" → "## Tiering is an adapter choice". **A**: "This module no longer
  routes by size … `build_envelope/3` no longer truncates … in two rounds" →
  present-tense "does not route by size … does not truncate … to fit an item".
- **`text.ex`** — **A**: "duplicated in the host's core app for Phases 1–6 …
  Phase 7.2 (2026-08-24) converged them … 7.1 … the Phase 8 path dep now" + two
  `steering/20…` file cites → present-tense "This module is the one home for text
  scrubbing: a host … calls `ALLM.Pipeline.Text.scrub/1` directly … no code path
  calls back into a host module". **Doctests preserved verbatim.**
- **`store.ex`** — **A**: "(batch 1.C)" (×2) dropped; "the extraction plan §3.2
  routes host reads" → "host reads route through"; "Phase 7.4 wired the three
  `ProcessingDecision` skip branches" → present-tense "a host's `ProcessingDecision`
  skip branches write a visible `:skipped` row". (`log_skipped/4` callback
  rationale preserved.)
- **`step.ex`** — **A/B**: `context` typedoc "Widened from a bare map in Phase 4
  (D5)" → present-tense "`run_with_step_log/5` always builds this struct, so the
  type names it". **C**: `step_type` callback example `:scrape_committee_list` →
  `:fetch_page`.
- **`artifacts/dynamo.ex`** — **A**: `exclusions/0` `@doc` "since Phase 8 they
  live in DIFFERENT repos" (×2) → "they live in DIFFERENT repos" / "each host is a
  different repo entirely"; "PHASE_1 §5.5" precedent cite dropped. (cross-repo
  drift-guard rationale preserved.)
- **`registry.ex`** — **C**: `{CommitteePipeline, :run}` → `{MyApp.ReportPipeline,
  :run}` and "the host's `Runner`" → "a host's own runner"; "One SST cron schedule
  entry" typedoc → "One cron schedule entry". **A**: "the extraction plan's
  §3.8a/§3.8b codegen … shell/SST/stage-scraper consumers" → "a host's codegen …
  a host's shell/deploy/stage-scraper consumers"; "extraction plan §3.8a" cite in
  the `use` `@doc` dropped.
- **`lock.ex`** — **A**: "batch 1.C moved it off `Advisory`'s two hardcoded
  clauses … this package no longer carries it" → "host domain knowledge, and this
  package does not carry it … declared on the host's registry". **C**:
  `NarrativeGenerator`'s ~40s OpenAI-call example → "tens of seconds of model
  calls".
- **`store/ecto.ex`** — **C**: `committees.last_step_log_id` host FK example → "a
  host table may carry a real Postgres FK onto `step_logs.id`"; "the four
  migrations" → "the migrations".
- **`artifacts/tiered.ex`** — **A**: "the hard-coded S3 residue
  `ALLM.Pipeline.ArtifactStore` used to carry (architecture §3.6, §2.7)" → "a size
  decision hard-coded into `ALLM.Pipeline.ArtifactStore`".
- **`mix/tasks/allm_pipeline.names.ex`** — **C**: example JSON `"committee"` /
  `["project","project_refresh","video"]` → `"daily_report"` /
  `["listing","listing_refresh"]`; "the shell `stage-scraper.sh` … `sst/scraper.ts`
  … across four runtimes" → host-neutral "the shell scripts, deploy tooling and
  codegen … across several runtimes".
- **`mix/tasks/allm_pipeline.nilability.ex`** — **A**: "before subphase 2.4's
  follow-up the parse discarded all three of its elements" → present-tense "a typo
  … fails loudly rather than exiting 0"; the dated `refsweep.py` re-derive block +
  "(This paragraph previously claimed …)" correction + `apps` host-layout paths →
  a NUL-safe `grep … lib test` over the package's own trees.

### README (Q1 = Option A — fully host-neutral, hexdocs `main: "readme"`)

Deleted the "Extracted from a production Elixir umbrella (Phases 1–8 …)"
narrative and the entire "### The path-dep umbrella" section (named-Amesbury,
`~/Projects/ALLM.Pipeline`, `deploy.sh`, readonly-mount specifics). The
consumption *mechanism* stays, described generically: a host consumes it as a
path dep or (once published) a Hex requirement, wiring the same way through
`use ALLM.Pipeline.Registry`. Also genericized three residual host references:
"Same images and ports as the host umbrella's stack", "Unlike the umbrella's
devcontainer", and "Publishing does not change the host umbrella".

### CHANGELOG (Q1 = Option A — carved OUT of the hard grep)

**Kept** line 5's `(previously the host's :amesbury_scraper)` migration note
(actionable consumer-migration info). **Reworded only** line 13's clause:
"extracted from its original host umbrella (extraction plan Phases 1–8)" →
"Initial standalone release of `ALLM.Pipeline`". The whole-surface HARD grep runs
`--exclude=changelog.md`, so `doc/changelog.md` still carries the kept
`:amesbury_scraper` note — intended.

### Deviations

- **D4 — genericized host proper nouns beyond the HARD token set.** Same shape as
  batch A's D2. Names not in the HARD grep (`NarrativeGenerator`, `CommitteePipeline`
  as an `entry:` MFA example — actually a HARD token, caught either way,
  `project_refresh`/`project`, `video_summary`, `committees.last_step_log_id`,
  `Schemas.Ordinance.fiscal_impacts`, `projects.scale`, `stage-scraper.sh`,
  `sst/scraper.ts`, `SST`, `Runner`, `VideoSummaryPipeline`/`MeetingSummaryPipeline`)
  were genericized or dropped under the review-lane "host-framing paraphrase"
  obligation, not the grep.
- **D5 — reworded present-tense `no longer` / `used to` sentences.** Several
  sentences (`artifact_store.ex`, `artifacts.ex`, `pipeline_run.ex`,
  `tiered.ex`, `encodable.ex`, `nilability.ex`) used the hard-banned "no longer" /
  "used to" tokens to state *current* behaviour. Reworded to plain present tense
  with the same meaning rather than deleted (over-strip guard).
- **D6 — manifest omission: two un-listed files carried host-specific refs via
  non-HARD tokens (found in code review, fixed by the orchestrator).** The design's
  batch-A/B manifest was built from a HARD-token source grep, so it inherited that
  grep's blind spot: `lib/allm/pipeline/schema/json_schema.ex` and
  `lib/allm/pipeline/llm_call_log.ex` were never listed, yet their `@moduledoc`s
  named a specific host engine function (`LLMEngine.normalize_schema/1`,
  `LLMEngine.generate_structured/4`), a host test file
  (`derived_schema_normalization_test.exs`), and host domain nouns
  (`key_provisions`/`KeyProvision`) — all category-C leaks on published pages, none
  of them HARD tokens, so the C2 hard grep AND the C2b advisory (`umbrella|host
  application`) both missed them. This is exactly the "grep is a floor, not a
  completeness oracle" case the design's own C1 warns about, surfaced by the
  code-review lane (its charge for host-framing the grep can't see). Genericized in
  place, preserving each moduledoc's technical rationale: `LLMEngine.*` → generic
  "a host's engine" / "the host normalizer" prose (matching each file's existing
  nearby generic phrasing at `llm_call_log.ex:6` and `json_schema.ex:90`);
  `derived_schema_normalization_test.exs` → "a consumer repo's schema-normalization
  test" (CLAUDE.md §1 style); `key_provisions`/`KeyProvision` → `line_items`/`LineItem`.
  Re-verified: the host-specific identifiers are gone from `doc/*.md`, the
  whole-surface HARD grep stays zero, `mix docs` stays warning-free, `mix precommit`
  green (exit 0, dialyzer 0 errors). The clean-generic un-listed files (`llm.ex`
  with `MyApp.LLMEngine`, `telemetry.ex`) and the other unswept adapters
  (filesystem/memory/s3/noop/pipeline_metric — only cite this package's own
  `*_test.exs`) were left correctly untouched.
- **No behavioral / spec change**, so `agent-spec/REVIEW.md` is N/A and
  `mix dialyzer` needed no separate run beyond precommit's.

### Verification transcripts (run 2026-09-01, inside devcontainer)

`doc/` is gitignored — regenerated with `mix docs`, greps run against the fresh
output; nothing under `doc/` committed.

```
mix docs >/dev/null                                       # exit 0
# WHOLE-surface HARD grep ($HARD from C2), CHANGELOG carved out:
grep -rInE "$HARD" --exclude=changelog.md doc/*.md         # NO OUTPUT (grep exit 1)
# positive control:
grep -rIl 'Pipeline' doc/*.md | head -1                    # doc/ALLM.Pipeline.Artifacts.Dynamo.md
# umbrella / host-application advisory (whole surface):
grep -rInE 'umbrella|host application' doc/*.md
#   doc/Mix.Tasks.AllmPipeline.Nilability.md:142: … this package names no host application.
#   doc/host_wiring.md:11: Throughout, `MyApp` stands for your host application.
# C3 zero-warning:
mix docs 2>&1 | grep -iE 'warning|error'                   # NO OUTPUT (grep exit 1)
```

Pre-sweep the whole surface carried **72** HARD hits (all batch B) and **19**
`umbrella` advisory lines; post-sweep the HARD grep is **zero** and **no**
`umbrella` line survives. The two surviving advisory lines match `host
application`, not `umbrella`, and are both justified-generic: one states a fact
about the package (it names no host application), the other is in the
deliberately-untouched `host_wiring.md` defining the `MyApp` convention. The
reviewer reads them to justified-zero.

### Release guard goes silent

`scripts/release.exs`'s `hexdocs_history_warning/0` (its `@hexdocs_history_pattern`
+ `Path.wildcard`/`Regex`, `--exclude=changelog.md`) run standalone against the
regenerated docs:

```
guard hit lines: 0
```

It fired on the pre-sweep tree (Subphase 1 recorded 174 hits) and is now
**silent** on the swept tree — the positive-control → cleared arc the guard was
designed for.

### `mix precommit`

Green. Per CLAUDE.md §2 (run inside the devcontainer) with
`DATABASE_HOST=host.docker.internal DATABASE_USER=pascalrettig`.

```
DATABASE_HOST=host.docker.internal DATABASE_USER=pascalrettig mix precommit
  ...
  3 doctests, 600 tests, 0 failures        # no "Excluding tags" — :dynamo set ran;
                                           #   the Text doctest (3 total) preserved and passing
  PLT is up to date! ... Total errors: 0   # dialyzer clean
  precommit exit: 0
```

The `[error] Refusing to … pipeline run …` log lines during `store_test` are the
designed ownership-refusal log noise from a function body (`refuse/2`'s `Logger`
call — not a doc, never reaches `doc/*.md`), not failures (0 failures). No
`@spec` was touched — doc-string edits only.

---

## Subphase 4 — New guide `guides/building_a_pipeline.md`

**Status: Completed.** (Guide written, registered in `mix.exs` `docs/0` `:extras`,
reciprocal cross-links added. Code review: ship as-is; its one Low finding was
verified against runtime code as a real false published sentence and the two
rendered occurrences were fixed — see D7. Security/functional/design N/A. Gates
green: guide renders, zero ExDoc warnings, born-clean, whole-surface HARD grep
zero, `mix precommit` exit 0, dialyzer 0 errors.)

### D7 — a pre-existing false `metrics from:` doc, found in code review, fixed (rendered occurrences only)

The guide correctly documents that `metrics from:` receives the **accumulator**
(matching the flagship `pipeline.ex` example). The code-review lane noticed
`ALLM.Pipeline.Dsl`'s own docs contradicted this — `dsl.ex:217` `@doc` said
`from:` "receives the value `summarize` produced", and the hook-signature table
at `dsl.ex:41` listed its argument as `(summary)`. Verified against runtime code:
`runtime.ex:264` calls `record_metrics(metrics_module, run, state.acc)` and
`runtime.ex:326` applies `from.(acc)` — the hook receives the accumulator, and
the adjacent comment (`runtime.ex:260`) states "`from:` reads the ACCUMULATOR …
NOT `summary`". So the guide/flagship were right and `dsl.ex`'s two **rendered**
(`doc/ALLM.Pipeline.Dsl.md`) statements were false. Both fixed (doc-string only,
no behavioral change): table row → `(acc)`; `@doc` → "receives the accumulator —
the value the stages folded, the same input `summarize` sees". Post-fix:
`doc/ALLM.Pipeline.Dsl.md` consistent with the guide, zero ExDoc warnings,
whole-surface HARD grep still zero.

**Deferred to the user (out of this docs run's scope):** the identical factual
error survives in a compile-time **raise message** at `dsl.ex:228` ("an arity-1
hook taking what `summarize` produced"). That is behavioral surface (a raised
string, not rendered to hexdocs); correcting it would break this run's "no
behavioral code changes" invariant, so it is surfaced for a follow-up rather than
changed here. No test pins the wording.

### What the guide covers (C4)

An end-to-end application tutorial, the companion to `host_wiring.md`'s wiring
focus. Section outline:

1. **A typed step** — `@behaviour ALLM.Pipeline.Step` with `use
   ALLM.Pipeline.Schema` Input/Output; names `ALLM.Pipeline.Step`,
   `ALLM.Pipeline.Schema`, `ALLM.Pipeline.StepLog` (artifact/log flags),
   `ALLM.Pipeline.Executor.run_step/5`, `ALLM.Pipeline.Context` as normative.
2. **An LLM step** — `use ALLM.Pipeline.LLMStep` with `json_schema: true`
   Output; names `ALLM.Pipeline.LLMStep`; links to `host_wiring.md` §2 for the
   `llm:` seam.
3. **Composing a pipeline** — `use ALLM.Pipeline` with a `stage` over a Step, a
   declarative `fan_out` over a Step, `metrics`, `summarize`; names
   `ALLM.Pipeline`, and the accumulator / `FanOut.reduce/5` / `Context` /
   `PipelineRun.complete/2` contracts by pointing at the moduledoc.
4. **Running it** — the generated `run/1`, its return contract, the guard.
5. **Reading a run back** — `ALLM.Pipeline.Query` facade (`get_run`,
   `run_stats`, `lineage_tree`, `resolve_step_log`, `fetch_artifact`), the flat
   two-level lineage tree, `StepLog.build_lineage_tree/1`, artifacts via
   `ArtifactStore.fetch/1` / `Artifacts`.
6. **Where to go next** — reciprocal link back to `host_wiring.md` + module
   pointers.

Born present-tense, host-neutral, `MyApp.*` throughout (`MyApp.ListStep`,
`MyApp.SummarizeStep`, `MyApp.ReportPipeline`). No phase numbering, no dates, no
consumer names. Snippets are illustrative-but-compilable in shape (Q2 default),
pointing at `test/support/` as the working reference — not a runnable app
skeleton.

### Real `Mod.fun/arity` autolinks — every one resolves (C3)

The 10 backticked real `ALLM.Pipeline.*.fun/arity` references in the guide,
each confirmed public at the stated arity (grep of the module for `def <name>(`
+ default-arg expansion):

| Autolink | Confirmed |
|---|---|
| `ALLM.Pipeline.Executor.run_step/5` | `def run_step(pipeline_run, step_module, input_struct, input_step_id \\ nil, opts \\ [])` |
| `ALLM.Pipeline.FanOut.reduce/5` | `def reduce(ctx, items, acc, fun, opts \\ [])` |
| `ALLM.Pipeline.PipelineRun.complete/2` | `def complete(pipeline_run, result_metadata \\ %{})` |
| `ALLM.Pipeline.Context.input_step_id/1` | `def input_step_id(%__MODULE__{...})` |
| `ALLM.Pipeline.Context.accumulator/1` | `def accumulator(%__MODULE__{...})` |
| `ALLM.Pipeline.Context.resource/2` | `def resource(%__MODULE__{...}, name)` |
| `ALLM.Pipeline.Query.lineage_tree/1` | `def lineage_tree(step_log_id)` |
| `ALLM.Pipeline.Query.fetch_artifact/1` | `def fetch_artifact(url)` |
| `ALLM.Pipeline.StepLog.build_lineage_tree/1` | `def build_lineage_tree(step_id)` |
| `ALLM.Pipeline.ArtifactStore.fetch/1` | `def fetch(url)` |

Plus bare-module autolinks (always resolve): `ALLM.Pipeline`,
`ALLM.Pipeline.Step`, `ALLM.Pipeline.Schema`, `ALLM.Pipeline.LLMStep`,
`ALLM.Pipeline.Context`, `ALLM.Pipeline.StepLog`, `ALLM.Pipeline.Query`,
`ALLM.Pipeline.ArtifactStore`, `ALLM.Pipeline.Artifacts`,
`ALLM.Pipeline.PipelineRun`.

**Deliberately NOT backticked as `Mod.fun/arity`** (they are generated onto the
*consumer's* module, not the macro module — a `Module.fun/arity` link would
warn): `run/1`, `coerce/2`, `call_llm/1`, `json_schema/0`, `execute/2`,
`prompt/1`, `step_type/0`, `input_schema/0`, `output_schema/0`, `new/1`,
`cast/1`. Written in prose as bare `` `fun/arity` `` (no module) or as function
calls inside ``` fences ```, neither of which ExDoc autolinks from an extra.

### Registration + cross-links

- `mix.exs` `docs/0` `:extras`: added
  `"guides/building_a_pipeline.md": [title: "Building a pipeline"]` (keyword
  form, matching `guides/host_wiring.md`'s entry; no `groups_for_extras` exists).
- `README.md` "Host consumption" section: one-line pointer to the new guide
  after the host-wiring pointer.
- `guides/host_wiring.md` intro: reciprocal one-line pointer to the new guide
  (wiring ↔ application).
- `mix.exs` hex `package` `files:` already ships `guides/` wholesale
  (`~w(lib guides priv/test_repo/migrations …)`) — verified, no edit needed.

### Verification transcript

```
mix docs 2>&1 | grep -iE 'warning|error'              # NO OUTPUT (grep exit 1) — every real autolink resolves
test -f doc/building_a_pipeline.md                     # rendered: doc/building_a_pipeline.md

HARD (from C2) over the guide page:
grep -InE "$HARD" doc/building_a_pipeline.md           # NO OUTPUT (exit 1) — born clean

HARD over whole surface, CHANGELOG carved out:
grep -rInE "$HARD" --exclude=changelog.md doc/*.md     # NO OUTPUT (exit 1)

positive control:
grep -rIl 'Pipeline' doc/*.md | head -1                # doc/ALLM.Pipeline.Artifacts.Filesystem.md (non-empty)

mix precommit (DATABASE_HOST=host.docker.internal DATABASE_USER=pascalrettig):
  3 doctests, 600 tests, 0 failures
  PLT is up to date! ... Total errors: 0        # dialyzer clean
  precommit exit: 0
```

### Deviations

None. No `@spec` touched (doc + `mix.exs` extras edits only), so `mix dialyzer`
was unaffected — it nonetheless ran green as part of `precommit`.
