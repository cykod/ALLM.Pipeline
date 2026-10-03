# The step's context at the LLM seam, and a ClassifyStep

*Generated 2026-10-03. Measured against: `18f1161` (working tree carries an
uncommitted `mix.exs`/`mix.lock` allm bump — see Assumptions A5). Every
`file:line` is relative to the repo root at that sha.*

**Goal.** (1) Answer the third consumer's (Legendis) upstream request
`steering/2026-10-02_ALLM_PIPELINE_ENGINE_OVERRIDE.md`: the LLM seam receives
the step's `%ALLM.Pipeline.Context{}` so a host adapter can do per-run engine
overrides, account attribution and usage metering itself. (2) Expose ALLM
0.6.0's typed classification (`ALLM.classify/3`) as a step kind,
`use ALLM.Pipeline.ClassifyStep`, routed through the same seam.

**Measurable outcome.** A host adapter exporting `resolve_engine/2` /
`generate_structured/5` observes a run option via `Context.get_opt/3` from a
DSL run, a direct `Executor.run_step/5`, a `Context.detached/1` call and a
`Task.async_stream` fan-out inside an overriding `execute/2`; an adapter
exporting only `/1` + `/4` passes the existing `llm_step_test.exs` unchanged in
behaviour; a `ClassifyStep` turns a FakeClassification response into a typed
Output struct. `mix precommit` green at each subphase.

**Layers touched.** `ALLM.Pipeline.LLM` (seam), `ALLM.Pipeline.LLMStep`
(macro), new `ALLM.Pipeline.ClassifyStep` (macro), `mix.exs` (allm floor),
two guides. No schema/DDL, no Registry, no Executor, no DSL runtime change.

**Spec sections covered.** The request's "The change we ask for", "Contract we
will consume" and "Tests we expect upstream" (all four test bullets → T1.8,
T1.10, T1.11, T1.12 + the migrated `StubLLM` suite); `CLAUDE.md` §1 (seam
wiring, mandatory-callback rule), §5 (env-touching tests), §7 (census
corollary, `Code.eval_string` rejection tests); `agent-spec/DESIGN.md`.

## Status

| Subphase | Concern | Status |
|---|---|---|
| 1.1 | Context reaches the LLM seam; `call_llm/1` → `call_llm/2` | Completed |
| 2.1 | Optional `classify/4` seam callback; allm floor 0.6.0 | Not Started |
| 2.2 | `use ALLM.Pipeline.ClassifyStep` | Not Started |

Overall Progress: 1/3 (records: `2026-10-03_LLM_SEAM_CONTEXT_AND_CLASSIFY_RECORDS.md`)

---

## Overview

### Deliverables

- **Phase 1 (breaking for step authors → the next release is v0.2.0).**
  Two optional context-taking callbacks on `ALLM.Pipeline.LLM`, preferred by
  the package when exported; the generated `call_llm/1` is **replaced** by
  `call_llm/2`. Host adapters do not change.
- **Phase 2 (additive).** An optional `classify/4` seam callback and the
  `ClassifyStep` macro. The allm requirement's floor rises to 0.6.0.

### Decisions taken (by the user, 2026-10-03)

| # | Decision | Rejected alternative |
|---|---|---|
| D1 | **Additive callbacks.** `resolve_engine/2` and `generate_structured/5` are `@optional_callbacks`; the package dispatches to them when exported and falls back to `/1` / `/4`. | A breaking rename to `/2` + `/5` — forces Amesbury's adapter (a path dep reading this checkout) to change in lockstep for no gain to it. |
| D2 | **The existing `/1` and `/4` stay MANDATORY.** | Making all four optional — breaks the guard `behaviours_test.exs:82` ("declares at least one mandatory callback"), which iterates `@host_seams [LLM]` (`behaviours_test.exs:71`), and moves "adapter missing a callback" from a compile warning to a runtime raise. Cost accepted instead: a context-taking adapter (Legendis) still defines `/1` + `/4`; the documented recommendation is that they **raise** (never delegate with `Context.detached()`), because the package never calls them while `/2` + `/5` are exported. |
| D3 | **`call_llm/1` is removed**, not shimmed. | A `call_llm/1` filling in `Context.detached()` — the silent-drop shape the request names: an eval grades the default engine under another model's label, a usage event carries no account. A compile error at the override is the loud version. |
| D4 | **A full `ClassifyStep` macro** in Phase 2, with the 0-consumer census stated (see "Consumer census"). | Seam callback only; deferring classification entirely. |
| D5 | **lib/ builds ALLM's own classification structs**; floor `>= 0.6.0 and < 1.0.0`. | A package-neutral question shape the host translates — keeps the floor at 0.4.2 but makes the host adapter a translation, contradicting `llm.ex:16-18` ("a delegation, not a translation"). |

### Non-obvious decisions (designer's)

- **Dispatch lives in `ALLM.Pipeline.LLM`, once.** Both macros resolve an
  engine; writing `function_exported?` twice is how they diverge. Contract C2.
- **`function_exported?/3` is preceded by `Code.ensure_loaded/1`.**
  `impl/0` returns a bare atom (`llm.ex:113-125`) and never loads the module;
  `function_exported?/3` answers `false` for an unloaded module, which would
  silently select the legacy arity on the first call of a lazily loaded
  (interactive-mode) host. (Erlang/Elixir documented behaviour of
  `function_exported?/3`; pinned by test T1.5 rather than recalled.)
- **Dispatch is per callback, not per adapter.** An adapter may export
  `resolve_engine/2` with `generate_structured/4` (it needs the override but
  not the account). Each call independently prefers the context arity.
- **ClassifyStep reuses the seam's error tag `{:llm_error, reason}`** rather
  than inventing `{:classify_error, _}`: a host's error arm matches one tag for
  everything that crossed the seam.
- **ClassifyStep's engine is resolved through the same `resolve_engine/{1,2}`.**
  `engine: :classifier` is host vocabulary (`llm.ex:20-27`); the host maps it
  to an `%ALLM.Engine{}` carrying a `:classification_adapter`. No new registry
  key, no second engine vocabulary.

### Out of scope (each deliberately)

- **A usage callback / wider `tokens` envelope.** The request explicitly does
  not ask (its "The change we ask for": "We deliberately don't ask for a usage
  callback"); its adapter meters from ALLM's `Response.usage` itself.
- **The `optional(:usage)` field promised as P6 in
  `steering/2026-08-31_SECOND_CONSUMER_GAP_RESPONSE.md`** ("new design
  subphase 2" there). Measured absent from `llm.ex:77-79`, and no design in
  `steering/` schedules it — it is an unscheduled gap, not bundled here
  (surgical) and not claimed by this design.
- **The eval harness.** The request keeps it in Legendis ("Decision: the eval
  harness stays in Legendis"); `Context.detached/1` (`context.ex:120-121`)
  already serves it.
- **Redacting `inspect(reason)` in the LLM error log** (`llm_step.ex:397-400`).
  The request records it as "Noted, not asked for"; its adapter returns a
  text-free reason. ClassifyStep copies the same log shape (2.2), so the future
  fix has two sites — named in its own plan if it ever comes.
- **Context to `prompt/1` / `state/1` / `questions/1`.** Not asked; prompts are
  built from the Input. An override of `execute/2` already has the context.
- **Moderation, transcription, images, prompt-caching knobs from ALLM 0.6.0.**
  The user named classification; nothing else in 0.6.0 maps to a step kind a
  consumer has asked for.
- **The package stripping `:engines` (or any key) from persisted run
  metadata.** The DSL's default `metadata:` hook is `%{options: opts}`
  (`pipeline.ex:116`, `dsl/runtime.ex:141-144`), so run options already reach
  `pipeline_runs.metadata` today. The keys are host vocabulary the package
  never interprets (`llm.ex:20-27`); naming `:engines` in lib/ would leak one
  host's vocabulary into the package. Instead 1.1 documents the hazard (see
  its checklist) and the arch/security lane checks it.

### Review lanes

Code review + arch/security review apply to all three subphases. Design
review (visual) is N/A — no UI.

### Consumer census (`CLAUDE.md` §7 corollary)

| Construct | Production declaration expected? |
|---|---|
| `resolve_engine/2`, `generate_structured/5` | **Yes** — Legendis Phase 6 (the requester). |
| `call_llm/2` in an overriding `execute/2` | **Yes** — every existing override must migrate (Amesbury, UNVERIFIED count: its repo is not mounted here; `llm_step_test.exs:142`'s `OverridingStep` is modelled on its `ordinance_transformer.ex`). |
| `classify/4`, `use ALLM.Pipeline.ClassifyStep` | **0 known.** No consumer has named a classify step. This is a finding, accepted by the user (D4), not a pass. Each consumer adopting it runs `grep -rn 'use ALLM.Pipeline.ClassifyStep' <app dirs> --include '*.ex' \| grep -v /test/` from its own root and records the result in its port design. |

---

## Behaviour & type contracts

### C1 — `ALLM.Pipeline.LLM` callbacks (normative home)

```elixir
# existing, unchanged, MANDATORY (D2)
@callback resolve_engine(name :: atom()) :: engine()
@callback generate_structured(prompt(), schema :: map(), schema_name :: String.t(), engine()) :: result()

# new, OPTIONAL — 1.1
@callback resolve_engine(name :: atom(), context :: ALLM.Pipeline.Context.t()) :: engine()
@callback generate_structured(
            prompt(), schema :: map(), schema_name :: String.t(), engine(),
            context :: ALLM.Pipeline.Context.t()
          ) :: result()

# new, OPTIONAL — 2.1
@callback classify(
            state :: ALLM.ClassificationRequest.state(),
            questions :: %{String.t() => ALLM.ClassificationQuestion.t()},
            engine(),
            context :: ALLM.Pipeline.Context.t()
          ) :: {:ok, ALLM.ClassificationResponse.t()} | {:error, term()}
# {:error, term()} deliberately: the seam's error is opaque to the package
# (llm.ex:14-16), exactly as result()'s is; the package only tags it.

@optional_callbacks resolve_engine: 2, generate_structured: 5, classify: 4
```

`result()` is unchanged (`llm.ex:77-79`). `ALLM.ClassificationRequest.state()`
is `String.t() | map() | list()` (`deps/allm/lib/allm/classification_request.ex:50`).
The intended host `classify/4` is the one-line delegation
`ALLM.classify(engine, state, questions: questions)`
(`deps/allm/lib/allm.ex:2202-2219`), returning ALLM's response unchanged —
the moduledoc's "a delegation, not a translation" (`llm.ex:12-18`) holds.

`context` is always a `%ALLM.Pipeline.Context{}` — never `nil`, never a bare
map — whatever the caller passed to `execute/2` (C3 normalizes).

### C2 — dispatch helpers (normative home), in `ALLM.Pipeline.LLM`

```elixir
@doc false
@spec __resolve_engine__(module(), atom(), Context.t()) :: engine()
@spec __generate_structured__(module(), prompt(), map(), String.t(), engine(), Context.t()) :: result()
@spec __classify__(module(), ALLM.ClassificationRequest.state(),
                   %{String.t() => ALLM.ClassificationQuestion.t()}, engine(), Context.t()) ::
        {:ok, ALLM.ClassificationResponse.t()} | {:error, term()}
@spec __context__(Context.t() | map() | nil) :: Context.t()   # C3's normalization, one copy
```

| Helper | Adapter exports (after `Code.ensure_loaded/1`) | Calls |
|---|---|---|
| `__resolve_engine__/3` | `resolve_engine/2` | `impl.resolve_engine(name, ctx)` |
| | otherwise | `impl.resolve_engine(name)` |
| `__generate_structured__/6` | `generate_structured/5` | the `/5` form with `ctx` |
| | otherwise | the `/4` form |
| `__classify__/5` | `classify/4` | `impl.classify(state, questions, engine, ctx)` |
| | otherwise | **raises** `RuntimeError` naming `impl`, `ALLM.Pipeline.LLM`, `classify/4` and `ALLM.classify/3` (a classify step on an adapter without classification is a wiring bug, loud like `impl/0` at `llm.ex:127-145`) |

If `Code.ensure_loaded/1` returns `{:error, _}`, `__resolve_engine__/3` and
`__generate_structured__/6` take the legacy branch, whose call then raises
`UndefinedFunctionError` naming the adapter — no rescue, no extra message.
`__classify__/5` has no legacy branch, so its `RuntimeError` names the load
failure (`{:error, reason}`) instead of claiming a loaded adapter lacks
`classify/4`.

The helpers do not call `impl/0` themselves; the caller resolves `impl` once
per call path and passes it (one config read per LLM call, as today at
`llm_step.ex:376`).

### C3 — generated `LLMStep` functions (normative home for the macro surface)

| Function | Contract |
|---|---|
| `call_llm(context, input)` | `@spec call_llm(ALLM.Pipeline.Context.t() \| map() \| nil, struct()) :: {:ok, map(), non_neg_integer()} \| {:error, {:llm_error, term()}}`. A bare map (`Step.context/0` tolerance, `context.ex:115-118`) or `nil` (the `execute(nil, input)` idiom, `step_test.exs:56`) is normalized to `Context.detached()` — the only place the package substitutes an empty context, because such a caller has no options to lose. The normalization is one public `@doc false` function, `LLM.__context__/1`, shared with ClassifyStep's `call_classifier/2` (one copy). |
| `call_llm/1` | **Does not exist.** `function_exported?(step, :call_llm, 1) == false` (T1.7). |
| `execute(context, input)` | `call_llm(context, input)` → `coerce/2` → `post_process/2`; still `defoverridable`. |
| `__call_llm__/4` | `(module, declaration, prompt, context)` → C2 helpers → today's envelope unwrap + error log + `llm_error/1` tagging, unchanged (`llm_step.ex:380-403`). Replaces `__call_llm__/3`. |

### C4 — `use ALLM.Pipeline.ClassifyStep` (normative home)

Options (validated in `__validate__!(module, opts)` — `(module, opts)` order,
`CLAUDE.md` §7): `type:` (atom, required), `engine:` (atom, required),
`input:` / `output:` (schema modules, default nested `Input` / `Output`).
Unknown option → `ArgumentError` naming the module and the known set. No
`schema_name:` (classification has no response format).

Imports `ALLM.Pipeline.Schema.input_schema/1,2` and `output_schema/1,2` — the
plain Schema forms; the Output does **not** need `json_schema: true`.

**Required of the using module:** `state/1` (Input struct →
`ALLM.ClassificationRequest.state()`) and `questions/1` (Input struct →
`%{(atom() | String.t()) => ALLM.ClassificationQuestion.t()}`). Absence of
either is a compile-time `ArgumentError` naming the module.

**Compile-time checks** (all `ArgumentError` naming the module): `input:` is a
compiled struct module (same predicate as `LLMStep`'s `assert_input_struct!/2`,
`llm_step.ex:641-653`, exposed as `@doc false LLMStep.__assert_input_struct__!/2`
— one copy); `output:` is a schema module
(`ALLM.Pipeline.Schema.JsonSchema.schema_module?/1`, `json_schema.ex:429-432`);
`state/1` and `questions/1` are defined; **no Output field declares `wire:`**
(`output.__allm_schema__(:wire) == []`, built from declared options only,
`schema.ex:997`) — question ids map to field NAMES, and `wire:` is an LLMStep
wire-contract concept with no meaning here, so allowing it would leave "is the
id the name or the wire name?" ambiguous; **every field whose
`LLMStep.__coercion__/1` is `:atom` declares `values:`** — a ClassifyStep
Output does not derive a JSON schema, so `JsonSchema.no_open_atom!/5` never
runs for it, and without this check such a field compiles and returns
`{:no_vocabulary, raw}` on every call.

Generated (overridable marked ⓞ):

| Function | Contract |
|---|---|
| `step_type/0`, `input_schema/0`, `output_schema/0` | `Step` callbacks, `@impl`; injects `@behaviour ALLM.Pipeline.Step`. |
| `call_classifier(context, input)` | `@spec … :: {:ok, %{String.t() => ALLM.ClassificationAnswer.t()}, non_neg_integer()} \| {:error, {:llm_error, term()}} \| {:error, {:invalid_questions, keyword([String.t()])}}`. Context normalized via `LLM.__context__/1`. Question ids are normalized to strings; **before any dispatch** (no provider call, no log) they are validated — see the error-contract table below. Then `impl = LLM.impl()`, `LLM.__resolve_engine__/3`, `LLM.__classify__/5`. Tokens = `ALLM.Usage.total_tokens(response.usage) \|\| 0` (`deps/allm/lib/allm/usage.ex:113-114`). An adapter error is logged as `Logger.error("Classification error in #{inspect(module)}: " <> inspect(reason))` (the shape of `llm_step.ex:397-400`, minus the schema name a ClassifyStep does not have) and tagged `{:llm_error, reason}` through the same `llm_error/1` normalization (exposed `@doc false` from LLMStep — one copy). |
| `coerce(answers, tokens)` | Answers → Output struct per the table below; `{:ok, struct()} \| {:error, {:coerce, [{atom(), term()}]}}`. Public for overriding `execute/2`, like `LLMStep.coerce/2`. |
| `post_process(output, input)` ⓞ | Identity. |
| `execute(context, input)` ⓞ | `call_classifier/2` → `coerce/2` → `post_process/2`. |

**`coerce/2`, per Output field `f`** (the answer is `answers[to_string(f)]`):

Rows are evaluated top to bottom; the first match wins. A field's type is
first unwrapped of `| nil` — `:generated_types` adds it to every field with
neither `required: true` nor `default:` (measured: `team_name: String.t() | nil`)
— the same unwrap `coercion/1` performs (`llm_step.ex:604-606`).

| Case | Result |
|---|---|
| `f == :answers` | the whole `answers` map, unchanged (structs kept: `StepLog`'s `maybe_serialize/2` serializes any struct, `step_log.ex:701`) |
| `f == :tokens_used` | `tokens` |
| no answer for `f` | field left out → declared `default:` applies |
| the answer's headline FIELD is `nil` — matched structurally: `%ClassificationAnswer{type: :choice, choice: nil}`, `%{type: :score, score: nil}`, `%{type: :yes_no, yes_probability: nil}` (never via `ClassificationAnswer.value/1`: its spec is `String.t() \| float()` (`classification_answer.ex:106`), so dialyzer flags a `nil` clause on its result as unmatchable, and it raises `FunctionClauseError` on an unknown type) | field left out → default applies. Checked BEFORE the vocabulary rule: `is_atom(nil)` is true and `to_string(nil) == ""`, so a `nil` choice reaching `__coerce_atom__/2` would become `:other` — the trap `llm_step.ex:483-496` documents. ALLM types all three headline fields `… \| nil` (`classification_answer.ex:57-66`). |
| `:choice` answer, field's `LLMStep.__coercion__/1` is `:atom` | `LLMStep.__coerce_atom__(answer.choice, values)` — the existing vocabulary rule (`llm_step.ex:522-547`): member → atom; unknown → `:other` iff declared, else `{:unknown_value, raw}` (`values:` is guaranteed present by the compile check) |
| `:choice` answer, field type is `String.t()`, `term()` or `any()` (after the `\| nil` unwrap) | `answer.choice` (string) unchanged |
| `:score` / `:yes_no` answer, field type is `float()`, `number()`, `term()` or `any()` (after the `\| nil` unwrap) | `answer.score` / `answer.yes_probability` (float) |
| any other answer-type × field-type pair (a probability into `boolean()`, a score into `integer()`, a choice into `float()`, a score into an `atom()` field) | issue `{f, {:type_mismatch, answer.type}}` — `struct/2` and dialyzer cannot catch it, so `coerce/2` is the boundary |

Field types are read from `__allm_schema__(:generated_types)` as LLMStep does
(`llm_step.ex:419`); the float-accepting set above is matched by AST name, the
same way `coercion/1` matches `Date` (`llm_step.ex:626`).

**Error contract — ClassifyStep (exhaustive).**

| Function | Reason | Recovery |
|---|---|---|
| `__validate__!/2` (compile) | `ArgumentError`: non-keyword opts; unknown option; missing/non-atom `type:` / `engine:`; non-atom `input:` / `output:` | fix the `use` line |
| `__before_compile__/1` (compile) | `ArgumentError`: `input:` not a compiled struct; `output:` not a schema module; `state/1` or `questions/1` undefined; a `wire:` option on an Output field; an `:atom` field without `values:` | fix the declaration |
| `call_classifier/2` | `{:error, {:invalid_questions, empty: []}}` — `questions/1` returned `%{}` | step author's bug; no provider call |
| | `{:error, {:invalid_questions, unknown: ids}}` — ids that are not the `to_string/1` of an Output field, or are `"answers"` / `"tokens_used"` (reserved) | declare the field, or rename the question |
| | `{:error, {:invalid_questions, duplicate: ids}}` — two keys collapsing to one string (`:team` and `"team"`) | use one spelling |
| | `{:error, {:llm_error, reason}}` — anything from the adapter / `ALLM.classify/3` (validation, provider, key) | host-side; retried by ALLM's engine policy where retryable |
| | `RuntimeError` from `LLM.__classify__/5` — adapter has no `classify/4` (or failed to load — the message says which); from `LLM.impl/0` — no `llm:` | host wiring |
| | `ArgumentError` naming the adapter — `classify/4` returned `{:ok, other}` where `other` is not a `%ALLM.ClassificationResponse{}` (matched explicitly, never a `KeyError` on `.usage`) | host adapter bug |
| | `FunctionClauseError` from `ALLM.classify/3`'s guard (`allm.ex:2216-2217`) — `state/1` returned a non-`state()` value, when the host delegates to ALLM | step author's bug; not rescued |
| `coerce/2` | `{:error, {:coerce, [{field, {:unknown_value, raw} \| {:type_mismatch, answer_type}}]}}` | step author's declaration vs the question |

Several `call_classifier/2` checks failing at once report the first in the
order above (empty, unknown, duplicate) — each is a static author error,
fixed one at a time. The `unknown:` and `duplicate:` id lists are
de-duplicated and sorted.

Struct built with `struct/2` (not `struct!/2`), as `LLMStep` does
(`llm_step.ex:447-449`). `LLMStep.__coerce_atom__/2` is a new `@doc false`
public wrapper over the private `coerce_scalar(:atom, _, _)` — the shared
owner of the vocabulary rule; ClassifyStep does not copy it.

**Thresholds are not the package's.** No confidence floor, no routing; a step
that routes declares `field :answers, map()` and reads confidence in
`post_process/2` (ALLM's own stance: `deps/allm/guides/classification.md`
"Routing on confidence").

---

## Module tree

```
lib/allm/pipeline/llm.ex                     (MODIFY — 1.1, C1 /2 + /5 callbacks, C2 two helpers, moduledoc; 2.1, classify/4 + __classify__/5)
lib/allm/pipeline/llm_step.ex                (MODIFY — 1.1, C3; 2.2, expose __assert_input_struct__!/2 + __coerce_atom__/2)
lib/allm/pipeline/classify_step.ex           (NEW — 2.2)
lib/allm/pipeline.ex                         (MODIFY — 1.1, one sentence in the "## Lineage" section, :178)
README.md                                    (MODIFY — 2.2, ClassifyStep in the feature list, :26)
lib/allm/pipeline/llm_call_log.ex            (MODIFY — 1.1, prose "generate_structured/4" at :6, :39 → "generate_structured/4 or /5")
lib/allm/pipeline/schema/json_schema.ex      (MODIFY — 1.1, prose at :109, same rename)
mix.exs                                      (MODIFY — 2.1, allm floor 0.6.0 + rewrite the "lib/ calls no ALLM.* function" comment)
guides/building_a_pipeline.md                (MODIFY — 1.1 `call_llm/1` at :80 → `call_llm/2`; 2.2 an unnumbered `### A classification step` inside §2 (a new `## 3` would renumber and break the "(section 4)" reference at :72), and a "Where to go next" line at :238)
guides/host_wiring.md                        (MODIFY — 1.1 §2 names the context callbacks and the raise recommendation; 2.1 names classify/4; 2.2 :59-60 "need not name an engine" covers ClassifyStep too)
test/allm/pipeline/llm_test.exs              (NEW — 1.1, C2 dispatch; 2.1, __classify__/5)
test/allm/pipeline/llm_step_test.exs         (MODIFY — 1.1, migrate to call_llm/2 + context tests)
test/allm/pipeline/registry_test.exs         (MODIFY — 1.1, comment at :129 names `call_llm/1`)
test/support/lazy_llm_adapter.ex             (NEW — 1.1, T1.5's on-disk adapter; deliberately NO @behaviour)
test/allm/pipeline/classify_step_test.exs    (NEW — 2.2)
```

`ls lib/allm/pipeline/ test/allm/pipeline/` at `18f1161`: no `classify_step.ex`,
no `llm_test.exs`, no `classify_step_test.exs`; `ls test/support/` has no
`lazy_llm_adapter.ex` — all four NEW paths are free.
Deliberately untouched: `executor.ex`, `context.ex`, `dsl/runtime.ex`,
`registry.ex`, `behaviours_test.exs` (D2 keeps its guard green as-is).

---

## Phase 1 — the step's context at the LLM seam

### 1.1 Context reaches the seam; `call_llm/1` → `call_llm/2`

**Test plan (first).**

`test/allm/pipeline/llm_test.exs` (NEW, `async: false` — not for application
env, which it never touches (it calls the C2 helpers with an explicit `impl`),
but because T1.5 purges loaded code, which is global to the VM):
- T1.1 `__resolve_engine__/3` on an adapter exporting `/1` only calls `/1`.
- T1.2 … exporting `/1` + `/2` calls `/2` with the exact context struct.
- T1.3 `__generate_structured__/6` mirrors T1.1/T1.2 for `/4` vs `/5`.
- T1.4 mixed adapter (`resolve_engine/2` + `generate_structured/4`) — each
  helper picks independently.
- T1.5 lazy load: `ALLM.Pipeline.TestSupport.LazyLLMAdapter`
  (`test/support/lazy_llm_adapter.ex`, so it has a `.beam` on disk and can be
  reloaded — a module defined in an `.exs` cannot: `Code.ensure_loaded/1`
  returns `{:error, :nofile}` after `:code.delete/1`, measured) exports
  `resolve_engine/1,2`. The test runs `:code.purge/1`, `:code.delete/1`,
  `:code.purge/1`, asserts `function_exported?(mod, :resolve_engine, 2) == false`
  (the precondition), then `__resolve_engine__/3` must still call `/2`. A
  `function_exported?`-only implementation fails it. The module declares **no**
  `@behaviour ALLM.Pipeline.LLM`: dispatch needs only the exports, and a
  `test/support` module declaring it would fail `behaviours_test.exs`'s
  "every module in the package declaring a seam @behaviour is listed in @seams"
  (that scan includes `elixirc_paths(:test)` modules — `CLAUDE.md` §1).
- T1.6 `Enum.sort(LLM.behaviour_info(:optional_callbacks))` equals
  `Enum.sort([resolve_engine: 2, generate_structured: 5])` (1.1) — 2.1 extends
  it. Sorted on both sides: `behaviour_info/1` does not preserve declaration
  order (measured `[g: 5, c: 4, a: 2]` for `@optional_callbacks a: 2, g: 5, c: 4`).

Every `.exs` test double that declares `@behaviour ALLM.Pipeline.LLM` defines
both mandatory callbacks, `resolve_engine/1` + `generate_structured/4` (raising
where unused) — a missing one is a compile warning that
`test --warnings-as-errors` turns red (`CLAUDE.md` §1). A double that needs
neither declares no `@behaviour`, as `LazyLLMAdapter` does.

`test/allm/pipeline/llm_step_test.exs` (MODIFY; stays `async: false`):
- Migrate every `call_llm(input)` (`:163`, `:165`, `:281`, `:294`, `:303`,
  `:311`) to `call_llm(Context.detached(), input)`; existing assertions
  unchanged — proves a `/1`+`/4`-only adapter (`StubLLM`, `:25-47`) still works.
- T1.7 `function_exported?(WidgetStep, :call_llm, 1) == false` and `…, 2) == true`.
- T1.8 A second stub, `ContextStubLLM`, exporting all four. It records the
  context it received by sending `{:llm_ctx, fun, ctx}` to
  `List.last(Process.get(:"$callers", [])) || self()` (the walk
  `llm_call_log.ex:5-10` already uses) — not the process dictionary, which
  T1.12's `Task` children cannot see, and not a pid carried in the context,
  which T1.9's `nil` / `%{}` contexts cannot carry. It always returns
  `{:ok, %{parsed: %{"kind" => "alpha"}, tokens: 1}}`, so the Executor's
  `cast/1` (`Widget.Output`'s `kind` is `required: true`) accepts the output. `WidgetStep.execute(Context.detached(engines: %{nano: :x}), input)`
  → the stub saw `Context.get_opt(ctx, :engines)` in BOTH `resolve_engine/2`
  and `generate_structured/5`.
- T1.9 `WidgetStep.execute(%{}, input)` (bare map) and
  `WidgetStep.execute(nil, input)` → stub received a `%Context{opts: []}` both
  times.
- T1.10 **Executor path** (DB-backed: `Sandbox.start_owner!(Config.repo(), shared: true)`
  in a `describe` setup, per §3): `Executor.run_step(run, WidgetStep, input, nil, account_id: "a1")`
  → stub saw `get_opt(ctx, :account_id) == "a1"` and
  `Context.step_log_id(ctx)` equal to the returned step log's id and
  `Context.pipeline_run_id(ctx) == run.id`; the call returns `{:ok, step_log, _}`.
- T1.11 **DSL path**: a one-stage pipeline fixture (module at the top of the
  file, §7) over `WidgetStep`; `Fixture.run(account_id: "a2", …)` → the run succeeds and the
  stub saw `"a2"`. (Lives here, not in `dsl/runtime_test.exs`, because that file is
  `async: true` (`dsl/runtime_test.exs:16`) and this test writes
  `:allm_pipeline` env — §5.)
- T1.12 **Fan-out override**: a step overriding `execute/2` that runs
  `Task.async_stream([1, 2, 3], fn _ -> call_llm(context, input) end)` → three
  recorded contexts, each carrying the run option. (Stub records via a
  test-pid `send/2`, not `Process.put/2`, since calls run in child processes.)
- `OverridingStep` (`:142`) migrates to `call_llm(context, input)` — it is the
  executable form of the migration a consumer performs. The
  `describe "call_llm/1"` block (`:277`) is renamed `"call_llm/2"`.

**Checklist.**
- [ ] C1's `/2` + `/5` callbacks with `@doc` (stating: preferred when exported;
      the `/1` + `/4` pair stays mandatory; recommended to raise in a
      context-only adapter — D2), `@optional_callbacks`.
- [ ] C2 `__resolve_engine__/3` + `__generate_structured__/6` +
      `__context__/1`, `Code.ensure_loaded/1` first.
- [ ] `ALLM.Pipeline.LLM` moduledoc: "Engine names are the host's vocabulary"
      (`llm.ex:20-27`) gains a "The step's context" paragraph stating:
      (a) the run's `opts` (e.g. an engine-override map, an account id) are
      the host's to read with `Context.get_opt/3`; the package interprets
      none of them; (b) inside a run, four keys never reach `get_opt/3` —
      `:resources`, `:carry`, `:acc`, `:input_step_id` are popped onto struct
      fields by `Context.new/3` (`context.ex:94-97`); a `Context.detached/1`
      context pops nothing and keeps them in `opts` (measured:
      `get_opt(Context.detached(carry: %{a: 1}), :carry) == %{a: 1}`); (c) an escape-hatch body that
      calls `Executor.run_step/5` itself must pass `ctx.opts` through, or the
      inner step's seam call sees none of them (the body owns that call —
      `context.ex:144-151`); (d) under the DSL's default `metadata:` hook run
      options are persisted to `pipeline_runs.metadata` (`pipeline.ex:116`),
      so a host passing engine structs or credentials as options declares a
      `metadata:` hook that drops them — or passes names, not structs
      (measured: `Encodable.encode(%{options: [engines: %{writer:
      ALLM.Engine.new(adapter_opts: [api_key: "sk-SECRET"])}]})` keeps
      `"api_key" => "sk-SECRET"` in the encoded map).
      (c) is also added, one sentence, to `ALLM.Pipeline`'s moduledoc where
      escape-hatch lineage is described.
- [ ] C3 in `llm_step.ex`: `call_llm/2` with the bare-map normalization,
      `execute/2` passes `context`, `__call_llm__/4`; delete `call_llm/1`.
      Moduledoc table (`llm_step.ex:48`) and "The engine name…" section
      (`:182-186`) updated.
- [ ] Prose renames: `llm.ex` `:14` (moduledoc), `:22-24`, `:63-64`
      (typedoc), `:109` (`impl/0` doc names `call_llm/1`) — each names both
      arities or `call_llm/2`; `llm_call_log.ex:6,39`, `json_schema.ex:109`,
      `guides/building_a_pipeline.md:80`, `registry_test.exs:129` (comment),
      and `guides/host_wiring.md` §2 (context callbacks, D2's raise
      recommendation, and the metadata hazard (d) above).
- [ ] Hexdocs hygiene: hidden `__…__` helpers are never backticked in
      moduledocs/guides (so `mix docs` emits no autolink warning and
      `mix.exs` stays untouched in Phase 1, per A5); no D-numbers, phase refs
      or consumer names in `lib/` or `guides/` — run `agent-spec/DOCS.md`'s
      HARD grep with its positive control.
- [ ] Tests T1.1–T1.12; `OverridingStep` migrated; `lazy_llm_adapter.ex` added.
- [ ] Changelog input for the milestone: **Breaking** — "`call_llm/1` is
      replaced by `call_llm(context, input)`; an overriding `execute/2` passes
      its context." Other — the two optional callbacks.

**Success criteria.** T1.1–T1.12 green; the pre-existing `llm_step_test.exs`
assertions pass with only the `call_llm` call-shape edits; `behaviours_test.exs`
untouched and green; `mix docs` warning-free.

**Host lockstep (outside this repo, consumer-owned).** Amesbury reads this
checkout as a path dep, so 1.1 breaks its compile until its overriding steps
change. From the umbrella root, the fail-closed census:

    grep -rn 'call_llm(' apps --include '*.ex' --include '*.exs' > /tmp/call_llm.txt; echo "exit: $?"
    wc -l < /tmp/call_llm.txt   # positive control — must be non-zero before the migration

Test files are included on purpose: an umbrella test calling a step's
`call_llm/1` breaks the umbrella's suite just as a lib call breaks its compile.

Each consumer also greps for a step defining its own 2-arity `call_llm` —
it would collide with the generated `def call_llm/2`.

Every hit with one argument becomes `call_llm(context, input)` (the override
already receives `context`). Then the umbrella compile check from `CLAUDE.md` §2
("Two-gate reality"). The Amesbury and life-skills ports carry this in their own
docs; this design names it so 1.1 is not merged without telling them.

**Verification.**

    mix precommit
    mix test test/allm/pipeline/llm_test.exs test/allm/pipeline/llm_step_test.exs
    grep -rn 'call_llm/1\|call_llm(input)' lib guides test   # expect no hits except T1.7's own test name (9 at 18f1161 — pre-migration positive control)
    grep -cE 'def call_llm\(context, input\)' lib/allm/pipeline/llm_step.ex   # expect 1
    grep -cE 'def call_llm\([a-z_]+\)' lib/allm/pipeline/llm_step.ex          # expect 0

The grep cannot see the `WidgetStep.call_llm(Widget.Input.new(…))` call shape
(`llm_step_test.exs:281,294,303,311`); the compiler does — a leftover `/1`
call is an undefined-function warning, red under `--warnings-as-errors`.

---

## Phase 2 — typed classification as a step

### 2.1 Optional `classify/4`; allm floor 0.6.0

**Precondition.** The working tree's uncommitted `mix.exs`/`mix.lock` allm
bump (A5) is committed or discarded first — 2.1 rewrites that same line.

**Test plan (first).** In `test/allm/pipeline/llm_test.exs`:
- T2.1 `__classify__/5` on an adapter exporting `classify/4` passes state,
  questions, engine and the exact context; returns its result unchanged.
- T2.2 on an adapter without it → `RuntimeError` whose message contains
  `"classify/4"` and the adapter's module name.
- T2.2b on an adapter without `classify/4`, `__classify__/5` does not call
  anything else first (no partial dispatch).
- T2.3 a delegating adapter whose `classify/4` is
  `ALLM.classify(engine, state, questions: q)` over
  `ALLM.Engine.new(classification_adapter: ALLM.Providers.FakeClassification,
  adapter_opts: [classification_script: [{:answers, %{"team" => "billing"}}]])`
  returns `{:ok, %ALLM.ClassificationResponse{}}` — pins the real 0.6.0 shape,
  not a hand-built struct (`deps/allm/guides/classification.md` "A first call").
- T1.6 extended: the sorted optional set is exactly
  `[classify: 4, generate_structured: 5, resolve_engine: 2]`.

**Checklist.**
- [ ] C1 `classify/4` + `@doc` (the one-line `ALLM.classify/3` delegation as the example).
- [ ] C2 `__classify__/5`.
- [ ] `mix.exs`: `{:allm, ">= 0.6.0 and < 1.0.0"}`; the comment rewritten to
      say lib/ builds `ALLM.Classification*` structs since 2.1, so 0.6.0 is the floor.
- [ ] `guides/host_wiring.md` §2: `classify/4` is optional, needed only by
      ClassifyStep, and is a delegation to `ALLM.classify/3`. Also: a bare
      delegation records nothing into `ALLM.Pipeline.LLMCallLog`
      (`llm_call_log.ex:5-7` — the host's engine writes entries), so a
      classify step's step log shows no calls and 0 total tokens unless the
      host records one; the `classify/4` `@doc` says the same.

**Success criteria.** T2.1–T2.3 + extended T1.6 green; `mix deps.get` resolves
without an override; `mix hex.build` succeeds (release gate input).

**Host lockstep (consumer-owned).** The `>= 0.6.0` floor forces every path-dep
consumer (Amesbury, life-skills, Legendis) onto allm ≥ 0.6.0 when 2.1 lands.
0.6.0 carries breaking changes of its own (`deps/allm/CHANGELOG.md`, "Breaking
changes" under `[REL] v0.6.0` — seven bullets, including (not limited to)
closed error enums gained members, Anthropic `input_tokens` now totals cached
tokens, image `:variation` removed; read the whole list). Each
consumer checks its own exhaustive matches on `EngineError`/`ValidationError`
reasons before taking 2.1; this design names it so 2.1 is not merged without
telling them.

**Verification.**

    mix precommit
    mix hex.build
    grep -n '{:allm,' mix.exs    # expect ">= 0.6.0 and < 1.0.0"

### 2.2 `use ALLM.Pipeline.ClassifyStep`

**Test plan (first).** `test/allm/pipeline/classify_step_test.exs`
(`async: false`, installs a `ClassifyStub` via `:allm_pipeline` env and
restores — §5; the stub delegates to `ALLM.classify/3` over FakeClassification
as T2.3, scripted per test). A fixture `TriageStep` with Output fields
`department: atom(), values: [:billing, :technical, :other]`,
`team_name: String.t()`, `frustration: float()`, `refund: float()`,
`answers: map()`, `tokens_used: integer()`. FakeClassification scripts a
choice only from the question's own options (it raises `ArgumentError`
otherwise, measured), so every scripted choice — including T2.5's `"x"` — is
listed among the question's options.
- T2.4 generated `execute/2` → struct with `department: :billing`,
  `frustration: 1.25`, `refund: 0.9`, `answers` holding three
  `%ALLM.ClassificationAnswer{}`.
- T2.5 choice outside vocabulary with `:other` declared → `:other`; a second
  fixture without `:other` → `{:error, {:coerce, [department: {:unknown_value, "x"}]}}`.
- T2.6 choice into a `String.t()` field → the string unchanged; a `:yes_no`
  answer into a `boolean()` field and a `:choice` into a `float()` field →
  `{:type_mismatch, _}` coerce issues.
- T2.7 `call_classifier/2` validation, the stub **not** called in any case:
  id `"nope"` → `{:invalid_questions, unknown: ["nope"]}`; id `"answers"` →
  same; `%{}` → `{:invalid_questions, empty: []}`; `%{:department => q, "department" => q}`
  → `{:invalid_questions, duplicate: ["department"]}` (a key naming a declared
  field, so the earlier `unknown:` check cannot fire first).
- T2.8 the stub saw the step's context (run option visible) — parity with T1.8.
- T2.9 adapter error → `{:error, {:llm_error, _}}`.
- T2.10 compile-time rejections via `Code.eval_string/1` under
  `System.unique_integer/1` names (§7): missing `state/1`; missing
  `questions/1`; unknown option; missing `type:`/`engine:`; `output:` not a
  schema module; an Output field declaring `wire:`; an `atom()` Output field
  without `values:`. Each message names the module.
- T2.11 an overriding `execute/2` calling `call_classifier/2` + `coerce/2`
  yields a struct equal to the generated path's.
- T2.12 `@behaviour ALLM.Pipeline.Step` is declared (the census test's
  attribute leg — `llm_step.ex:53-57`).
- T2.13 a `coerce/2` call whose `:choice` answer has `choice: nil` (hand-built
  `%ClassificationAnswer{type: :choice}`) leaves `department` at its default —
  NOT `:other`, though `:other` is declared. Same for `score: nil` and
  `yes_probability: nil`.
- T2.14 **Executor path** (DB-backed, per §3): `Executor.run_step(run,
  TriageStep, input, nil, [])` → `{:ok, step_log, output}`, and
  `step_log.output_data["answers"]["department"]["choice"] == "billing"` —
  exercises `cast/1` on the Output and `StepLog`'s struct serialization of the
  `answers` map (`step_log.ex:701`).

**Checklist.**
- [ ] `lib/allm/pipeline/classify_step.ex` per C4: moduledoc (what it
      generates, the coerce table, thresholds-are-yours), `__using__/1`,
      `__before_compile__/1`, `__validate__!/2`.
- [ ] `llm_step.ex`: `@doc false __assert_input_struct__!/2` (the existing
      private body, renamed-and-exposed, `LLMStep` calls it too),
      `@doc false __coerce_atom__/2` and `@doc false __llm_error__/1` (the
      existing `llm_error/1`).
- [ ] `guides/building_a_pipeline.md`: a short "A classification step"
      section after §2 pointing at the moduledoc as authority.
- [ ] Tests T2.4–T2.14.
- [ ] README feature list (`:26`), `host_wiring.md:59-60`, and
      `building_a_pipeline.md:238` name ClassifyStep.
- [ ] Changelog input: "Add `use ALLM.Pipeline.ClassifyStep` over ALLM 0.6.0
      typed classification; the LLM seam gains optional `classify/4`."

**Success criteria.** T2.4–T2.14 green; `mix docs` builds with the new module;
dialyzer clean over the new specs.

**Verification.**

    mix precommit
    mix test test/allm/pipeline/classify_step_test.exs
    grep -c 'defp coerce_scalar(:atom' lib/allm/pipeline/classify_step.ex   # expect 0 — no copy of the vocabulary rule
    grep -c 'defp coerce_scalar(:atom' lib/allm/pipeline/llm_step.ex        # positive control: expect 3 (measured at 18f1161)
    grep -c '__coerce_atom__' lib/allm/pipeline/classify_step.ex            # positive control: expect ≥ 1 — the shared rule is used

---

## Assumptions

- A1. Legendis's adapter will export `/1` + `/4` alongside `/2` + `/5` (D2's cost).
  Communicated back via the response to their request (not this repo's file).
- A2. No in-tree LLM adapter besides the test stubs: `grep -rn '@behaviour ALLM.Pipeline.LLM$' lib test`
  at `18f1161` → only `test/allm/pipeline/llm_step_test.exs:27`. So the new
  optional callbacks need no stubs anywhere (`CLAUDE.md` §1's mandatory-callback
  rule does not fire — nothing mandatory is added).
- A3. Every DSL step already receives the run's `opts` in its context
  (`dsl/runtime.ex:531` → `step_opts/1` at `:724-725` → `executor.ex:386`
  `Context.new/3`); Phase 1 changes nothing upstream of `execute/2`. T1.10/T1.11
  verify it rather than trust this.
- A4. ALLM 0.6.0's classification API is as read from `deps/allm` at the
  locked 0.6.0 (`deps/allm/mix.exs:4`): `ALLM.classify/3`
  (`allm.ex:2202-2219`), `ClassificationAnswer` fields
  (`classification_answer.ex:57-78`), `ClassificationResponse.usage`
  (`classification_response.ex:42-62`).
- A5. The uncommitted working-tree change (`mix.exs` allm `>= 0.4.2 and < 1.0.0`,
  `mix.lock` allm 0.6.0) is the user's in-flight work; Phase 1 does not touch
  either file, and 2.1 raises the floor on top of it.
- A6. The next release after Phase 1 is a minor bump (0.1.x → 0.2.0) because
  removing `call_llm/1` breaks step authors; the release script performs it
  (`CLAUDE.md` §8), not this design.

## Definition of Done

- Every Status row Complete; `mix precommit` green at the tip.
- `@spec` + `@doc` (or `@doc false` with a reason) on every new public function
  in C1–C4.
- No new serializable struct, so no round-trip test is owed.
- Changelog inputs from 1.1, 2.1, 2.2 reach the milestone's `/changelog` entry,
  1.1's under **Breaking changes**.
- The consumer census table above is restated, measured, in `_RECORDS.md` at
  closure.
- Code review + arch/security review run per subphase.
