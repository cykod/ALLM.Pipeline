# Asks

[IMPL] sat 8/29 10pm - Add hex release scripts/config and a devcontainer to ALLM.Pipeline, mirroring the release pattern used in ~/Projects/ALLM

[BOOT] mon 8/31 10am - Bootstrap agent-spec/ for ALLM.Pipeline from similar ~/Projects donors (Elixir, Ecto, hex package)

[MILE] mon 8/31 10am - Bootstrapped agent-spec/ lane specs (IMPLEMENTATION, REVIEW, DESIGN, CODE_REVIEW) mined from ALLM, amesbury, and unllmtd donors

[DSGN] mon 8/31 11am - Design the multi-consumer + Hex-release prep: namespace rename, hexdocs sweep, consumer onboarding, and v0.1.0 release (steering/2026-08-31_MULTI_CONSUMER_HEX_PREP.md)

[MILE] mon 8/31 11am - Committed hex release readiness: ported release script, devcontainer + service stack, publish metadata, and hexdocs-clean moduledoc references

[ABLD] mon 8/31 6pm - Auto-build MULTI_CONSUMER_HEX_PREP: rename config namespace to :allm_pipeline, host-neutral hexdocs, onboarding guide, and v0.1.0 Hex release prep

[IMPL] mon 8/31 6pm - Implement subphase 1 of MULTI_CONSUMER_HEX_PREP: package-side config namespace rename :amesbury_scraper -> :allm_pipeline plus Dynamo default table rename

[CDRV] mon 8/31 6pm - Code review on subphase 1 config-namespace rename (:amesbury_scraper to :allm_pipeline)

[MILE] mon 8/31 6pm - Renamed the pipeline config namespace :amesbury_scraper to :allm_pipeline (subphase 1) with C2 Dynamo default-table rename and falsified-prose fixes

[IMPL] mon 8/31 6pm - Subphase 3: hexdocs-facing lib/ prose sweep (remove non-atom amesbury mentions, relocate host-twin pointers to CLAUDE.md)

[MILE] mon 8/31 6pm - Swept Amesbury host names from lib/ moduledocs so the public hexdocs are host-neutral (subphase 3), relocating pointer facts to CLAUDE.md

[CDRV] mon 8/31 6pm - Code review on subphase 4 consumer onboarding guide + DDL packaging per steering/2026-08-31_MULTI_CONSUMER_HEX_PREP.md

[MILE] mon 8/31 6pm - Added the host-wiring onboarding guide and shipped the canonical test-harness DDL in the Hex tarball (subphase 4)

[CDRV] mon 8/31 7pm - Code review on subphase 6 (governed-doc updates) of MULTI_CONSUMER_HEX_PREP steering

[MILE] mon 8/31 7pm - Updated CLAUDE.md, README, and agent-spec/DESIGN for the multi-consumer publish-ready reality without over-claiming publish (subphase 6)

[RETR] mon 8/31 7pm - Retro on the package-side MULTI_CONSUMER_HEX_PREP run (4 batches)

[GATE] mon 8/31 7pm - Gate-review MULTI_CONSUMER_HEX_PREP package-side subphases 1/3/4/6 — did they succeed and get genuinely exercised

[MILE] mon 8/31 7pm - Polished the CLAUDE.md header wording after the gate passed (phase-end polish for the multi-consumer hex-prep run)

[MILE] mon 8/31 7pm - Named the v0.1.0 public-API changes (namespace, Dynamo default, shipped DDL/guide) in CHANGELOG per the release DoD

[MILE] mon 8/31 8pm - Designed the second-consumer gap closure (steering/2026-08-31_SECOND_CONSUMER_GAPS.md) and wrote the item-by-item reply doc for the consuming project

[MILE] mon 8/31 8pm - Recorded subphase 2 landing host-side and moved MULTI_CONSUMER_HEX_PREP to 5/6 (only the v0.1.0 publish remains, user-gated)

[MILE] mon 8/31 9pm - Added dialyzer to the precommit gate and fixed the 13 pre-existing warnings it surfaced (status-type nilability, :mix/:ex_unit PLT apps, Dynamo key_definitions shape) once a container-native PLT let it run

[DSGN] mon 8/31 9pm - Design hexdocs update: add a real-project implementation guide, strip phase/history references to focus on current functionality, and update agent-spec to keep hexdocs history-free

[BUILD] tue 9/1 12am - Build all 4 subphases of the hexdocs overhaul (agent-spec rule + release guard, sweep batches A & B, new building_a_pipeline guide) per steering/2026-08-31_DOC_UPDATES.md
2026-09-01 00:27 [FIX] Fix issues from DOC_UPDATES sub1 review set (code/security/design/functional); only F1 Medium actionable

[MILE] tue 9/1 12am - Committed hexdocs history-purge rule (agent-spec/DOCS.md), publish-time guard in release.exs, and CLAUDE.md/CODE_REVIEW.md pointers (Subphase 1)

[MILE] tue 9/1 12am - Purged development-phase history and consumer names from 11 batch-A moduledocs, preserving current-constraint rationale (Subphase 2)

[MILE] tue 9/1 1am - Purged history from 20 batch-B moduledocs, host-neutralized README/CHANGELOG, and closed a manifest omission in json_schema/llm_call_log (Subphase 3)

[MILE] tue 9/1 1am - Added guides/building_a_pipeline.md tutorial and corrected a false metrics from: doc in dsl.ex; hexdocs overhaul complete 4/4 (Subphase 4)

[RETR] tue 9/1 1am - Retro on the /safe-build run of the Hexdocs Overhaul (4 subphases of steering/2026-08-31_DOC_UPDATES.md)

[FIX] tue 9/1 1am - Fixed the false 'metrics from:' wording in the dsl.ex compile-time raise message (phase-retro follow-up), closing deviation D7 across all three occurrences

[GATE] tue 9/1 8am - Gate-review the DOC_UPDATES hexdocs overhaul (4 subphases) — assess whether each subphase succeeded and was actually exercised by its review/oracle

[MILE] tue 9/1 9am - Applied the DOC_UPDATES retro: broadened the docs-review lane's grep-blind-spot charge in agent-spec/CODE_REVIEW.md and marked the retro applied

[MILE] wed 9/2 3pm - Committed the release-script clean-tree allowlist for CHANGELOG.md/ASKS.md and Phase-B ASKS.md staging (release.exs + ASKS.md only)

[ASKS] wed 9/2 3pm - Assess whether the Step macros can autogenerate __MODULE__.Input/Output from inline input_schema/output_schema blocks to cut declaration noise

[MILE] thu 9/3 6pm - Added inline input_schema/output_schema blocks for steps, defaulted LLMStep's input:/output: to the nested modules, and introduced use ALLM.Pipeline.Step
