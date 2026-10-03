# ALLM.Pipeline: the run's context at the LLM seam — upstream change plan

*Written 2026-10-02 by Legendis Phase 3.6 (`steering/designs/2026-10-01_PHASE_3_TYPED_STORY_LOOP.md`
§ 3.6), for Phase 6 of `steering/PHASE_2026-09-30_INITIAL_PHASING.md`. Architecture: D10, D16, D18,
D19 (`steering/ARCH_2026-09-30_INITIAL_ARCHITECTURE.md`). Measured against the read-only mount
`/workspaces/ALLM.Pipeline` at `18f1161` ("Release v0.1.1"). Every `file:line` below is relative
to `/workspaces/ALLM.Pipeline/lib/allm/pipeline/` and was re-read on 2026-10-02.*

Built in ALLM.Pipeline's own project (D19), never patched from Legendis. Phase 6 (the first
pipeline) can't start its LLM steps until this lands in the mounted version.

## What Legendis needs, and why

Phase 6 runs the first `ALLM.Pipeline.LLMStep` through our `ALLM.Pipeline.LLM` adapter. That
adapter has three jobs the package's seam can't serve today:

1. **A per-run engine override.** The eval suite (D16) runs one pipeline on several models over
   the same cases. A step names an intent (`engine: :writer`). For an eval run, our adapter must
   resolve that intent to the engine the run was given, not the default one.
2. **The account on the LLM call.** Every paid call writes a usage event with its account (D18).
   The adapter writes it, so it needs the run's `account_id` (and the pipeline run and step ids)
   at call time.
3. **A usage report at the seam.** The usage event needs input, cached input, cache-write input
   and output tokens, the provider, the model and the latency. The seam's envelope carries a
   single token total.

All three come down to one gap: **the LLM seam never sees the step's context.**

## The gaps, cited

### 1. `resolve_engine` sees only the step's engine name

- `llm.ex:87`: `@callback resolve_engine(name :: atom()) :: engine()`. Its one argument is the
  step's declared intent.
- `llm.ex:22-27`: the moduledoc says so: `resolve_engine/1` "takes an atom naming a *call-site
  intent*".
- `llm_step.ex:377`: the only call, `engine = impl.resolve_engine(declaration.engine)`, inside
  `__call_llm__/3` (`llm_step.ex:375`), which receives the module, the declaration and the
  prompt, and nothing from the run.
- `llm_step.ex:184-186`: the step docs repeat that the name is resolved "at **call** time" through
  `resolve_engine/1`.

### 2. The context stops at `execute/2`

- The run's options do reach every step's context. A DSL run passes its `opts` into each step
  (`dsl/runtime.ex:531`, `step_opts/1` at `dsl/runtime.ex:724-725`), `Executor.run_step/5` takes
  them (`executor.ex:152`), and builds `Context.new(pipeline_run, step_log, opts)`
  (`executor.ex:386`). A step reads them with `Context.get_opt/3` (`context.ex:195-198`).
- But the generated `execute/2` drops it: `def execute(_context, input)` (`llm_step.ex:292`), then
  `call_llm(input)` (`llm_step.ex:293`). `call_llm/1` takes only the input
  (`llm_step.ex:264-265`), so neither `resolve_engine/1` nor `generate_structured/4`
  (`llm.ex:96-101`, arguments: prompt, schema, schema name, engine) can see an option, the run or
  the step log.

### 3. Run metadata exists, but not at the seam

- A run already has metadata: `field(:metadata, :map, default: %{})` (`pipeline_run.ex:107`),
  written by `Executor.create_pipeline_run(name, metadata, attrs)` (`executor.ex:63`). The DSL
  fills it from a pipeline's `metadata` hook over the run's `opts`
  (`dsl/runtime.ex:141-144`). So `account_id` can be **recorded** on the run today.
- What's missing is the call: the adapter can't read it, for the reason in gap 2. The only
  per-call channel is `LLMCallLog`, a process-dictionary collector the host's
  `generate_structured/4` writes into (`llm_call_log.ex:5-7`), which is a log, not an input, and
  which D10 keeps off outside the eval suite.

### 4. The envelope carries one token total

- `llm.ex:77-79`: `{:ok, %{parsed: map(), tokens: non_neg_integer()}}`. No cached input, no
  cache-write input, no input/output split, no model, no latency.
- `executor.ex:642`: the step log's `total_tokens/1` sums a `total_tokens` per call from the
  `LLMCallLog` entries. That is pipeline accounting, not a ledger per account (D18, "Over:
  ALLM.Pipeline's `pipeline_metrics` alone").

## The change we ask for

One additive change: **pass the step's `%ALLM.Pipeline.Context{}` to the LLM seam.**

- `ALLM.Pipeline.LLM` gains optional context-taking callbacks:
  - `resolve_engine(name :: atom(), context :: Context.t()) :: engine()`;
  - `generate_structured(prompt, schema, schema_name, engine, context :: Context.t()) :: result()`.

  The package calls the arity-2/arity-5 form when the adapter exports it, and falls back to the
  current arity-1/arity-4 form otherwise, so existing hosts don't change. (Or a single breaking
  rename: the package is at v0.1.x and Legendis is its third user. The library's maintainers
  choose.)
- The generated `execute(context, input)` passes `context` to `call_llm/2`, and
  `__call_llm__/4` passes it to both callbacks. **`call_llm/1` goes away in the same change**, so
  a step that overrides `execute/2` (a fan-out step has to: the generated `execute/2` makes one
  call, `llm_step.ex:292-293`) must call `call_llm(context, input)`. A `call_llm/1` that filled
  in `Context.detached/0` would hand the seam an empty context, silently dropping `:engines` (an
  eval would grade the default engine under another model's label) and `:account_id` (a usage
  event with no account, against D18). That breaks step authors, not hosts; the package is at
  v0.1.x, and a step with truly no run calls `call_llm(Context.detached(opts), input)` itself.
- Nothing else. With the context in hand, our adapter does all three jobs itself:
  - **override:** `Context.get_opt(ctx, :engines, %{})[name]`, falling back to the default
    engine for that name;
  - **account:** `Context.get_opt(ctx, :account_id)`, plus `Context.pipeline_run_id/1` and
    `Context.step_log_id/1` for the usage event's purpose fields;
  - **usage:** the adapter calls ALLM itself (through our metered wrapper, as the biographer does
    with `Legendis.Biographer.Metered`) and writes the usage event from ALLM's `Response.usage`
    before it returns the envelope. So the package needs **no usage callback** and no wider
    envelope: the seam is the chokepoint D18 wants, once it can see the account.

We deliberately don't ask for a usage callback or a richer `tokens` field. Both would put
Legendis's ledger shape into the package, and the context is enough.

### Contract we will consume

- Inside a DSL run, `context.opts` holds every key passed to `MyPipeline.run(opts)`
  (already true: `dsl/runtime.ex:724-725`).
- Outside a run, `Context.detached(opts)` (`context.ex:120-121`) carries the same keys, so an eval
  harness passes `engines:` and `account_id:` the same way.
- The context reaches the seam on every LLM call, including a step that fans out with
  `Task.async_stream` (the call runs in the step's process tree; the context is an argument, not
  process state).

### Tests we expect upstream

- A host adapter exporting the context-taking callbacks receives the step's context, with a run
  option visible through `Context.get_opt/3`, from both a DSL run and a direct
  `Executor.run_step/5`.
- An adapter exporting only the current callbacks still works unchanged.
- A step invoked with `Context.detached(opts)` passes those opts to the seam.
- A step overriding `execute/2` that calls `call_llm/2`, including from inside
  `Task.async_stream`, passes its context through to the seam.

### Noted while reading, not asked for here

- `llm_step.ex:397-399` logs `inspect(reason)` at `:error` for every LLM error. A provider error
  can quote the prompt, and Legendis prompts carry narrator prose, which `agent-spec/SECURITY.md`
  keeps out of logs. Our adapter can return a reason that carries no text. If that proves
  fragile, it becomes its own plan.

## Decision: the eval harness stays in Legendis

D19 listed "an eval harness that runs a pipeline over cases and engines" as a likely upstream
candidate. **We don't ask for it.** ALLM.Pipeline already lets a host run a step outside any
pipeline: `Context.detached/1` (`context.ex:110-121`) is documented as the context "for a Step
invoked **outside** any pipeline run — a mix task, a backfill, an eval harness". `execute/2` is
the `Step` behaviour's public callback (`step.ex:88`). So a harness built in Legendis calls
`Step.execute(Context.detached(engines: …, account_id: nil), input)` per case and engine, and
the override above does the rest.

Legendis's harness already exists for the biographer (`server/lib/legendis/evals/biographer.ex`,
`mix legendis.eval`): cases, runs, deterministic checks, a schema-constrained judge, and the
results table. Phase 6 extends it to pipeline steps. Cases, rubrics and judges are
product-specific, so they belong here.

## Status

Not started upstream. Phase 6 names it as a prerequisite. When it lands in the mount, drop the
stale PLT hash (`rm server/priv/plts/*.plt.hash`) before dialyzer
(`agent-spec/IMPLEMENTATION.md` § ALLM).
