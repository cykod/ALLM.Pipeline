# Code Review Spec — ALLM.Pipeline

Code-QUALITY review: DRY, YAGNI, Rule of 3, reuse, architectural fit. Not a
behavioral test (that's `REVIEW.md`) and not a security audit. Every finding:
`file:line`, the invariant violated, severity (Blocker / Finding / Nit), and a
concrete proposed fix. Lead with architectural-invariant findings — they are
unique to this codebase and the most expensive to discover later.

## Architectural invariants (this repo)

- **Nothing depends on a host.** No consumer namespace in `lib/` (the compiler
  enforces names — flag the near-misses it can't see: new reads of host config
  keys, host-shaped assumptions in defaults). No new dep in `mix.exs` to make a
  reach compile — the reach is the bug (`CLAUDE.md` §1).
- **Exactly one `repo/0`**: `ALLM.Pipeline.Config`. A second anywhere in `lib/`
  is a Blocker; a test pins the set (`CLAUDE.md` §1).
- **Seams resolve at runtime through the Registry.** A module literal where an
  `impl/0` lookup belongs is a Blocker. A new mandatory `@callback` without stubs
  on every in-tree implementer — `.exs`-defined test doubles included — is a
  Blocker (`CLAUDE.md` §1).
- **Serializability.** Any fun, PID, ref, connection handle, or credential on a
  data struct is a Blocker — it breaks round-trip and risks leaking secrets;
  those resolve at call time.
- **Migrations never import schema modules** — raw queries + string table names.
  Production DDL belongs in the host; `priv/test_repo/migrations/` is harness-only.
- A test that observes what the test harness itself installs is observing the
  harness, not the framework (`CLAUDE.md` §5).

## Deliberate non-uniformities — do NOT flag

Each of these is argued in `CLAUDE.md`; "fixing" one wastes a fix pass and
teaches the next agent to undo a decision:

- The Registry's `put_new`-vs-`put` split across seam and non-seam keys (§6).
- The sequential and concurrent fan-out paths handling a raising item differently
  (§7 — the concurrent wrap is link safety, not policy).
- Two complete-or-fail tails: `Lifecycle.owned_run/4` AND `Executor.finish_run/2`
  (§7 — different callers; a THIRD copy is a Blocker).
- Teardown-error metadata written by two different channels (§7 — Ecto drops
  unchanged maps).
- The `:allm_pipeline` config namespace hardcoded per seam module rather than
  centralized into one `otp_app/0` accessor (§1 — churns 40+ sites for no
  behavioral gain, and the house style distrusts singleton accessors).

## Heuristics

- **Rule of 2 for semantic clones**: two implementations differing only by a
  guard, clause order, or `def`/`defp` is the extraction trigger; extraction
  migrates EVERY copy in the same commit. Near-duplicate adapter bodies free to
  diverge stay parallel.
- **Hand-mirrored sets need membership guards**: a rule or vocabulary enforced in
  more than one shape (lookup tables, tag lists, arity tables) gets a test that
  pins the exact set — the `:dynamo` tag list and `__hook_arities__/0` are the
  house patterns. A copy synced only by a comment is a Finding.
- **Error-atom vocabulary**: check new atoms against
  `grep -rhoE '\{:error, :[a-z_]+' lib | sort | uniq -c` — a new `:missing`
  beside an established `:not_found` is a Finding.
- **Automatic highs**: public function without `@spec`; a spec'd change with no
  dialyzer run; `{:error, term()}` in a spec; `String.to_atom/1` on external
  input; error strings instead of structs; a `try/rescue` that neither logs nor
  returns; a committed secret.
- **YAGNI**: options, fields, and error branches with a single caller and no
  design-stated future use. This codebase's speculative-generality attractor is
  DSL options — a construct with zero production consumers shipped green four
  times; ask "who declares this?"
- **Comment-tense greps** over touched files: future-tense claims about unbuilt
  siblings, and stale "not yet"/"no caller" claims the diff itself falsified —
  the second licenses a cleanup pass to delete something load-bearing.
- **Published-doc history**: flag category-A/B/C patterns in a touched
  `@moduledoc`/`@doc` — development-phase numbering, "used to / no longer"
  narrative, `batch N` / `extraction plan` / `steering/20…` references, or
  consumer-specific proper nouns (`meeting_agenda`, `committee`, `Amesbury`, …).
  The hexdocs are present-tense and host-neutral; rationale is preserved, only
  narrative deleted. Watch the two things the release-time grep can't: an
  over-stripped rewrite that lost the "why", and host framing paraphrased
  generically. Cite `agent-spec/DOCS.md` (C1 table + "What the grep can't see").
- **Test smells**: a conjunctive test whose later conjuncts a first-assertion
  failure masks; an assertion on a raw config literal a normalizer rewrites; a
  new callback obligation with no test exercising the real consumer.

## Severity routing

High/Blocker = this batch's fix pass. Medium = the next subphase's design or
hand-off notes (a fix that belongs in unwritten code goes in that code's design,
not a TODO comment). Low = phase-end polish. Write findings to
`.work/code-reviews/`.
