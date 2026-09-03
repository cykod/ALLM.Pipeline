## [FEAT] Inline input_schema/output_schema blocks for steps
*Thursday, September 3rd at 6pm*
A step can now declare its Input and Output schemas inline instead of writing 
out the nested modules and then restating them in the `use` options. The 
hand-written form is unchanged and still required for a schema shared by two 
steps or living in its own file — the sugar is additive, and every existing 
declaration compiles as before.

- `ALLM.Pipeline.Schema` gains `input_schema/2` and `output_schema/2`, which 
expand to exactly the nested module written out by hand. The `defmodule` is 
emitted as an alias rather than a computed atom, which is what keeps the short 
`%Input{}` alias resolving in the step body.
- `use ALLM.Pipeline.LLMStep` defaults `input:`/`output:` to the nested 
`Input`/`Output`, and imports its own `output_schema/2` that defaults 
`json_schema: true` on. The compile-time struct and derivation probes still 
run, against the defaulted names.
- New `use ALLM.Pipeline.Step` injects the behaviour, imports the blocks, and 
derives `input_schema/0`/`output_schema/0` from whichever blocks a module 
declares. A block plus a hand-written accessor of the same name raises rather 
than degrading into a "clauses must be grouped" warning against generated code.
- Corrects the `@impl true` on `prompt/1` in the moduledoc and guide examples: 
it is required by the macro, not by the `Step` behaviour, so copying it was a 
`--warnings-as-errors` build failure for a consumer.

---

## [TWK] Release script tolerates dirty CHANGELOG.md and ASKS.md
*Wednesday, September 2nd at 3pm*
The Phase A clean-working-tree check no longer requires --allow-dirty when the 
only dirty paths are CHANGELOG.md and ASKS.md — exactly the record files that 
/changelog and ask-logging leave uncommitted going into a release. Any other 
dirty path still aborts (or needs --allow-dirty, which remains as the full 
bypass). Phase B (--finalize) now stages ASKS.md alongside mix.exs and 
CHANGELOG.md into the Release commit. The script still mutates only mix.exs and 
never checks out the record files, so a rollback can't clobber notes or logs.

---

## [DOC] Broaden the docs-review lane's grep-blind-spot charge
*Tuesday, September 1st at 9am*
Applied the DOC_UPDATES phase retro's one rule-worthy finding: the code-review 
docs-history lane said to watch 'the two things the release-time grep can't', 
but the run proved there are more blind spots (D6: host references the token 
set doesn't name; D7: a doc claim that is simply false). Refined that clause in 
agent-spec/CODE_REVIEW.md in place to name all four checks — over-strip, host 
paraphrase, whole-surface scan for non-token module names, and a factual 
spot-check against runtime code. Merge-in-place, not an append, per the 
consolidation rule.

---

## [BUG] Fix false metrics from: text in the dsl.ex raise message
*Tuesday, September 1st at 1am*
Phase-retro follow-up to the hexdocs overhaul: the compile-time ArgumentError 
raised when 'metrics' is declared without 'from:' described the hook as 'taking 
what summarize produced'. The runtime applies the from: hook to the accumulator 
(from.(acc)), so the message was factually wrong — the same falsehood the doc 
sweep already corrected in the rendered ALLM.Pipeline.Dsl moduledoc. Reworded 
to 'taking the accumulator'. No behavioral change beyond the error string; no 
test pinned the wording (dsl_test 37 tests, 0 failures).

---

## [DOC] Add building-a-pipeline guide; fix false metrics from: doc
*Tuesday, September 1st at 1am*
Final subphase of the hexdocs overhaul. Adds guides/building_a_pipeline.md, an 
end-to-end application tutorial (authoring a Step with Schema Input/Output, an 
LLMStep, composing with use ALLM.Pipeline via stage/fan_out/metrics/summarize, 
invoking run/1, and reading a run back through ALLM.Pipeline.Query), registered 
in mix.exs docs/0 :extras with reciprocal cross-links from README and 
host_wiring.md. The guide is born present-tense and host-neutral (MyApp.* 
throughout), points at each normative moduledoc rather than duplicating it, and 
all ten real ALLM.Pipeline.* autolinks resolve so mix docs stays warning-free. 
Also corrects a pre-existing falsehood the guide surfaced: ALLM.Pipeline.Dsl's 
docs claimed metrics from: receives what summarize produced, but the runtime 
applies the hook to the accumulator (from.(acc)) — the two rendered doc 
statements (the hook table and the metrics @doc) are fixed to say accumulator. 
mix precommit green; the whole-surface banned-pattern grep over doc/*.md is 
zero, completing the overhaul (4/4).

---

## [DOC] Purge history from batch-B moduledocs, README, CHANGELOG
*Tuesday, September 1st at 1am*
Subphase 3 (final sweep) of the hexdocs overhaul: apply the C1 rule to the 
remaining ~20 batch-B moduledocs, host-neutralize the README (the hexdocs main 
page — drop the Phases 1-8 narrative and the path-dep umbrella section, keep 
the consumption mechanism generic), and reword the CHANGELOG's extraction-plan 
clause while keeping its :amesbury_scraper migration note. Also closes a 
manifest omission (deviation D6): two files the design's HARD-token source grep 
never listed — json_schema.ex and llm_call_log.ex — still named a host 
engine function, a host test file, and host domain nouns in their moduledocs; 
the code-review lane caught them and they were genericized in place. After this 
batch the whole-surface banned-pattern grep over doc/*.md (changelog carved 
out) returns zero, the release guard goes silent, ExDoc emits zero warnings, 
the ALLM.Pipeline.Text doctest is preserved, and mix precommit is green (600 
tests, dialyzer clean). No behavioral code.

---

## [DOC] Purge development history from batch-A moduledocs
*Tuesday, September 1st at 12am*
Subphase 2 of the hexdocs overhaul: apply the C1 rule to the 11 batch-A 
moduledocs (the DSL/lifecycle/executor cluster — pipeline.ex, llm_step, 
executor, dsl, dsl/item, dsl/resource, dsl/runtime, dsl/stage, fan_out, 
context, lifecycle). Deletes development-phase narrative and drops (Phase N Dx) 
tags, genericizes consumer-specific names to MyApp.*, and restates 
historically-framed live status as present tense — while preserving every 
current-constraint rationale (the over-strip guard). The flagship pipeline.ex 
example is replaced wholesale with MyApp.ReportPipeline, retaining all five 
hard DSL constructs. Only @moduledoc/@doc/@typedoc strings changed; the BATCH_A 
banned-pattern grep over regenerated doc/*.md returns zero, ExDoc emits zero 
warnings, and mix precommit stays green (600 tests, dialyzer clean). No 
behavioral code.

---

## [DOC] Add hexdocs history-purge rule and publish-time guard
*Tuesday, September 1st at 12am*
Subphase 1 of the hexdocs overhaul (steering/2026-08-31_DOC_UPDATES.md): 
establish the durable rule that published hexdocs describe current 
functionality in the present tense, with no development-phase numbering or 
consumer-specific names. New agent-spec/DOCS.md carries the C1 categorization 
table, the C2 banned-pattern grep recipe (hard gate + positive control + soft 
advisory), and the C3 zero-warning invariant. A WARN-only 
hexdocs_history_warning/0 in scripts/release.exs regenerates doc/ at release 
time and flags any surviving history references (excluding changelog.md). 
CLAUDE.md and agent-spec/CODE_REVIEW.md gain pointer lines. Docs and 
release-script only — no behavioral code changed.

---

## [OTHR] Gate dialyzer in precommit and fix its 13 warnings
*Monday, August 31st at 9pm*
Dialyzer had never actually run to completion in this repo: a host-built PLT
baked absolute `/Users/…/.asdf` OTP paths that halt dialyzer inside the
devcontainer, so the release gate's dialyzer step was silently a no-op. A clean
container-native run surfaced 13 genuine, pre-existing warnings — all fixed 
—
and `dialyzer` is now the fourth step of the `precommit` alias so the gate
runs on every change.

- PipelineRun/StepLog `@type t`: made `status` nilable (`status() | nil`). A
  freshly built `%__MODULE__{}` (every insert/create path) has `status: nil`
  because the schema field carries no default, so it was not a subtype of
  `t()`, and dialyzer inferred every `changeset(%__MODULE__{}, …) |>
  repo().insert()` path — and their `Store.Ecto` delegates — as `no_return`.
- mix.exs: added `dialyzer: [plt_add_apps: [:mix, :ex_unit]]`. `precommit` runs
  in `:test` env, so dialyzer analyzes both `lib/mix/tasks/*` (`Mix.*`) and
  `test/support/*` (`ExUnit.Assertions.*`), whose refs are otherwise unknown.
- Artifacts.Dynamo.create_table/0: pass `key_definitions` as a keyword list,
  not a map, matching ExAws's `[{atom, type}, …]` spec — runtime-identical
  under the dep's `Enum.map` encoder, but the map form dialyzed as `no_return`.
- Docs: recorded dialyzer's move into `precommit` (CLAUDE.md §2/§8 and the
  release script's gate-count comment) and documented the PLT host-path
  contamination gotcha and its in-place rebuild fix.

---

## [DOC] Record subphase 2 landed host-side; MULTI_CONSUMER_HEX_PREP now 5/6
*Monday, August 31st at 8pm*
Captures the host-side landing of subphase 2 (umbrella lockstep seam-key move) 
on 2026-08-31: the design's Status table moves to 5/6 with subphases 1-4 and 6 
Complete, subphase 2 Complete host-side, and subphase 5 (v0.1.0 release) 
Deferred as user-gated on the public-remote and Hex-auth preconditions. The 
RECORDS companion gains a full subphase-2 section — the 16 umbrella config 
sites moved, the C2 table_name guard, the shared-DynamoDB environment repair, 
and the umbrella verification transcript (mix precommit exit 0, 2200 tests 0 
failures, with the :dynamo exclusion no longer firing, proving :dynamo config 
now reads through :allm_pipeline) — and discharges the previously-deferred 
subphase-4 schema-parity re-run. CLAUDE.md's header is updated to reflect that 
only the publish step remains. Doc-only.

---

## [DOC] Design second-consumer gap closure and consumer reply
*Monday, August 31st at 8pm*
Receive the second consumer's nine-item upstream prerequisite table and design
the six items MULTI_CONSUMER_HEX_PREP did not: its subphases 1/3/4 already 
closed
P1-P3 (re-measured at a10d672, not recalled). Six subphases, contracts C1-C4, 
each
with executed verification commands and positive controls.

- P9 goes further than asked: drop {:allm, "~> 0.4.2"} rather than widen it, on
  the measurement that lib/ and test/ hold three ALLM.* references and all three
  are comments about a struct arriving from the host. There is no call site, so 
a
  hard requirement was dictating a provider-library version for nothing.
- P6 widens LLM.result/0 with an optional usage: key. llm_step.ex:327 is a map
  pattern, so extra keys already pass; the subphase's value is converting that
  accidental tolerance into a pinned contract before someone tightens it.
- P5 corrects executor.ex's claim that Dsl.Runtime writes is_retry from a retry:
  declaration removed in Phase 5.10. The option is caller-supplied and live via
  run_step/5, and grep shows zero tests, so it gains its first pair.
- A gap the consumer's host-name-keyed sweep structurally could not see: paths 
in
  shipped files absent from the shipped tree - 9 steering/ refs, 6 .work/ refs, 
4
  citations of a scripts/nilability_predict.py that is not in this repo at all, 
and
  4 amesbury mentions in the migration moduledoc a new consumer is told to copy.
  The criterion returns 15 today with its positive controls at 5, so it is
  discriminating rather than vacuously empty.
- P4, P7 and P8 are declined with named triggers rather than absorbed silently,
  per the CLAUDE.md 7 lesson about constructs shipping green with zero 
consumers.
- The reply doc is written and sendable now: nine dispositions, measurement 
output
  pasted verbatim, and an explicit note that the package is 5/6 with only the
  user-gated Hex publish left.

---

## [DOC] Name the v0.1.0 public-API changes in CHANGELOG
*Monday, August 31st at 7pm*
Enriches the still-unreleased v0.1.0 CHANGELOG entry so it names this run's 
consumer-facing changes, per the MULTI_CONSUMER_HEX_PREP design's Definition of 
Done (subphase-5 precondition #1). Adds a 'Consumer-facing configuration' 
section for the config-namespace move to the package's own :allm_pipeline and 
the allm_pipeline_artifacts default Dynamo table, and 'Other changes' lines for 
the host-wiring onboarding guide, the canonical DDL shipped in the tarball, and 
the host-neutral hexdocs. No version bump: nothing has been released (no tags), 
so the changes fold into the existing unreleased v0.1.0 rather than inventing a 
v0.2.0. Subtitle broadened to 'Standalone, consumer-ready'.

---

## [TWK] Polish CLAUDE.md header wording after gate pass
*Monday, August 31st at 7pm*
Phase-end polish for the MULTI_CONSUMER_HEX_PREP auto-build run: replaces the 
opaque coinage 'single-consumer debts' in the CLAUDE.md header with the plainer 
'the debts that only held while there was one consumer' and reflows the 
paragraph to wrap width. Governed-doc meaning is preserved exactly (the 
enumerated debts, the two deferred subphases, the one-consumer fact, and the 
publishing trigger are unchanged). The only other deferred-Low, mix.exs's 
docs.extras "CHANGELOG.md": [], was verified to be load-bearing keyword-list 
syntax rather than redundant and correctly left as-is. Suite green (600 tests, 
0 failures).

---

## [DOC] Update agent docs for the multi-consumer, publish-ready reality
*Monday, August 31st at 7pm*
Subphase 6 of steering/2026-08-31_MULTI_CONSUMER_HEX_PREP.md: refreshes the 
governed agent docs so they stop describing a stale single-namespace world, 
while carefully NOT asserting anything not yet true (the Hex publish and 
umbrella lockstep are deferred to the host, and no second consumer exists yet). 
CLAUDE.md's header is reframed to publish-ready-not-published with the standing 
publish trigger refined rather than retired, and its section 7 census corollary 
now runs from every consumer repo as each port's own obligation; README's intro 
states sole-consumer-but-onboarding-ready; agent-spec/DESIGN.md's DDL note 
becomes per-consumer and names the now-shipped canonical migration as the 
source of truth. A dated CORRECTED note on the design's subphase-6 section 
flags that its checklist assumed a publish that has not happened. Doc-only; 
gate green (600 tests). Three items remain deferred to the host: the v0.1.0 
publish (subphase 5), the umbrella seam-key lockstep (subphase 2), and the 
umbrella schema-parity re-run.

---

## [DOC] Add host-wiring guide and ship canonical DDL in tarball
*Monday, August 31st at 6pm*
Subphase 4 of steering/2026-08-31_MULTI_CONSUMER_HEX_PREP.md: adds the consumer 
onboarding path so a new host can wire the framework and create the pipeline 
tables from the Hex tarball alone. New guides/host_wiring.md is a hexdocs extra 
with the five C4 sections (registry wiring, the optional llm: seam, production 
DDL adoption, artifact infrastructure, the consumer test-suite pattern), each 
citing its normative moduledoc rather than duplicating it. mix.exs adds the 
guide to docs.extras and adds guides + priv/test_repo/migrations to 
package.files so both the guide and the parity-checked test-harness migration 
ship in the tarball; the migration gains one moduledoc sentence naming it the 
canonical DDL reference (no DDL byte changed). README's host-consumption 
section is generalized to consumers-plural and points new hosts at the guide. 
Gates green (600 tests, mix docs clean with 13 live autolinks, tarball contains 
both paths); the umbrella schema-parity re-run is deferred to the host (sibling 
repo absent) and is safe by construction given the moduledoc-only migration 
edit.

---

## [DOC] Sweep Amesbury host names from lib/ moduledocs for hexdocs
*Monday, August 31st at 6pm*
Subphase 3 of steering/2026-08-31_MULTI_CONSUMER_HEX_PREP.md: removed every 
non-atom Amesbury-derived name from lib/ moduledocs and comments (24 files) so 
nothing host-specific reaches the public hexdocs. Host module examples became 
MyApp.* placeholders; host-as-evidence census sites became generic 'a consumer 
repo's census/twin test' phrasing with the concrete host-twin pointers 
relocated to CLAUDE.md section 1; operator-facing stack strings now point at 
this repo's own docker-compose.yml; two moduledoc bucket/root examples were 
genericized to my-artifacts. The live shared -test MinIO bucket in 
config/test.exs was deliberately left untouched (out of lib/, guards the shared 
round-trip). Prose-only, no code/spec/schema change; grep -rni amesbury lib/ is 
now 0, mix docs builds clean with no dangling autolinks, and the full gate is 
green (600 tests, 0 failures both dynamo directions).

---

## [OTHR] Rename config namespace :amesbury_scraper to :allm_pipeline
*Monday, August 31st at 6pm*
Subphase 1 of the multi-consumer/Hex-prep work 
(steering/2026-08-31_MULTI_CONSUMER_HEX_PREP.md): the package now reads and 
writes all of its application config under its own OTP app :allm_pipeline 
instead of the host's :amesbury_scraper — 43 atom sites across 12 lib/ files 
(including Registry's @otp_app) and 137 test sites, plus the Dynamo coded 
default-table fallback amesbury_artifacts to allm_pipeline_artifacts (contract 
C2). Aligning the config namespace with mix.exs's app: :allm_pipeline removes 
the standalone 'configured application not available' boot notice. The prose 
the rename falsified was rewritten in the same commit (registry/config 
moduledocs, the deleted README boot-notice paragraph, CLAUDE.md sections 1/5/6, 
agent-spec/CODE_REVIEW.md). Behavior-preserving: no seam, arity, return-shape, 
or schema change; full gate green (600 tests, 0 failures in both dynamo 
directions). Umbrella-side lockstep (subphase 2) and the v0.1.0 release 
(subphase 5) are deferred to the host.

---

## [OTHR] Hex release readiness: release script, devcontainer, metadata
*Monday, August 31st at 11am*
Ports the two-phase ALLM release script (gates plus regex version bump; never 
publishes or pushes) and adds the devcontainer plus a docker-compose service 
stack (DynamoDB Local, MinIO, optional postgres profile) on the umbrella's 
ports. mix.exs gains full publish metadata: a @version attribute for the 
script's bump, GitHub source_url and links now that the public remote exists, 
an ex_doc docs block with a deliberate skip_code_autolink_to list, and 
CHANGELOG.md in the tarball files. Five moduledocs gain t:/c:/fully-qualified 
references so the hexdocs build links cleanly, CLAUDE.md documents the stack 
and the release flow (§8), and the README adds service-stack and releasing 
sections. CHANGELOG.md and ASKS.md are seeded.

---

## [DOC] Bootstrap agent-spec/ lane specs from donor-project mining
*Monday, August 31st at 10am*
Seed the standalone repo with its agent-spec/ set: IMPLEMENTATION.md (workflow 
skeleton, verified mix bindings, Elixir stack lessons), REVIEW.md (iex-driven 
exercise doctrine for a headless library), DESIGN.md (design-doc structure and 
evidence discipline), and CODE_REVIEW.md (architectural invariants plus a 
do-NOT-flag list keyed to CLAUDE.md). Content was mined from the ALLM, 
amesbury, and unllmtd corpora, keeping toolchain-true lessons and dropping 
donor-specific detail; no FRONTEND.md since the package has no frontend. Specs 
reference CLAUDE.md's repo-specific sections rather than restating them.

---
