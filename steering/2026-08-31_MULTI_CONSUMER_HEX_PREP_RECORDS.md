# Multi-Consumer + Hex Release Prep — Implementation Records

Companion to `2026-08-31_MULTI_CONSUMER_HEX_PREP.md`. Per-subphase deviations,
verification transcripts, and closure notes.

---

## Subphase 1 — Package-side namespace rename + Dynamo default table

**Status: Completed** (this repo's `mix precommit` + two-direction dynamo pair
green; review gates run and clean — functional-review APPROVED (live suite
green), code-review ship-as-is (0 High/Med, 2 Low: F1→HANDOFF for subphase 3,
F2 nice-to-have left for polish), security-review no-issues (N/A confirmed),
design-review N/A (backend-only diff)). Artifacts under
`.work/{reviews,code-reviews,security-reviews,design-reviews}/2026-08-31-subphase1-namespace-rename*`.
Subphase 2 (umbrella lockstep) is NOT part of this run; the umbrella is red on
the path dep until the user lands it on the host.

### What changed

Mechanical atom substitution `:amesbury_scraper` → `:allm_pipeline` plus two
`"amesbury_artifacts"` string renames (C2), plus the prose the rename falsified.

- **`lib/` — 12 files, 43 atom sites** (re-derived, matched the design's count):
  `registry.ex` (incl. `@otp_app`, line 154), `llm.ex`, `store.ex`,
  `artifact_store.ex`, `artifacts.ex`, `config.ex`, `llm_call_log.ex`,
  `lock.ex`, `artifacts/{dynamo,filesystem,s3,tiered}.ex`. The substitution
  also covered every moduledoc `config …` example in those files.
- **`dynamo.ex:66` (C2)**: coded fallback table `"amesbury_artifacts"` →
  `"allm_pipeline_artifacts"`.
- **`config/test.exs`**: three `config :amesbury_scraper, …` blocks →
  `:allm_pipeline`; deleted the now-false namespace-non-goal comment; kept the
  distinct-Dynamo-table note and the shared-MinIO-bucket note.
- **`test/` — 13 files, 137 atom sites**: substitution moved both the
  `Application.put_env/delete_env` seam usages AND the C3 message assertions
  (`config_test.exs:69,81,91,119,156` — the string `":amesbury_scraper"`
  contains the atom token, so one substitution flips both). Fixture rename
  `registry_test.exs:458` `dynamo_table: "amesbury_artifacts"` →
  `"allm_pipeline_artifacts"` (filler value in an unknown-option rejection
  test; cosmetic, follows C2).
- **Prose the rename falsified** (rewritten, not blockquote-corrected — these
  are the framework's own docs, current truth):
  `registry.ex` moduledoc "`:allm_pipeline` is the config namespace" section +
  `@otp_app` comment; `config.ex:48` clause; `agent-spec/CODE_REVIEW.md:41`
  (the "do NOT flag" bullet retargeted from the old namespace to the
  not-centralized-into-an-accessor decision); `README.md:129-135` boot-notice
  paragraph deleted; `CLAUDE.md` §1 namespace sentence (line ~46), §5 setup
  example (lines ~198-221), and the §6 env-specific `config` example line ~238
  (falsified example config line, not in the design's explicit checklist but
  spelled the old atom — corrected to keep the doc accurate).

No seam, arity, return-shape, or schema change. Behavior-preserving.

### Deviations

- **§6 example line (CLAUDE.md ~238) corrected beyond the checklist.** The
  subphase-1 checklist named §1 line 46 and §5; it did not name the §6
  `config :amesbury_scraper, ALLM.Pipeline.Artifacts, …` example. That line is
  an example config a consumer would write and is falsified by the rename, so
  it was updated in the same commit (a stale namespace in an example is a
  latent wrong instruction). Recorded here rather than corrected in the design.
- **Host-path (`apps/amesbury_scraper/…`) and operator-string mentions left in
  place.** `grep -rn 'amesbury_scraper' lib/` still returns 5 non-atom hits
  (`llm_step.ex:37`, `fan_out.ex:43`, `executor.ex:705`, `dynamo.ex:391`,
  `lock/advisory.ex:12`) and the `Dynamo.exclusions/0` operator string still
  names the Amesbury umbrella's `docker-compose.dev.yml`. These are the
  hexdocs-facing prose sweep — **subphase 3**, explicitly out of subphase 1's
  scope (design "MODIFY — subphase 3"). Not touched.

### Environment note

Service stack was DOWN in the devcontainer at start. Brought it up with
`docker compose up -d` (Dynamo :4028, MinIO :4026) and
`docker compose --profile postgres up -d` (Postgres). `host.docker.internal`
from this devcontainer resolves to the OrbStack host, which runs a *different*
Postgres on :5432 lacking the `postgres` role; the compose Postgres is a
sibling container reached only by its network IP. Ran the suite with
`DATABASE_HOST=<compose-pg-ip> DATABASE_USER=postgres DATABASE_PASSWORD=postgres`.
Dynamo/MinIO were reachable via the preset `host.docker.internal` endpoints.
All verification commands below were run this way (real services, not skipped).

### Verification transcript (all run, all green)

```
# Baseline before changes (start-green):
mix test  →  3 doctests, 600 tests, 0 failures  (stack up)
mix test 2>&1 | grep -c 'but the application is not available'  →  1  (boot notice positive control)

# After changes:
mix precommit  →  EXIT 0  (compile 0 warnings, format clean, 600 tests 0 failures)
grep -rn ':amesbury_scraper' lib/ test/ config/ | wc -l          →  0
grep -rc ':allm_pipeline' config/test.exs                        →  6   (positive control, non-zero)
mix test 2>&1 | grep -c 'but the application is not available'   →  0   (boot notice gone)

# Two-direction dynamo pair (CLAUDE.md §4):
mix test                                        →  3 doctests, 600 tests, 0 failures   (NO "Excluding tags")
DYNAMODB_ENDPOINT=http://127.0.0.1:9 mix test   →  3 doctests, 600 tests, 0 failures, 20 excluded
                                                   + operator message (table "allm_pipeline_artifacts_test")
```

Matches CLAUDE.md §4's table exactly (0 failures both directions, 20 excluded
only when down).
