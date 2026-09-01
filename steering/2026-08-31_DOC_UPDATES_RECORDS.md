# DOC_UPDATES — Records (deviations, closure ledger, verification transcripts)

Companion to `steering/2026-08-31_DOC_UPDATES.md`. Per-subphase records live here;
the design doc's Status table and checkboxes are the orchestrator's to tick.

---

## Subphase 1 — Agent-spec rule + verification harness

**Status: Completed.** (Code review: ship as-is, 1 Medium F1 closed via reciprocal
cross-references; security: no issues; functional/design: N/A. Gates green.)

### Files created / modified

**NEW**
- `agent-spec/DOCS.md` — the durable rule: C1 decision table (verbatim), C2 grep
  recipe (HARD + positive control + soft advisory), C3 zero-warning invariant +
  the ExDoc "resolvable module / unresolvable member" note, and the "What the
  grep can't see" review-lane obligation. States the rule once (not duplicated
  into CLAUDE.md).
- `steering/2026-08-31_DOC_UPDATES_RECORDS.md` — this file.

**MODIFY**
- `scripts/release.exs`:
  - Added `@hexdocs_history_pattern` module attribute (near the other attrs,
    ~:113) — an Elixir `~r/.../` sigil mirroring the C2 `HARD` literal byte-for-byte.
  - Added `defp hexdocs_history_warning/0` (after `migration_touch_warning/1`,
    step-6c region). Runs `System.cmd("mix", ["docs"], stderr_to_stdout: true)`
    — the script's FIRST `mix docs` run (verified: none existed) — then greps the
    regenerated `doc/*.md` (excluding `changelog.md`) for the pattern in-process
    (`Path.wildcard` + `Regex.match?`, not shelling to `grep`, to avoid the
    `[`/`(`/`|`/`/` shell-escaping trap). On a hit it WARNs through the same
    `IO.puts(:stderr, ...)` advisory channel as the `Excluding tags` /
    migration-touch warnings, with the count and the text "hexdocs still contain
    development-history references — see agent-spec/DOCS.md", then lists the
    `file:line: line` hits. Never aborts.
  - Wired the call as `log_step("step 6c", ...)` beside `migration_touch_warning`
    (~:256).
- `CLAUDE.md` — one pointer line after the intro block: "Published hexdocs are
  present-tense and history-free — see `agent-spec/DOCS.md`." (Rule not restated;
  CLAUDE.md keeps its own phase history.)
- `agent-spec/CODE_REVIEW.md` — one review-lane bullet under Heuristics
  ("Published-doc history"): flag category-A/B/C patterns in touched
  `@moduledoc`/`@doc`, cite `agent-spec/DOCS.md`.

**CONFIRMED, no edit** — `mix.exs` hex `package` `files:` already ships `guides`
wholesale (`mix.exs:63` → `~w(lib guides priv/test_repo/migrations …)`). Subphase
4's new guide reaches the tarball with no `files:` change.

### Deviations

- **D1 — In-process grep instead of shelling to `grep`.** The design says the
  guard "greps `doc/*.md`". Implemented with `Path.wildcard/1` + `Regex.match?/2`
  rather than `System.cmd("grep", …)`. Reason: the `HARD` pattern contains `[`,
  `(`, `|`, `/` — shell-quoting it correctly through `System.cmd` argv is a trap,
  and an in-process regex is the same pattern with no escaping surface. The
  pattern literal is kept byte-for-byte in step with `agent-spec/DOCS.md` C2 (a
  header comment on `@hexdocs_history_pattern` says so). Behaviour is identical:
  WARN-not-abort, `--exclude=changelog.md` semantics preserved by
  `Enum.reject(basename == "changelog.md")`.

### Verification transcripts (run 2026-09-01, pre-sweep tree)

`mix docs` regenerates the gitignored `doc/`; greps run against that fresh output.

```
mix docs >/dev/null                                  # exit 0
grep -rIlE "$HARD" doc/*.md | wc -l          -> 33   # >0: hard pattern fires (control)
grep -rIl 'Pipeline' doc/*.md | head -1      -> doc/ALLM.Pipeline.Artifacts.Tiered.md   # non-empty (positive control)
grep -rInE 'umbrella' doc/*.md | wc -l       -> 29   # >0: soft advisory fires (control)
grep -rlE "$HARD" --exclude=changelog.md doc/*.md | wc -l  -> 32   # release-guard scope: >0 today
```

Release guard's exact Elixir logic (`@hexdocs_history_pattern` +
`Path.wildcard`/`Regex`), run standalone against the regenerated docs:

```
hit lines: 174        # guard fires; sample:
  doc/ALLM.Pipeline.ArtifactStore.md:33: ## Tiering is an adapter choice (Phase 7)
  doc/ALLM.Pipeline.ArtifactStore.md:35: This module no longer routes by size ...
  doc/ALLM.Pipeline.Executor.build_envelope/3 no longer truncates ...
```

So `hexdocs_history_warning/0` fires on today's (pre-sweep) tree and WARNs — its
positive control. It will go silent after subphases 2–3 drive the hard grep to
zero.

`scripts/release.exs` parses/compiles clean (`elixir -e 'Code.compile_file(...)'`
— the module fully evaluated before `main` hit the expected arg-parse
`System.halt(1)`; the `~r` sigil is valid).

### `mix precommit`

Green. Environment: run from inside the devcontainer, so per CLAUDE.md §2 the
host Postgres was reached with `DATABASE_HOST=host.docker.internal
DATABASE_USER=pascalrettig` (the default `postgres` role does not exist on the
host DB — a bare `mix precommit` fails with `role "postgres" does not exist`).

```
DATABASE_HOST=host.docker.internal DATABASE_USER=pascalrettig mix precommit
  ...
  3 doctests, 600 tests, 0 failures        # no "Excluding tags" line — :dynamo set ran
  PLT is up to date! ... Total errors: 0   # dialyzer clean
  precommit exit: 0
```

The `[error] Refusing to … pipeline run …` log lines during `store_test` are the
designed ownership-refusal log noise, not failures (0 failures).

`mix dialyzer` was exercised (it is in `precommit` since 2026-08-31) and passed;
no `@spec` was touched — spec/script/doc edits only.
