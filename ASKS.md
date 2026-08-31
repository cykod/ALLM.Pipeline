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
