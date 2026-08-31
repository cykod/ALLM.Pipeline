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
