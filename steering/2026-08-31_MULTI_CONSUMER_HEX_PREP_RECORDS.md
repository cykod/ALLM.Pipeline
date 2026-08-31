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

---

## Subphase 3 — Hexdocs-facing `lib/` prose sweep

**Status: Completed** (this repo's `mix precommit` green, `mix docs` clean with
no autolink warnings, two-direction dynamo pair matches CLAUDE.md §4; review
gates run and clean — functional-review APPROVED (verified 0 `amesbury` in the
generated `doc/` tree, not just source), code-review ship-as-is 0 findings,
security-review no-issues (public-exposure check passed — sweep is a net
reduction in exposure), design-review N/A (docs-only diff)). Artifacts under
`.work/{reviews,code-reviews,security-reviews,design-reviews}/2026-08-31-subphase3-prose-sweep*`.

### What changed

Swept every non-atom `amesbury` mention from `lib/` per the design's Sweep
policy. Starting count `grep -rni 'amesbury' lib/ | wc -l` = **56** (subphase 1
had already removed the 43 atom sites); final count = **0** (literal zero — see
the bucket/root note below, both were resolvable). 23 `lib/` files touched.

Policy application:

- **Host module as example → neutral `MyApp.*`:** `llm.ex:7,18`,
  `llm_call_log.ex:6`, `llm_step.ex:62`, `telemetry.ex:64`, `metrics.ex:47`,
  `executor.ex:117`, `registry.ex:34,58,112-113,115,285`, `step_log.ex:28`,
  `pipeline.ex:274`, `text.ex:9-17`, `query.ex:8`, `store/ecto.ex:33`,
  `lock.ex:47`, `config.ex:6-7,75,97-98,129,150`.
- **Host module as evidence → "a consumer repo's census/twin test":**
  `llm_step.ex:36-40` and `executor.ex:704-706` (Step-schema census),
  `fan_out.ex:29,43-48` (fan-out site census), `dynamo.ex:391-396` (tag-list
  drift guard). Concrete host-twin pointers relocated to CLAUDE.md §1 (new
  "Host-twin guards" note); the dynamo drift-guard fact was already in §4 and
  was NOT restated.
- **Operator strings → THIS repo's `docker-compose.yml`:** `s3.ex:109`,
  `dynamo.ex:426`. Both now read "this repo's `docker-compose.yml` serves it:
  `docker compose up -d`" (§4 pair re-run to confirm — see transcript).
- **Host-named doc examples → neutral values:** `s3.ex:27`
  `bucket: "amesbury-artifacts"` → `"my-artifacts"`; `filesystem.ex:13`
  `root: "/var/tmp/amesbury-artifacts"` → `"/var/tmp/my-artifacts"`.
- **Comment-only `alias Amesbury.Repo` → "a host repo module":**
  `metrics.ex:219`, `step_log.ex:756`, `pipeline_run.ex:471`,
  `lock/advisory.ex:131`. House-shape cites `schema.ex:585`,
  `json_schema.ex:166` → generic "cross-boundary mirror" phrasing.
- **Other host-path/attribution mentions genericized:** `metrics.ex:173`
  (non-Amesbury boards → out-of-scope items), `lock/advisory.ex:11-12`
  (host membership guard), `s3.ex:33,278` (`Amesbury.Media.S3`),
  `nilability.ex:52` (Amesbury repo's CLAUDE.md → "the house rule").

### Relocated to CLAUDE.md

Added a **"Host-twin guards"** note to §1 (right after the runtime-resolution
paragraph) naming the three concrete host-twin tests the `lib/` prose used to
carry — `StepSchemaCensusTest`, `FrameworkBoundaryGuardsTest`, and the
umbrella's registry-declared-values / `pipelines_test.exs` lock-keys guards —
with a cross-reference that the `:dynamo` tag-list guard is already in §4 and the
DSL production-declaration census in §7 (not restated in both).

### Deviations / non-obvious resolutions

- **Bucket/root doc examples were changed (contra the HANDOFF's literal
  "do NOT touch").** The HANDOFF Open item and the design's Sweep-policy line
  conflict on `s3.ex:27` / `filesystem.ex:13`. Resolved per the build prompt's
  written rule: these two are **pure `@moduledoc` example config blocks with no
  runtime effect** — the real coded defaults are `Keyword.get(:bucket)` → `nil`
  (`s3.ex:61`) and `Path.join(System.tmp_dir!(), "allm_pipeline_artifacts")`
  (`filesystem.ex`, design Out-of-scope §65). Verified `grep -rn
  '"amesbury-artifacts"'` finds NO test round-tripping the plain (non-`-test`)
  value. So they were neutralized. The **live** shared resource — the `-test`
  bucket at `config/test.exs:31` (`"amesbury-artifacts-test"`) — was LEFT
  untouched (out of `lib/`, out of scope, guards the shared-MinIO round-trip).
- **`fan_out.ex` keeps `FrameworkBoundaryGuardsTest` and "in this repo" in its
  moduledoc** — `test/allm/pipeline/fan_out_test.exs:131-133` asserts both
  substrings present and `refute`s a specific stale phrasing. Genericized the
  surrounding "Amesbury umbrella repo" / "apps/amesbury_scraper/lib" wording but
  kept the two test-pinned tokens; the concrete host-repo file path moved to
  CLAUDE.md §1.
- **`mix.exs` autolink list unchanged.** `docs.skip_code_autolink_to` holds only
  `ALLM.Pipeline.*` function entries — none reference an amesbury name, and the
  sweep deleted no reference an entry masked. Checklist item 2 satisfied with no
  edit. (The 5 `amesbury` mentions in `mix.exs` are in comments outside `lib/`,
  out of subphase-3 scope.)

### Verification transcript (all run, all green)

```
grep -rni 'amesbury' lib/ | wc -l          →  0        (literal zero)
grep -rci 'pipeline' lib/allm/pipeline.ex  →  109      (positive control, non-zero)
mix precommit                              →  EXIT 0   (compile 0 warnings, format clean, 3 doctests 600 tests 0 failures)
mix docs                                   →  EXIT 0, no 'warning:'/'could not be found'/broken-ref lines
mix test test/allm/pipeline/fan_out_test.exs → 4 tests, 0 failures

# Two-direction dynamo pair (CLAUDE.md §4):
mix test                                        →  3 doctests, 600 tests, 0 failures   (NO "Excluding tags")
DYNAMODB_ENDPOINT=http://127.0.0.1:9 mix test   →  3 doctests, 600 tests, 0 failures, 20 excluded
                                                   + operator message now naming THIS repo's docker-compose.yml
```

Run in the devcontainer with `DATABASE_HOST=<compose-pg-ip>
DATABASE_USER=postgres DATABASE_PASSWORD=postgres` (same environment note as
subphase 1). Real services, nothing skipped.

---

## Subphase 4 — Consumer onboarding guide + DDL shipping

**Status: Completed** (this repo's gates green — `mix precommit` exit 0, `mix
docs` clean with the guide rendering 13 live moduledoc autolinks, `mix hex.build`
packs both `guides/host_wiring.md` and the migration; review gates run and clean —
functional-review APPROVED (both paths verified in the packed tarball, migration
moduledoc-only, suite green), code-review ship-as-is (1 cosmetic Low: redundant
`"CHANGELOG.md": []` in mix.exs, left for polish), security-review no-issues (1
non-blocking INFO: the newly-shipped migration moduledoc names host details, but
pre-existing and already shipped via CLAUDE.md — consistent with the design's
accepted tarball position), design-review N/A (docs/packaging diff)). Umbrella
schema-parity re-run DEFERRED (sibling repo absent) — safe by construction
(moduledoc-only edit, zero DDL bytes), carried in HANDOFF for the user's host run.

<details><summary>original "Built, gates pending" status (superseded by the Completed line above)</summary>

Docs + packaging only; no `lib/` behavior change, no DDL byte change. The
umbrella schema-parity re-run is DEFERRED — the sibling `~/Projects/amesbury`
repo is absent from this environment (see the deferred note below).

</details>

### What changed

- **`guides/host_wiring.md`** (NEW file; created the `guides/` dir — none
  existed). A hexdocs extra with the five C4 sections, each **citing** its
  normative moduledoc home rather than restating it (the design is emphatic
  that inlining a second copy re-creates the two-sources-of-truth the moduledocs
  warn about):
  1. **Registry wiring** — the `use ALLM.Pipeline.Registry` declaration +
     `install/0` from `Application.start/2`; points at `ALLM.Pipeline.Registry`'s
     moduledoc for the key-mapping / `put_new` asymmetry / tuple form / when
     `install/0` runs.
  2. **The optional `llm:` seam** — undeclared ⇒ `ALLM.Pipeline.LLM.impl/0`
     raises by design; points at `ALLM.Pipeline.LLM`'s moduledoc.
  3. **Production DDL adoption** — copy
     `priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs` into
     the host's `priv/repo/migrations/`; table names are contract; host owns and
     freezes them.
  4. **Artifact infrastructure** — DynamoDB (`:dynamo` `table_name:` +
     `Dynamo.create_table/0`), S3 bucket, the `Tiered` default; cites the three
     adapter moduledocs; notes the `ex_aws*` optional deps.
  5. **Consumer test-suite pattern** — a host test registry, sandbox checkout
     via `ALLM.Pipeline.Config.repo/0`, and `Artifacts.Dynamo.exclusions/0` as
     the shared stack-down probe (the cross-repo drift guard, `CLAUDE.md` §4).
  Neutral `MyApp.*` names throughout, consistent with the subphase-3-swept
  moduledocs; nothing names Amesbury. The `exclusions/0` example uses the real
  `{tags, message}` 2-tuple return shape (verified against `dynamo.ex:414` and
  this repo's own `test/test_helper.exs:34` — an initial draft with an invented
  `{:exclude, …}`/`:ok` shape was corrected before any gate).

- **`mix.exs`** — two deltas:
  - `docs.extras` now
    `["README.md", "guides/host_wiring.md": [title: "Wiring a host"], "CHANGELOG.md": []]`
    (was `["README.md", "CHANGELOG.md"]`). `docs.main` stays `"readme"`; no
    `groups_for_extras` in this config, so adding to `extras` is sufficient for
    the page to render.
  - `package.files` now
    `~w(lib guides priv/test_repo/migrations .formatter.exs mix.exs README.md CHANGELOG.md LICENSE CLAUDE.md)`
    (added `guides` + `priv/test_repo/migrations`), with a comment naming why
    both ship (wire-from-tarball).

- **Migration moduledoc**
  (`priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs`) — ONE
  sentence added to the `@moduledoc` naming this file as the canonical DDL
  reference a new consumer copies, and pointing adoption mechanics at the guide
  (not restated here). **DDL untouched** — see the deferred-parity evidence.

- **`README.md` "Host consumption"** — renamed from "Host consumption (the
  path-dep umbrella)"; generalized to consumers-plural with a lead paragraph
  pointing new hosts at `guides/host_wiring.md`, and the umbrella-specific
  detail demoted to a "The path-dep umbrella" subsection ("The first consumer,
  an internal umbrella…").

### Deferred verification — umbrella schema-parity re-run

The design's checklist item "Re-run the schema-parity check in the umbrella
(host twin `AmesburyScraper.Pipeline.FrameworkBoundaryGuardsTest`)" CANNOT run
here: `~/Projects/amesbury` is absent from this environment. It is deferred to
whenever the umbrella is next available (naturally, subphase-2 lockstep or the
subphase-5 release preconditions).

**Evidence it is safe to defer:** the migration edit is **moduledoc-only**, so
schema parity is preserved by construction. `git diff -- priv/test_repo/migrations/`
shows the entire hunk inside the `@moduledoc` string (lines 18–21 region); the
diffstat is `4 insertions(+), 1 deletion(-)`, all prose. Zero lines at or below
`use Ecto.Migration` / inside `change do` (the `create table` / `add` / `create
index` calls) changed — no column, index, constraint, type, or FK was touched.
The parity queries compare column/index/constraint sets, none of which a
moduledoc affects.

### Verification transcript (all run this env, all green)

```
git diff --stat -- priv/test_repo/migrations/   →  1 file, 4 insertions(+), 1 deletion(-)   (moduledoc-only; DDL unchanged)

mix precommit                          →  EXIT 0  (compile 0 warnings, format clean, 3 doctests 600 tests 0 failures)
mix docs                               →  EXIT 0, no warning/could-not/broken-ref lines; doc/host_wiring.html generated
mix hex.build                          →  EXIT 0, allm_pipeline-0.1.0.tar (checksum 4fb4ca11…)

# Both onboarding files ship in the tarball:
tar -xOf allm_pipeline-*.tar contents.tar.gz | tar -tzf - | grep -E 'guides/|priv/test_repo'
    →  guides/host_wiring.md
       priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs
```

Run in the devcontainer with `DATABASE_HOST=<compose-pg-ip>
DATABASE_USER=postgres DATABASE_PASSWORD=postgres` (same environment note as
subphases 1/3). The `.tar` is gitignored; removed after inspection. The
`[error]`/`[warning]` lines in the `mix precommit` output are deliberate
test-fixture log output (borrowed-run refusals, deliberate `:boom` failures),
not compile warnings — the run is 0 failures with `--warnings-as-errors`.
