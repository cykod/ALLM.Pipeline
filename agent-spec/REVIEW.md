# Review Spec — ALLM.Pipeline

Functional review of recent work. Golden rule: a review must **exercise** the
library, not read the diff. A green suite proves the implementer's tests pass; a
review proves a consumer can pick up the public API, call it the documented way,
and get sensible behavior — including on error paths. If you cannot exercise it
(service down, missing fixture), report `BLOCKED:` naming exactly what you need —
never write a "what should happen" walkthrough.

## Execution surfaces

This is a headless library — no UI, no server. The live system is:

- **`iex -S mix` (primary).** Drive every public function the diff touches,
  constructing inputs only through public constructors — never reach into struct
  internals. In `MIX_ENV=test` the test registry wires TestRepo + adapters
  (`CLAUDE.md` §2); `llm:` is deliberately unwired and `LLM.impl/0` raising is
  designed behavior, not a defect.
- **The test suite as harness.** `mix test` from this repo's root; it creates and
  migrates its own DB.
- **Service-backed adapters.** `docker compose up -d` (DynamoDB Local :4028,
  MinIO :4026; `--profile postgres` if no host Postgres). For adapter changes, run
  the real round-trip against the local stack and inspect at least one stored
  artifact against the declared output shape.

## Required steps

- Run the full gate: `mix precommit`, plus `mix dialyzer` when specs changed.
  Capture each command's output verbatim — test counts and excluded-tag counts,
  not one exit code. Read gates by exit code, never by grepping output for "error".
- Record excluded tags every run; flag when a change *should* have toggled one.
  For `Artifacts.Dynamo` changes, run the two-direction pair in `CLAUDE.md` §4 —
  it is the only discriminating observable for the exclusion logic.
- Exercise every public function the change touches; trigger at least one
  documented error path per changed function and confirm the error's SHAPE, not
  just that it errored.
- Round-trip every touched serializable struct (term + JSON). A fun, PID, ref, or
  credential on a data struct is a blocker.
- Re-paste every touched `@doc` example into the live session — doctests run
  automatically, but the manual pass catches stale surrounding prose.
- Idempotency where claimed: re-run and confirm no duplicate rows for stable keys.

## The review doc

Write to `.work/reviews/`. Format: summary → gate stack with output → REPL
sessions, each a fenced block with a 1–2 sentence narration of what it proves (a
block without narration is decoration; narration without a block is unverifiable)
→ doc/design drift → findings tagged Blocker / Finding / Nit with `file:line` and
a proposed fix → sign-off line (APPROVED / APPROVED with findings / BLOCKED).

- Compare the implementation against the design's cited sections; an undocumented
  deviation is a blocker.
- A negative exhaustiveness claim ("nothing else reads it") ships its unscoped
  search inline, or is downgraded to "I checked N and they are clean."
- When a phase has no exercisable surface, write an explicit N/A stub naming the
  test that proves the behavior — an empty review directory is indistinguishable
  from "review never run."
- "No findings" from a review that actually ran the checklist is a result — don't
  manufacture Lows.
