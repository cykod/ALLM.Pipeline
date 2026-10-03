# Records — The step's context at the LLM seam, and a ClassifyStep

Companion to `steering/2026-10-03_LLM_SEAM_CONTEXT_AND_CLASSIFY.md`. Bookkeeping
(status, checklist, deviations, measured facts) lives here; the design doc is
not edited during implementation. Its embedded Status table still reads
`Not Started` — this file is the current status.

## Status

| Subphase | Concern | Status |
|---|---|---|
| 1.1 | Context reaches the LLM seam; `call_llm/1` → `call_llm/2` | Completed (reviews + fix pass; fix-pass delta re-reviewed in batch 2's round) |
| 2.1 | Optional `classify/4` seam callback; allm floor 0.6.0 | Not Started |
| 2.2 | `use ALLM.Pipeline.ClassifyStep` | Not Started |

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
