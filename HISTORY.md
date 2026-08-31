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
