# Docs Spec — ALLM.Pipeline

The published hexdocs describe **what the framework does now**, in the present
tense. They are not a record of how it got here: no development-phase numbering,
no "used to / no longer" narrative, no consumer-specific proper nouns. The
history lives in git + `CHANGELOG.md` + `steering/` + `CLAUDE.md` (the agent
guide, which ships in the tarball but is deliberately NOT a `docs/0` `:extra`, so
ExDoc never renders it) — do not relocate it into a `@moduledoc`/`@doc`.

This is the durable rule the sweep of `steering/2026-08-31_DOC_UPDATES.md`
applied and that every later moduledoc edit must keep applying. It is stated
**once, here**; `CLAUDE.md` and `agent-spec/CODE_REVIEW.md` point at it rather
than restating it.

**Scope.** The published surface is what ExDoc renders: every `@moduledoc` /
`@doc` in `lib/`, plus the `docs/0` `:extras` (`README.md`, `guides/*`,
`CHANGELOG.md`). `#` code comments never reach hexdocs — history in a comment is
out of scope and correctly stays (it documents *why the code is this way* for
maintainers, the same role as `CLAUDE.md`). So the honest oracle is the
**generated** `doc/*.md`, never `lib/*.ex`: a source grep conflates rendered
docs with comments. `doc/` is gitignored — regenerate it with `mix docs`, grep
it, never commit it.

**Rationale is preserved; only narrative is deleted.** Most historical sentences
in these moduledocs exist to explain a *current, non-obvious constraint* (why
teardown precedes the terminal write; why a validator returns quoted AST). The
rule rewrites those to present tense — it does **not** delete the explanation.
Over-stripping (losing the "why") is the failure mode the grep cannot catch; the
review lane must (see "What the grep can't see").

---

## C1 — The categorization decision rule

Every historical or host-specific fragment in a published doc falls into exactly
one of four categories. The action is fixed per category. This table is the
normative rule.

| # | Category | Recognizer | Action | Worked example (real, from this tree) |
|---|---|---|---|---|
| A | **Narrative history** | "Before Phase 4…", "used to carry", "X ported it until Phase Y", "widened from … to …", "As of 2026-08-13", any **ISO-dated rationale** ("Measured 2026-…", "Corrected 2026-…", "widened on 2026-…"), "predates", "retired", a **`batch N`** or **`extraction plan §…`** reference, a **`steering/20…` file reference** | **Delete the narrative.** If it was the only statement of a *current* fact, restate that fact in the present tense. The history itself lives in git + CHANGELOG + `steering/` — do not relocate it into the doc. | `pipeline.ex` moduledoc: *"Before Phase 4 an orchestrator was a plain module, and every one hand-wrote the same skeleton… its variations were the defects"* → *"The DSL owns the run skeleton — run creation, lineage-threaded step sequencing, the guard that fails-and-reraises, metrics, terminal complete — so a pipeline declares stages, not boilerplate. Hand-writing that skeleton is what produces the classic defects: a run that never terminates, steps passed `nil` lineage, an orchestrator with no rescue."* |
| B | **Phase / deviation tag on a still-true rule** | a parenthetical `(Phase 4 D3)`, `(Phase 4.5 Alternatives)`, `(Phase 4 D6)` appended to a sentence that is otherwise present-tense | **Delete the tag only;** keep the sentence. | `dsl/resource.ex`: *"## Why teardown runs BEFORE the terminal write (Phase 4 D3)"* → *"## Why teardown runs before the terminal write"* |
| C | **Consumer-specific example / name** | `meeting_agenda`, `MeetingAgendaPipeline`, `MeetingListScraper`, `MeetingImportanceScorer`, `MeetingsPipeline`, `CommitteePipeline`, `committee`, `Government`, `Ordinance`/`ordinance`, `Amesbury`/`amesbury`, `transform_ordinance`, `scrape_committee_list` and any other host proper noun (grep each swept page for `[A-Z][a-z]+[A-Z]` module-looking names and confirm each is either a package `ALLM.Pipeline.*` module or a generic `MyApp.*`) | **Genericize** to a host-neutral name (`MyApp.*`, a self-contained illustrative pipeline). The example must still read as *plausibly compilable*, not a fragment. Drop any "actually ships as of…" framing. | `pipeline.ex`'s flagship `MeetingAgendaPipeline` example → a generic `MyApp.ReportPipeline` (or similar) with the same construct coverage but no host domain. |
| D | **Live status framed historically** | "No production consumer as of Phase 4.5 — deadlined to Phase 5", "the guard is inert on every live path" | **Restate as present-tense status,** dropping the phase deadline; keep the substance (that the construct/guard has no in-tree consumer today). | `dsl/resource.ex`: *"No production consumer as of Phase 4.5 — deadlined to Phase 5…"* → *"No in-tree pipeline declares a `resource` yet; it exists for hosts whose steps hold external handles (a browser session, a DB connection) that must be released even when a run raises."* |

### What the grep can't see (review-lane obligation)

The hard grep (C2a) is a floor over an *enumerable* token set. Two blind spots
are the review lane's, not the grep's:

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
`host application`) is surfaced by the **soft advisory grep (C2b)** for
line-by-line review rather than gated — keeping the hard grep false-positive-free
while still mechanically flagging the host framing for the reviewer.

---

## C2 — The verification grep (banned patterns + positive control)

The published-surface check. Run after `mix docs` regenerates `doc/`. Emptiness
is success, so it ships with a positive control per `agent-spec/DESIGN.md`.

Two greps: a **hard** one that gates (must reach zero), and a **soft advisory**
one that surfaces host-framing for review (does not gate). The hard pattern is
anchored to structural forms — a phase number, a `batch N`, an ISO date, a
history verb, an Amesbury-domain proper noun — never a bare substring the new
prose could match. `HARD` is the single source of truth; the release-time guard
(`scripts/release.exs` `hexdocs_history_warning/0`) embeds the identical literal
as its `@hexdocs_history_pattern` attribute — an executable hand-copy that must
stay byte-for-byte in sync with this `HARD` fence (edit both together; the only
sanctioned difference is the Elixir `~r/.../` sigil escaping `steering\/20`,
whose `/` is the sigil delimiter). There is no automated drift guard on purpose
(a source-scanning test was rejected as brittle), so the two cross-reference
each other and are edited as a pair.

```bash
# Regenerate the literal published surface.
mix docs >/dev/null

# The single source of truth for the hard pattern.
HARD='[Pp]hases? [0-9]|\(D[0-9]|used to |no longer|predates|retired|Before Phase|As of 20[0-9][0-9]|20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]|batch [0-9]|extraction plan|steering/20|meeting_agenda|MeetingAgenda|MeetingList|MeetingImportance|MeetingsPipeline|CommitteePipeline|committee|Government|Scorer|Ordinance|ordinance|Amesbury|amesbury'

# (a) HARD — must return zero. (CHANGELOG is carved out — it records the rename
#     it performed; run --exclude=changelog.md over the whole surface.)
grep -rInE "$HARD" --exclude=changelog.md doc/*.md
echo "banned hits: $?"        # grep exit 1 (no match) == success

# (b) POSITIVE CONTROL — must return NON-zero. Proves the grep + corpus work
#     (a typo'd pattern or empty doc/ would make (a) falsely pass).
grep -rIl 'Pipeline' doc/*.md | head -1   # expect at least one file

# (c) SOFT ADVISORY — host-framing the hard grep deliberately excludes; NOT a
#     gate. Read to zero by the code-review lane, page by page (see "What the
#     grep can't see"). Some 'umbrella' lines may legitimately survive as
#     generic "umbrella application"; the reviewer decides per line.
grep -rInE 'umbrella|host application' doc/*.md   # advisory — review, do not gate
```

**The hard grep is a floor, not a completeness oracle.** It catches an
*enumerable* token set (a phase number, a `batch N`, an ISO-dated rationale, an
Amesbury-domain proper noun). It cannot catch host-framing paraphrase — an
"umbrella lends its run" sentence reworded generically, a rationale whose date
was dropped. Grep-zero is necessary, not sufficient; the residual is the
code-review lane's charge (C2b + "What the grep can't see").

---

## C3 — The `mix docs` zero-warning invariant

`mix docs` emits ExDoc warnings on broken autolinks. The invariant:

```bash
mix docs 2>&1 | grep -iE 'warning|error'    # expect: no output
```

**Where the warning actually comes from.** ExDoc warns only on a **resolvable
module with an unresolvable member** — a backticked
`ALLM.Pipeline.Text.no_such_fun/9` warns; a fully **invented** name does *not*,
whether fenced or inline (`` `MyApp.NonExistent` `` and `` `MyApp.NonExistent.foo/1` ``
both produce no warning). `mix.exs` corroborates: ExDoc "warns when the target is
private or hidden" — i.e. a known module, an unknown/hidden member. So the real
hazard of a genericizing rewrite is **not** the invented `MyApp.*` names (safe
anywhere); it is a genericized example that **retains a real
`ALLM.Pipeline.*.fun/arity` reference whose arity no longer matches**, or a
leftover backticked host module (`MeetingImportanceScorer.Output`) that once
resolved against a host but never against the package. After each rewrite,
confirm every retained backticked `Mod.fun/arity` resolves, and run the
zero-warning check above.
