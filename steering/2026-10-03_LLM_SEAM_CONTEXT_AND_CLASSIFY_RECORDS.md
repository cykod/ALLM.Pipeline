# Records — The step's context at the LLM seam, and a ClassifyStep

Companion to `steering/2026-10-03_LLM_SEAM_CONTEXT_AND_CLASSIFY.md`. Bookkeeping
(status, checklist, deviations, measured facts) lives here; the design doc is
not edited during implementation. Its embedded Status table still reads
`Not Started` — this file is the current status.

## Status

| Subphase | Concern | Status |
|---|---|---|
| 1.1 | Context reaches the LLM seam; `call_llm/1` → `call_llm/2` | Completed (reviews + fix pass; fix-pass delta re-reviewed in batch 2's round) |
| 2.1 | Optional `classify/4` seam callback; allm floor 0.6.0 | Completed |
| 2.2 | `use ALLM.Pipeline.ClassifyStep` | Completed |

---

## 1.1 — implementation record (2026-10-03)

Built against `18f1161` (HEAD; `git diff --name-only 18f1161..HEAD` empty).
`mix.exs` / `mix.lock` (the user's in-flight allm bump, A5) untouched.

### Checklist

- [x] C1's `/2` + `/5` callbacks with `@doc` (preferred when exported; `/1` +
      `/4` stay mandatory; raise recommendation), `@optional_callbacks`.
- [x] C2 `__resolve_engine__/3` + `__generate_structured__/6` + `__context__/1`,
      `Code.ensure_loaded/1` first (one private `exports?/3`).
- [x] `ALLM.Pipeline.LLM` moduledoc gains "The step's context" — (a) opts are
      the host's, (b) the four popped keys / detached pops nothing, (c) escape-hatch
      bodies pass `ctx.opts`, (d) run options persisted to `pipeline_runs.metadata`.
      (c) also one sentence in `ALLM.Pipeline`'s "## Lineage".
- [x] C3 in `llm_step.ex`: `call_llm/2` (normalizes via `LLM.__context__/1`),
      `execute/2` passes `context`, `__call_llm__/4`; `call_llm/1` deleted.
      Moduledoc table and "The engine name…" section updated.
- [x] Prose renames: `llm.ex` (moduledoc, typedoc, `impl/0` doc),
      `llm_call_log.ex` ×2, `json_schema.ex`, `guides/building_a_pipeline.md`,
      `registry_test.exs` comment, `guides/host_wiring.md` §2 (context
      callbacks, raise recommendation, metadata hazard).
- [x] Hexdocs hygiene: no hidden `__…__` helper is backticked in a moduledoc or
      guide; `agent-spec/DOCS.md` HARD grep → 0 hits (exit 1), positive control
      returns a file; `mix docs` emits no warning.
- [x] Tests T1.1–T1.12; `OverridingStep` migrated; `test/support/lazy_llm_adapter.ex` added.
- [ ] Changelog input — carried to the milestone's `/changelog` (not written
      here): **Breaking** — "`call_llm/1` is replaced by
      `call_llm(context, input)`; an overriding `execute/2` passes its
      context." Other — "`ALLM.Pipeline.LLM` gains optional
      `resolve_engine/2` and `generate_structured/5`, receiving the step's
      `ALLM.Pipeline.Context`; preferred when exported."

### Test map

| Plan id | Where |
|---|---|
| T1.1–T1.4 | `test/allm/pipeline/llm_test.exs` — `__resolve_engine__/3`, `__generate_structured__/6` describes, "dispatch is per callback" |
| T1.5 | `llm_test.exs` — "a not-yet-loaded adapter is loaded before its exports are consulted" |
| T1.6 | `llm_test.exs` — "the context-taking callbacks are exactly the optional ones" |
| (C3 `__context__/1`) | `llm_test.exs` — `__context__/1` describe (added: a contract function the plan tests only indirectly) |
| T1.7 | `llm_step_test.exs` — "call_llm/1 does not exist; call_llm/2 does" |
| T1.8 | "a run option reaches both context-taking callbacks" |
| T1.9 | "a bare-map context…" / "a nil context…" (split — conjunctive test rule) |
| T1.10 | "Executor.run_step/5's options and lineage reach the seam" (DB-backed) |
| T1.11 | "a DSL run's options reach the seam" (`ContextPipeline` fixture at file top) |
| T1.12 | "an overriding execute/2 that fans out passes the context from every child" (`FanOutStep`) |

### Red-first evidence (mutation, after the green run)

| Mutant | Result |
|---|---|
| `exports?/3` without `Code.ensure_loaded/1` | 1 failure — T1.5 only |
| `__generate_structured__/6` never picks `/5` | 7 failures (T1.3 /5 case + every `ContextStubLLM` test — its `/4` raises) |
| `__resolve_engine__/3` never picks `/2` | 9 failures (T1.2, T1.4, T1.5 + every `ContextStubLLM` test) |

### Measured facts (re-run, not trusted from the design)

- `Context.get_opt(Context.detached(carry: %{a: 1}), :carry) == %{a: 1}`;
  via `Context.new/3` → `nil`. Confirms moduledoc point (b).
- `Encodable.encode(%{options: [engines: %{writer: ALLM.Engine.new(adapter_opts: [api_key: "sk-SECRET"])}]})`
  still contains `"sk-SECRET"`. Confirms point (d).
- A3 (run opts reach every DSL step's context) verified by T1.10/T1.11 green.

### Gates run by the implementer

- `mix precommit` → exit 0: `3 doctests, 632 tests, 0 failures, 22 excluded`
  (616 before: +16); dialyzer `Total errors: 0`. The `:dynamo` / `:s3` sets were
  **excluded** (MinIO and DynamoDB Local unreachable from this devcontainer) —
  a weaker gate, per `CLAUDE.md` §8; the changed code touches neither adapter.
- Dialyzer first halted on the host-path-poisoned PLT (`CLAUDE.md` §2); rebuilt
  with `rm -f _build/test/dialyxir_*.plt*`.
- Verification block: `grep -rn 'call_llm/1\|call_llm(input)' lib guides test`
  → 1 hit, T1.7's own test name (positive control: 9 at `18f1161`);
  `def call_llm(context, input)` count 1; `def call_llm(<one arg>)` count 0.
- Not run here: the umbrella-side fail-closed compile check (`CLAUDE.md` §2) —
  the Amesbury umbrella is not mounted in this container. It is also expected
  to FAIL until the consumer migrates its overriding steps (design "Host
  lockstep").

### Deviations

- **D-impl-1 (tactical).** `__context__/1` gets its own direct tests in
  `llm_test.exs` beyond T1.9's behavioural coverage — it is a C2 contract
  function.
- **D-impl-2 (tactical).** T1.9 is split into two tests (bare map, `nil`) per
  `agent-spec/IMPLEMENTATION.md`'s conjunctive-test rule.
- **D-impl-3 (tactical).** T1.8–T1.12's `ContextStubLLM` defines the mandatory
  `/1` + `/4` as raising (the documented recommendation), which makes every
  context test also a proof that the context arities are preferred.
- No structural deviation from C1–C3.

### Host lockstep (outstanding, consumer-owned)

Removing `call_llm/1` breaks any consumer step that calls it. Amesbury (path
dep on this checkout) must migrate before its next compile; count UNVERIFIED
here (repo not mounted). Run the design's fail-closed census from its root.

### Fix pass (2026-10-03)

Sources: functional review `.work/reviews/2026-10-03-llm-seam-1.1/overview.md`
(F1), code review `.work/code-reviews/2026-10-03-llm-seam-1.1.md` (F1–F5),
security review (clean), design review (N/A). All findings Low; no cross-station
duplicates (functional F1 and code-review F3 are different sentences).

- **Functional F1 (doc half, carve-out: false sentence in hexdocs).** The
  `ALLM.Pipeline.LLM` "The step's context" bullet claimed the package
  interprets none of the run's opts; a `fan_out` item's opts carry the
  package's `:queue_since` (`dsl/runtime.ex:385`, read at `executor.ex:463`;
  re-measured by grep, pre-existing). Bullet now names it as reserved.
- **Code-review F3 (carve-out).** `llm_step.ex` "no context-free form" →
  "no arity that omits it … takes an explicit `nil`"; "grade or bill" →
  "call the wrong engine or attribute the call to no one"; also states the
  foreign-struct rejection (F1 below).
- **Code-review F1 applied.** `LLM.__context__/1` now accepts only
  `%Context{}`, a non-struct map, or `nil`; a foreign struct raises
  `FunctionClauseError`. Verified safe: the only `execute/2` caller in `lib/`
  is `Executor` (`executor.ex:417`), always with `Context.new/3`'s struct
  (`executor.ex:386`). New test "a foreign struct is rejected, not normalized".
- **Code-review F2 applied.** `exports?/3` uses `Code.ensure_loaded?/1`; T1.5
  (the lazy-load test) still green.
- **Code-review F4 applied.** `__context__/1`'s conjunctive test split into
  bare-map / `nil`.
- **Code-review F5 applied.** Reflowed `llm_step.ex` "So an overriding
  `execute/2`…" paragraph and `guides/building_a_pipeline.md` §2; dispatch
  comment no longer anticipates an unbuilt step kind.

#### Deferred (out of fence)

- **Functional F1 structural half** — move `:queue_since` off run opts onto a
  `Context`/`Executor`-owned channel so adapters never see it and a host opt of
  that name is not clobbered inside fan-outs. Outside this design's fence
  (Context/Executor deliberately untouched). Carried as an Open row in
  `.work/HANDOFF.md`; this entry is its tracked receiver.

Gate: `DATABASE_HOST=host.docker.internal mix precommit` → exit 0;
`3 doctests, 634 tests, 0 failures, 22 excluded` (+2 over 632: the split and the
foreign-struct test); dialyzer `Total errors: 0`. `:dynamo`/`:s3` excluded
(services unreachable from this container), as before.

---

## 2.1 — implementation record (2026-10-03)

Built on `ae4d620` (1.1 committed). Status: **Built, gates pending.**

Precondition A5: the user's uncommitted `mix.exs`/`mix.lock` bump was still in
the tree; 2.1 rewrote its `{:allm, …}` line in place (not committed or
discarded first — the line is superseded either way). `mix.lock` kept at allm
0.6.0; `mix deps.get` → "All dependencies are up to date", lock diff unchanged.

### Checklist

- [x] C1 `classify/4` + `@doc` (the one-line `ALLM.classify/3` delegation as
      the example; the LLMCallLog note), in `@optional_callbacks`.
- [x] C2 `__classify__/5`: `Code.ensure_loaded/1` (not the boolean
      `exports?/3` — the load-failure branch must name the reason);
      `RuntimeError` naming adapter, `classify/4`, `ALLM.classify/3`; a load
      failure is named as one.
- [x] `mix.exs`: `{:allm, ">= 0.6.0 and < 1.0.0"}`; comment rewritten (lib/
      builds/matches `ALLM.Classification*` structs and calls
      `ALLM.Usage.total_tokens/1`, so 0.6.0 is the floor).
- [x] `guides/host_wiring.md` §2: `classify/4` optional, ClassifyStep-only, a
      delegation; engine name → engine with `:classification_adapter`; bare
      delegation records nothing into `LLMCallLog`.
- [ ] Changelog input — carried to the milestone (see 2.2).

### Test map (`test/allm/pipeline/llm_test.exs`, `describe "__classify__/5"`)

| Plan id | Test |
|---|---|
| T2.1 | "an adapter exporting classify/4 gets every argument and the exact context"; "the adapter's result is returned unchanged" (split — conjunctive rule). *2.2 fix pass:* the latter split into "an adapter's error is returned unchanged" / "an adapter's response is returned unchanged" — `Classifier`'s non-contract return is now refused (D-impl-6) |
| (D-impl-6, fix pass) | "a success that is not a ClassificationResponse raises, naming the adapter"; "a non-tuple return raises, naming the adapter — never a CaseClauseError" |
| T2.2 | "an adapter without classify/4 raises, naming the adapter and the callback" |
| T2.2b | "an adapter without classify/4 is not called at all before the raise" (`NoClassify` exports every other seam function, each reporting) |
| (C2 load branch) | "an adapter that fails to load is named as a load failure" — contract invariant not in the plan |
| T2.3 | "a delegating adapter returns ALLM 0.6.0's own response" (real FakeClassification) |
| T1.6 ext. | "the context-taking callbacks and classify/4 are exactly the optional ones" |

Red first: all six failed for the right reason (`__classify__/5` undefined;
optional set missing `classify: 4`). Mutant: load-failure branch reporting
"does not export" → 1 failure (the load test).

### Deviations

- **D-impl-4 (tactical).** `__classify__/5` calls `Code.ensure_loaded/1`
  directly rather than the private `exports?/3` (which returns a boolean and so
  cannot name the load error C2 requires).

---

## 2.2 — implementation record (2026-10-03)

Status: **Built, gates pending.**

### Checklist

- [x] `lib/allm/pipeline/classify_step.ex` per C4 — moduledoc (generated
      functions, question-id table, coerce table, thresholds-are-yours),
      `__using__/1`, `__before_compile__/1`, `__validate__!/2` (`(module, opts)`).
- [x] `llm_step.ex`: `__assert_input_struct__!/2` (the private body
      renamed-and-exposed; LLMStep calls it), `__coerce_atom__/2` (wrapper over
      `coerce_scalar(:atom, …)`), `__llm_error__/1` (the former `llm_error/1`).
      Comment references to the old name updated in
      `json_schema_cross_file_test.exs` and `test/fixtures/cross_file_step/*`.
      The shared input-struct message now says "The step's callbacks receive
      the Input STRUCT" (was "`prompt/1` receives…" — wrong for a classify
      step); no test asserted the old wording.
- [x] `guides/building_a_pipeline.md`: `### A classification step` at the end
      of §2 (unnumbered — §4 reference intact); "Where to go next" names
      ClassifyStep.
- [x] Tests T2.4–T2.14.
- [x] README feature list, `host_wiring.md` §2 opening ("no LLMStep or
      ClassifyStep steps"), `building_a_pipeline.md` "Where to go next".
- [ ] Changelog input — for the milestone's `/changelog` (not written here):
      "Add `use ALLM.Pipeline.ClassifyStep` over ALLM 0.6.0 typed
      classification; the LLM seam gains optional `classify/4`. The `allm`
      requirement's floor rises to 0.6.0."

### Test map (`test/allm/pipeline/classify_step_test.exs`, 39 tests; 40 after the fix pass)

| Plan id | Test(s) |
|---|---|
| T2.4 | "turns the answers into a typed Output struct"; "keeps every answer struct in an `answers` field" |
| T2.5 | "…becomes :other where :other is declared"; "…without :other is a coercion failure" (`StrictTriageStep`, inline blocks) |
| T2.6 | "a choice into a String.t() field…"; coerce/2 "yes_no … boolean()", "choice … float()" (+ "score … integer()", "score … atom()") |
| T2.7 | `describe "call_classifier/2 question validation"` — unknown, reserved `answers`, empty, duplicate; + "unknown is reported before duplicate, de-duplicated and sorted" (the ordering rule) |
| T2.8 | "the adapter sees the step's context" (both `resolve_engine/2` and `classify/4`) |
| T2.9 | "an adapter error is tagged :llm_error and returned" (also asserts the log line) |
| T2.10 | `describe "compile-time checks"` — state/1, questions/1, unknown option, missing type:/engine:, non-atom engine:, output: not schema, input: not struct, wire:, atom() without values:; + positive control "the fixture shape compiles" |
| T2.11 | "an override over call_classifier/2 + coerce/2 yields the generated path's struct" |
| T2.12 | "carries the @behaviour attribute and exports the callbacks" |
| T2.13 | three tests: choice/score/yes_no headline `nil` → default (department stays `:unassigned` though `:other` is declared) |
| T2.14 | "the Output casts and the answer structs persist in the step log" (DB-backed, sandbox owner) |
| (contract) | "tokens_used is the response's total tokens" (30+12 → 42); "an adapter returning a non-response success is named, not a KeyError"; "the adapter receives the state and string-keyed questions" |

### Red-first evidence

The suite was written before `classify_step.ex` but first ran after it, so its
first run was green (38/38). Red evidence is therefore by mutation (each
restored byte-identical, no formatter mid-pass):

| Mutant | Result |
|---|---|
| M1 `choice: nil` read clause dropped | 1 failure (T2.13 choice) |
| M2 duplicate check disabled | 1 failure |
| M3 reserved fields not subtracted | 1 failure (`"answers"` id) |
| M4 no `\| nil` unwrap | 8 failures |
| M5 tokens forced to 0 | 1 failure |
| M6 context replaced by `Context.detached()` | 1 failure (T2.8) |
| M7 `wire:` compile check off | 1 failure |
| M8 empty-questions check off | 1 failure (ALLM's own ValidationError surfaced instead) |

### Measured facts

- Dialyzer flags an explicit `{:ok, other}` clause after
  `{:ok, %ClassificationResponse{}}` (`pattern_match`) — and also when moved
  into a private helper (`pattern_match_cov`): it trusts `__classify__/5`'s
  spec. See D-impl-6. *Superseded by the fix pass:* with the check moved into
  `LLM.__classify__/5` around the variable-module `impl.classify(...)` call,
  dialyzer needs no suppression (`Total errors: 0`, no `@dialyzer` in `lib/`).
- FakeClassification reports zero usage (`total_tokens: 0`); the token test
  therefore uses a hand-built response through the stub's override.
- `StepLog` serializes the `answers` map's structs: `output_data["answers"]
  ["department"]["choice"] == "billing"` (T2.14).

### Deviations

- **D-impl-5 (tactical).** `call_classifier/2` passes `state/1` as a thunk,
  evaluated only after the questions validate — a refused question map
  evaluates nothing but `questions/1`.
- **D-impl-6 (tactical).** The `{:ok, other}` → `ArgumentError` check lives in
  a private `unwrap_response!/2` with `@dialyzer {:no_match, unwrap_response!: 2}`
  — the first `@dialyzer` attribute in `lib/`. Rejected: widening
  `__classify__/5`'s C2 spec (forbidden by IMPLEMENTATION.md), dropping the
  check (C4's error table requires it), a hidden public helper only to dodge
  call-site narrowing. Review lane: confirm the scoped suppression is acceptable.
  **Resolved in the fix pass (code review F1):** the check moved into
  `LLM.__classify__/5` (`checked_classification!/2`, `llm.ex:319`), where the
  value enters the package from a module the compiler cannot see; C2's spec is
  unchanged and now enforced. `unwrap_response!/2` and the `@dialyzer`
  attribute are deleted; `__call_classifier__/5` matches
  `{:ok, %ClassificationResponse{}}` directly. Non-tuple returns (formerly a
  `CaseClauseError` in `__call_classifier__/5`) now raise the same
  `ArgumentError`. Dialyzer: `Total errors: 0` with no suppression.
- **D-impl-7 (tactical).** `invalid_questions` is typed narrowly
  (`[empty: []] | [unknown: [String.t()]] | [duplicate: [String.t()]]`) rather
  than C4's `keyword([String.t()])` — same values, sharper spec.

### Gates run by the implementer

- `mix precommit` → exit 0: `3 doctests, 678 tests, 0 failures, 22 excluded`
  (634 before: +44 = 6 in `llm_test.exs`, 38 in `classify_step_test.exs`;
  plus one ClassifyStep test added after); final re-run `3 doctests, 679
  tests, 0 failures, 22 excluded`, exit 0; dialyzer
  `Total errors: 0`. `:dynamo`/`:s3` excluded (services unreachable here).
- `mix docs` → no warning/error lines; DOCS.md HARD grep → no hits (exit 1),
  positive control returns a file; soft advisory hits are the two pre-existing
  "your host application" lines.
- `mix hex.build` → succeeds, tarball lists `lib/allm/pipeline/classify_step.ex`.
- Verification: `grep -n '{:allm,' mix.exs` → `">= 0.6.0 and < 1.0.0"`;
  `defp coerce_scalar(:atom` in classify_step.ex → 0 (control: 3 in
  llm_step.ex); `__coerce_atom__` in classify_step.ex → 2.

### Fix pass (2026-10-03)

Sources: functional review `.work/reviews/2026-10-03-llm-seam-2/overview.md`
(F1, F2 — Low), code review `.work/code-reviews/2026-10-03-llm-seam-2.md` (F1
Medium; F2–F5 Low), security review (clean), design review (N/A). Run's last
batch, so every Low was applied here rather than deferred to polish. No
cross-station duplicates: functional F1 (non-map `questions/1`) and code-review
F1's non-tuple gap are different inputs to different functions; each
single-reporter finding was re-measured (below).

- **Code-review F1 (Medium) — D-impl-6 resolved.** See D-impl-6 above. New
  tests in `llm_test.exs` (2.1 test map). Mutant "the seam passes the adapter's
  return through unchecked" (`checked_classification!/2`'s refusing clause →
  `other`), run on a copy of the tree → 3 failures: the two new `llm_test.exs`
  tests and `classify_step_test.exs`'s "an adapter returning a non-response
  success is named, not a KeyError" (C4's error-table row still holds; its
  mechanism moved).
- **Functional F2 (carve-out: false sentence in hexdocs + guide).** Re-measured:
  `Executor.drain_and_store_llm/2` (`executor.ex:541`) returns `%{}` on an empty
  `LLMCallLog`, and neither `step_log.ex:150-151` nor the test DDL gives
  `llm_call_count` / `llm_total_tokens` a default — so they are `NULL`, not `0`.
  `LLM.classify/4`'s `@doc` and `guides/host_wiring.md` §2 now say so and point
  at the Output's `tokens_used`. Sibling grep `zero total|total tokens` over
  `lib guides README.md` → only `classify_step.ex`'s coerce-table row (correct:
  it is the Output field).
- **Functional F1.** `questions/1` returning a non-map now raises
  `ArgumentError` naming the step module and `questions/1`, before `state/1` or
  any dispatch (a fallback `__call_classifier__/5` clause, `classify_step.ex:318`).
  Chosen over `{:error, {:invalid_questions, …}}` because a non-map is a type
  violation of the callback's contract, not an id problem — the tuple is typed
  as id lists inside a well-formed map — and it sits with the table's other
  raised step-author shape errors (`state/1`'s non-`state()` value, the
  compile-time rows). Moduledoc "Question ids" updated; design error table
  gained a dated `> CORRECTED:` blockquote naming the row. Test "a non-map
  questions/1 raises, naming the step and questions/1"; mutant "fallback clause
  deleted" (copy) → 1 failure, `FunctionClauseError` instead of `ArgumentError`.
- **Code-review F2.** `LLM` moduledoc: "The step's context" notes `classify/4`
  always takes the context; the engine-name sentence and the `engine` typedoc
  name `classify/4`; the dispatch-helper comment scopes its legacy-branch claim
  to `__resolve_engine__/3` / `__generate_structured__/6`.
- **Code-review F3.** The score/yes_no `read/3` clauses merged into one guarded
  clause over `@float_types` plus `float_value/1`; nil-headline clauses stay
  first.
- **Code-review F4.** The atom-option shape rule is one `@doc false`
  `defguard LLMStep.__atom_option__/1` (`llm_step.ex:788`), used by both
  `fetch_atom!/4`s; messages stay local.
- **Code-review F5.** `mix.exs` comment: "cap the ceiling below that release
  (or adapt the code and raise the floor)"; requirement unchanged
  (`">= 0.6.0 and < 1.0.0"`). `mix.lock` untouched.

The design's C4 adapter row ("`classify/4` returned `{:ok, other}`") now also
covers a non-tuple return and is raised by the seam; the orchestrator added a
second `> CORRECTED:` blockquote under the error-contract table saying so.
Post-fix scoped re-review (`.work/code-reviews/2026-10-03-llm-seam-2-fixdelta.md`):
ship as-is; its F-L2 (unguarded fallback clause) applied — the clause is now
`when not is_map(questions)`.

Gate: `DATABASE_HOST=host.docker.internal mix precommit` → exit 0;
`3 doctests, 683 tests, 0 failures, 22 excluded` (+4 over 679: three net in
`llm_test.exs`, one in `classify_step_test.exs`); dialyzer `Total errors: 0`.
`mix docs` → no warning/error lines; DOCS.md HARD grep → no hits (exit 1),
positive control `doc/ALLM.Pipeline.Artifacts.Dynamo.md`.

### Consumer census (Definition of Done, measured)

`grep -rn 'use ALLM.Pipeline.ClassifyStep' lib --include '*.ex'` → 0 in this
repo's `lib/` (as expected — the declarations are test fixtures). Production
declarations: **0 known** in any consumer (not measurable here; no consumer
repo mounted). A finding, accepted by D4.

### Host lockstep (outstanding, consumer-owned)

The 0.6.0 floor forces every path-dep consumer onto allm ≥ 0.6.0; each checks
its exhaustive matches on allm's error enums (allm `CHANGELOG.md`, v0.6.0
"Breaking changes") before taking 2.1.
