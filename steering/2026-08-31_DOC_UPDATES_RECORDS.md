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
