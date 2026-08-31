# Implementation Spec — ALLM.Pipeline

Read `CLAUDE.md` first — it owns the repo-specific rules (dep-list boundary, test
harness, `:dynamo` exclusion, application-env discipline, DSL internals, release).
This spec is the build workflow plus the stack lessons CLAUDE.md doesn't carry.

## Workflow

- The design doc is the source of truth. Read the WHOLE design before writing code;
  implement subphases in order — build order is load-bearing.
- **Start green**: `mix precommit` (and `mix dialyzer` if the phase touches specs)
  must pass before any code. A pre-existing failure blocks the phase — stop and ask.
  Baseline repair is a separate, user-authorized `chore:` commit, minimum touch.
- Per subphase: mark its status row `In Progress` → write the Test Plan tests first
  and watch them fail *for the right reason* → minimum implementation → focused
  tests green → full suite green → gates → tick the design's checkboxes → mark
  `Complete` → one-line Implementation Note per deviation → commit citing the
  design section. Never leave a subphase `In Progress` at commit.
- The Test Plan is a coverage floor AND the scope contract: invariants named in the
  contracts section but missing from the plan are tests you must add; branches and
  options the plan doesn't test are out of scope.
- Stop and ask when: the design is ambiguous or has multiple valid implementations,
  conflicts with existing code, specs `{:error, term()}`, or names a test target
  that can't exist yet. Structural inference (struct field changes, `@enforce_keys`,
  new fallback clauses) needs a design amendment; tactical inference (naming, idiom)
  gets logged and moved past.
- After all subphases: a final summary — files created/modified (exact paths),
  deviations and why, public-API additions (one CHANGELOG line each), test-count
  delta, and a manual `iex -S mix` verification recipe.
- On a *resumed* build, the status table is a claim to verify against the tree and
  the gate, not to trust.

## Project bindings

```bash
mix precommit        # compile --warnings-as-errors + format + test --warnings-as-errors
mix test             # creates + migrates allm_pipeline_test itself (see CLAUDE.md §2)
mix dialyzer         # NOT in precommit; run whenever a @spec'd function changes
docker compose up -d # DynamoDB Local :4028 + MinIO :4026 (--profile postgres for DB)
```

Toolchain pin: `.tool-versions` (erlang 27.1.2 / elixir 1.17.3-otp-27). The suite
runs on the host, standalone. The umbrella-side fail-closed warning check and the
two-direction `:dynamo` run are specified in `CLAUDE.md` §2/§4 — run them when a
change touches compile output or `Artifacts.Dynamo`.

## Mutation testing

Follow `~/.claude/skills/_shared/mutation-testing.md` (§Station 2 for implementers).
Project bindings: test command `mix test`; never run `mix format` or the precommit
alias mid-mutation-pass (formatting rewrites the mutated file and invalidates the
bracketing digests). At least one mutant per pass walks the diff's own decision
points, not the design's test list.

## Stack lessons

- Every public function gets `@spec`; never widen a spec to silence dialyzer — fix
  the implementation. Never spec `{:error, term()}`.
- A doctest only runs if some test file says `doctest <Module>` — the gate does not
  check this; orphaned doctests pass green forever. Confirm the directive.
- `--warnings-as-errors` catches unused `def` but NOT unused `defp` aliases/imports
  left behind by a move — re-grep the module after rewriting and delete in the same
  commit. A stale incremental compile can hide a real warning: confirm risky batches
  with `mix compile --force --warnings-as-errors`.
- An empty-output exit-0 `mix test path/...` means "matched zero files", not passed.
- `mix format` only reaches `.formatter.exs` inputs; inspect the diff for unrelated
  reformat churn and split it out.
- Under OTP 27+, a literal `0.0` pattern matches only `+0.0` and warns — use a
  `when x == 0.0` guard.
- Reference optional deps (`ex_aws*`) via `Code.ensure_loaded?/1`-guarded runtime
  resolution; a direct reference trips `--warnings-as-errors` when the dep is absent.
  The core must compile and test with the optional deps absent.
- Ban `if Mix.env() == :test` in `lib/`; test-only code lives in `test/support/`.
- A `defp` inside a `__using__/1` `quote` expands into every consuming module and
  collides there — use `@doc false def` on the macro module, invoked via
  `unquote(__MODULE__).fun(...)`. Helpers pushed OUT of a quote must take plain
  data; anything naming a package module stays inside (consumer compile order).
- Tests that mutate VM-global state (application env, named processes, telemetry
  handlers, `:persistent_term`) are `async: false` and snapshot/restore the whole
  key — the shapes and the carve-out rule are `CLAUDE.md` §5.
- Pin the RAW application env, never the resolved value — the resolved value agrees
  with the default whether or not anything ran. A seam whose only configured value
  is its own default is untested: assert fallback-with-key-deleted, a non-default
  module configured, and a dispatch only that fixture satisfies.
- A test that passed on its first run has not been tested — record the red first.
- ExUnit stops at the first failing assertion, so later conjuncts of a conjunctive
  test are vacuously true — split them.
