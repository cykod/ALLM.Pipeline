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

## Subphase 2 — Umbrella lockstep seam-key move

**Status: Completed 2026-08-31** — landed host-side from the umbrella checkout
(`~/Projects/amesbury`, working tree at `995b4e3`), the environment the earlier
subphases did not have. Umbrella `mix precommit` exit 0; the fail-closed
dep-compile check green; the deferred subphase-4 schema-parity re-run
discharged in the same sitting (see below).

### Baseline (pre-edit working tree, per the umbrella's baseline rule)

`mix precommit` at `995b4e3` before any edit: **exit 2** — `amesbury` 1075/0,
`amesbury_scraper` 2200 tests / **51 failures** / 31 excluded (with the
`:dynamo` exclusion firing), `amesbury_web` 274 tests / 1 failure. Failure
census: the two `Amesbury.PipelinesTest` namespace assertions, plus 50
artifact-store casualties — with the umbrella's `:dynamo` config unread under
the old namespace, the adapter fell back to **real AWS DynamoDB** with the
test env's dummy credentials (`UnrecognizedClientException` throughout the
log). That is the live blast radius the design predicted; it also means a prod
deploy in the interim state would have silently repointed the artifact table
to C2's new default. Captured: `precommit-baseline.log` (session scratchpad;
figures restated here because the scratchpad dies with the session).

### What changed (16 sites)

- **Config, 12 lines** `config :amesbury_scraper, …` → `config :allm_pipeline, …`:
  `config/config.exs:62` (`:dynamo`), `:116` (`LLMCallLog`);
  `config/dev.exs:80,89`; `config/test.exs:43,51`; `config/eval.exs:27`;
  `config/runtime.exs:51,81` (endpoint overrides), `:449` (prod
  `DYNAMODB_TABLE`), `:461` (prod S3 bucket). Line numbers pre-edit.
- **Code, 3 sites**: `pipelines_test.exs:90` (`:repo` assertion) **and :60 —
  a variable-key read (`get_env(:amesbury_scraper, behaviour, [])`) the
  design's literal-pattern grep structurally could not find** (the
  "zero grep hits prove nothing for non-literal calls" rule; found by
  eyeballing the failing test's describe block); `eval/eval_helper.exs:186`.
- **Prose, 3 sites**: `config/config.exs:52–59` (the "`:amesbury_scraper`
  stays the framework's config namespace through Phase 1" paragraph —
  falsified, rewritten); `lib/amesbury/pipelines.ex:66` comment;
  `apps/amesbury_scraper/CLAUDE.md:275` example config line.
- **What stayed**: every `:amesbury_scraper` line carrying the umbrella's own
  keys (`ecto_repos`, `HttpScraper`, `LLMEngine`, `DocumentExtractionClient`,
  `MapboxGeocoder`, `:opengov`) — 12 `config :amesbury_scraper` lines remain
  in `config/`, and all remaining `get_env(:amesbury_scraper, __MODULE__)`
  reads are own-app modules (verified by eyeball of the filtered grep).
  Deliberate doc survivors: historical steering/`.work` records, and
  `steering/SST_DEPLOYMENT_PLAN.md:875` — a frozen `runtime.exs` sketch that
  already names the retired `LLMClient` module, i.e. historical in character.

### C2 guard (checklist item: every env sets `table_name` explicitly)

Enumerated from the post-edit tree: `config.exs` `"amesbury_artifacts"`,
`dev.exs` `"amesbury_artifacts_dev"`, `test.exs` `"amesbury_artifacts_test"`,
`eval.exs` `"eval_artifacts"`, prod `runtime.exs:449`
`env!("DYNAMODB_TABLE", :string!)`. The package's new default
`"allm_pipeline_artifacts"` never fires in any umbrella environment.

### Environment repair (shared local DynamoDB)

The shared DynamoDB Local on :4028 held only `allm_pipeline_artifacts_test`
(the package-side run's compose restart lost the umbrella's tables — DynamoDB
Local here is ephemeral). Recreated `amesbury_artifacts_test` and
`amesbury_artifacts_dev` via `ALLM.Pipeline.Artifacts.Dynamo.create_table/0`
(`MIX_ENV=test mix run -e …` / dev with `DYNAMODB_ENDPOINT=http://localhost:4028`
— the host shell's `.env` value was a stale OrbStack `*.orb.local` name,
`:nxdomain`, the documented drift; probed before overriding).

### Verification transcript (all run host-side, umbrella root)

```
# Baseline (pre-edit):            mix precommit → exit 2 (52 failures, census above)
# After (post-edit, stack UP):    mix precommit → exit 0
#   amesbury 1075/0 · amesbury_scraper 13 doctests, 2200 tests, 0 failures, 31 excluded
#   (Excluding tags: [:playwright, :live] — the :dynamo exclusion NO LONGER fires,
#    proving the :dynamo config is read through :allm_pipeline) · amesbury_web 274/0

mix deps.compile allm_pipeline --force → exit: 0
grep -c 'Compiling' allm-compile.log   → 1   (positive control, non-zero)
grep -c 'warning:'  allm-compile.log   → 0

grep -rn -E "amesbury_scraper, (ALLM\.Pipeline|:dynamo|:repo|:alert_on_empty|:lock_keys)" \
  config/ apps --include='*.ex' --include='*.exs' | wc -l   → 0
grep -rn 'config :amesbury_scraper' config/ | wc -l          → 12  (positive control — own keys remain)
grep -rc 'config :allm_pipeline' config/*.exs                → config.exs 3, dev 2, test 2, eval 1, runtime 4

grep -c 'but the application is not available' <both logs>   → 0 both directions
# (No positive control exists umbrella-side: the notice was a package-repo
#  phenomenon — :amesbury_scraper is a real app here and :allm_pipeline a
#  loaded dep, so the notice never fired in the umbrella baseline either.)
```

`pipelines_test.exs` + `pipelines_declared_values_test.exs` green (in the
targeted pre-gate run and again inside the full gate).

### Deferred subphase-4 parity re-run — DISCHARGED

`mix test apps/amesbury_scraper/test/amesbury_scraper/pipeline/framework_boundary_guards_test.exs`
→ 0 failures (targeted run, and again inside the full `mix precommit`),
confirming the moduledoc-only migration edit preserved schema parity, as
predicted by construction. The `.work/HANDOFF.md` row is ticked.

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

---

## Subphase 6 — Multi-consumer agent-doc updates

**Status: Completed** (this repo's `mix precommit` exit 0, 3 doctests 600 tests
0 failures — doc-only diff; review gates run and clean — functional-review
APPROVED (all 4 observables pass; reframing verified truthful — no "published"
or plural-consumer claim, all named artifacts exist on disk), code-review
ship-as-is (0 High/Med, 1 cosmetic Low left for polish; the false-governed-doc
hazard verified clean), security-review no-issues (prose-only, no secrets;
steering docs not in the tarball), design-review N/A (doc-only diff)). Artifacts
under `.work/{reviews,code-reviews,security-reviews,design-reviews}/2026-08-31-subphase6-agent-docs*`.
Files touched: `CLAUDE.md`, `README.md`, `agent-spec/DESIGN.md`.
`agent-spec/CODE_REVIEW.md` was NOT touched — see "Deviations" (its §1 namespace
bullet was already brought to current truth in subphase 1, so no subphase-6 edit
was needed there despite the Module-tree listing it).

### ⚠️ KEY RECONCILIATION — the design's subphase-6 wording assumed a publish that has NOT happened

The design's subphase-6 checklist (lines 503–519) was written assuming subphases
2 and 5 had landed: it says to rewrite the `CLAUDE.md` header to "the consumer
**list**" and "that the package is now **published**", and to **retire** the
"Publishing trigger" sentence. **In THIS run none of that is true:**

- **Subphase 5 (v0.1.0 Hex publish) is DEFERRED to the host.** The package is
  publish-*ready* (host-neutral hexdocs, onboarding guide + canonical DDL in the
  tarball, `@version "0.1.0"`) but is **NOT on Hex**.
- **No second consumer exists.** Consumers 2/3 are explicitly out of scope
  (design Overview "Out of scope"); the Amesbury umbrella is still the sole
  consumer.
- **Subphase 2 (umbrella lockstep) is also deferred to the host** — the umbrella
  still reads `:amesbury_scraper` until the user lands it there.

Writing "now published" or a plural "its consumers" into a governed doc would be
a **false statement in a governed document** — the worst error available here. So
every subphase-6 edit was phrased for the **true current state**, not the
publish-assumed one:

- **`CLAUDE.md` header** — did NOT claim published and did NOT pluralize
  consumers. Kept the accurate facts (still **one** consumer, the umbrella, path
  dep) and REFRAMED the "hex-ready but not published" line to state that the
  readiness work (this design) landed — namespace is now the package's own OTP
  app name, hexdocs are host-neutral, the guide + canonical DDL ship in the
  tarball — and that only the publish step (subphase 5) and umbrella lockstep
  (subphase 2) remain, **deferred to the host**. **REFINED** the "Publishing
  trigger" sentence rather than retiring it (it still hasn't published, so the
  trigger still stands); annotated it "(still standing — it has not been
  published)".
- **`README.md` intro** — the design offered "→ consumers-plural once a second
  consumer actually lands (leave a TODO only if this subphase closes before then
  — otherwise phrase it now)". Since NO second consumer landed, did the
  current-reality phrasing: "currently its sole consumer", plus a sentence that
  the framework is host-neutral and onboarding-ready via the host-wiring guide
  (making new consumers possible without asserting they exist), and "not yet
  published". Did NOT pluralize as if consumers 2/3 exist. (No literal `TODO`
  marker left — the current-reality phrasing is self-consistent and needs no
  future-edit flag; the standing publish/second-consumer triggers already live in
  the `CLAUDE.md` header and §8.)

These two are the deviation from the design's literal checklist wording, made
because the design's wording is counterfactual for this run's scope. A
`> CORRECTED:` note was added to the design's subphase-6 section pointing here.

### The publish-independent edits (done normally, matching the design)

- **`CLAUDE.md` §7 corollary** (was "run the census from the Amesbury umbrella
  root") → now "run the census from EVERY consumer repo … each consumer port's
  own obligation, named in that port's design", with the Amesbury `grep` kept as
  the concrete example and "a second consumer runs the equivalent from its own
  tree". Not deferred to any subphase (consumers 2/3 out of scope).
- **`agent-spec/DESIGN.md` "DDL in two places"** (was "the host-side production
  migration (which lives in the Amesbury repo)") → per-consumer phrasing that
  names the canonical DDL file
  `priv/test_repo/migrations/00000000000001_create_pipeline_tables.exs` (shipped
  in the tarball per subphase 4) as the source of truth each consumer copies into
  its own repo and freezes.

### Deviations

- **`agent-spec/CODE_REVIEW.md` not edited** — the Module tree lists it under
  "MODIFY — subphase 6", but its only namespace-sensitive line (§1 bullet, line
  41) was already retargeted to current truth in **subphase 1** (see subphase-1
  RECORDS: "`agent-spec/CODE_REVIEW.md:41` … retargeted … to the
  not-centralized-into-an-accessor decision"). It reads `:allm_pipeline` today
  and states no one-consumer/published claim, so there was nothing left for
  subphase 6 to fix. No edit rather than a no-op edit.

### Grep survivor list — `amesbury_scraper` in the governed docs

The verification grep
`grep -n 'amesbury_scraper' CLAUDE.md README.md agent-spec/*.md | grep -v 'was\|history\|formerly'`
returns **3** survivors, all in `CLAUDE.md`, all **deliberate concrete
host-file-path pointers** — NOT false config-namespace claims. `CLAUDE.md` is not
hexdocs; it legitimately names the concrete host (build prompt: "those are NOT
the target"). They stay:

| Line | Text | Why it stays |
|---|---|---|
| 32 | `apps/amesbury_scraper/CLAUDE.md` §1 (where the framework's behaviour is documented consumer-side) | concrete host doc path, a correct pointer |
| 59 | `apps/amesbury_scraper/test/amesbury_scraper/pipeline/step_schema_census_test.exs` | concrete host-twin test path (the §1 "Host-twin guards" note) |
| 249 | `apps/amesbury_scraper/test/amesbury/pipelines_declared_values_test.exs` | concrete host-owned-values test path (§5) |

None asserts the `:amesbury_scraper` *config namespace* (that assertion was the
target, and subphase 1 removed it from `lib/`/`config/`). No survivors in
`README.md` or `agent-spec/*.md`.

### Verification transcript (all run this env, all green)

```
grep -n 'amesbury_scraper' CLAUDE.md README.md agent-spec/*.md | grep -v 'was\|history\|formerly' | wc -l
    →  3   (all deliberate host-file-path pointers — table above)

DATABASE_HOST=<compose-pg-ip> DATABASE_USER=postgres DATABASE_PASSWORD=postgres mix precommit
    →  EXIT 0   (compile 0 warnings, format clean, 3 doctests 600 tests 0 failures)
```

Run in the devcontainer with the compose Postgres container IP for `DATABASE_HOST`
(same environment note as subphases 1/3/4 — `host.docker.internal:5432` lacks the
`postgres` role; the compose Postgres is reached by its network IP). Docs-only
diff, so no two-direction dynamo pair re-run was needed (§4 is not touched by this
subphase). Review gates (code/security/design) not yet run — status is "Built,
gates pending" accordingly; security/design are N/A per the design's Overview
(no runtime/frontend change), code-review applies only weakly (docs-only, no
`lib/` diff).
