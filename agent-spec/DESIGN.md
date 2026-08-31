# Design Spec — ALLM.Pipeline

Conventions for design docs in this repo. Designs land in `steering/` as
`YYYY-MM-DD_<DESCRIPTIVE_NAME>.md`; subphases are numbered under their parent
(`3A.1`). A design REFINES the architecture/phasing doc into subphases — cite
section numbers, never restate prose (restating creates two sources of truth).

## Structure

1. **Header**: goal, measurable outcome, spec sections covered, layers touched.
2. **Status table**: one row per subphase (`Not Started / In Progress / Complete /
   Deferred`) plus an `Overall Progress: N/M` line, updated at every transition.
3. **Overview**: deliverables; out-of-scope items each with a one-line
   justification (a missing item reads as oversight, a stated exclusion as
   intent); non-obvious decisions with rationale; which review lanes apply and
   what triggers the N/A ones.
4. **Behaviour & type contracts**, before any subphase: struct shapes with field
   types and defaults, full `@type`s including closed-union members, `@spec`s with
   the complete error shape — never `{:error, term()}` — as copy-pasteable code.
   State each load-bearing value ONCE; checklists reference the contract block.
5. **Module tree**: every file `(NEW — N.M)` / `(MODIFY — N.M, rationale)`, test
   files included, 1:1 with source files. `ls` the parent directory of every NEW
   path before locking it in.
6. **Per subphase**: one concern, independently shippable (gate green, no
   half-defined public API); a Test Plan FIRST; 4–8 checkboxes; a Verification
   block of exact commands, uniform across subphases (`mix precommit`, plus
   `mix dialyzer` when specs change).
7. **Definition of Done**: all rows Complete; full gate green; `@spec` + doc on
   every new public function; round-trip test per serializable struct; CHANGELOG
   line per public-API change; both review lanes run.

## What a design must specify for this stack

- **Seam wiring.** Any new host collaborator resolves through the Registry at
  runtime (`CLAUDE.md` §1/§6) — the design names the seam key, the default (or
  the deliberate absence of one), and the conformance stubs. A new mandatory
  `@callback` lists EVERY in-tree implementer to stub, test doubles included
  (`CLAUDE.md` §1).
- **DDL in two places.** Schema changes name both the `priv/test_repo/migrations/`
  harness DDL and the host-side production migration (which lives in the Amesbury
  repo), plus the schema-parity re-run. Table names are contract.
- **Error contract table** (function × reason atom × recovery) for validator-shaped
  modules — exhaustive, so the implementer never invents an atom.
- **Consumer census.** Production declarations live in the CONSUMER's repo; a new
  DSL option's design records whether a production declaration will exist, per the
  corollary in `CLAUDE.md` §7 — four constructs shipped green here with zero
  consumers.

## Evidence discipline

- Test-observable claims are verified, not recalled: every concrete runtime fact
  (the exception raised, the atoms accepted, a return shape) carries a `file:line`
  cite landing on a `def`/`field`/`@spec` — not prose — or a
  "(verified in iex on <date>)" annotation. Memory is not a citation. Hedge words
  (`should raise`, `roughly`, `or the equivalent`) are trip-wires — grep for them
  before freezing.
- Comparative claims quote, not cite: "mirrors X" inlines the two or three
  relevant lines — and is also a duplication smell; consider naming a shared owner.
- Execute every command a criteria list contains, at design time, and paste its
  output beside it. Carry the command that RE-DERIVES a number, never the number.
- Anchor grep-count criteria to a structural form (declaration, import, call),
  never a bare substring the design's own prose will match; every emptiness-is-
  success check ships a positive control pasted beside it.
- Pre-decide binary scope decisions ("investigate and either fix or document") —
  don't outsource them to the implementer. Code sketches are starting points, not
  contracts: mark them as such.
- A deferral is a two-sided edit: it must name a receiving subphase whose
  checklist actually contains the item — verify by grepping the receiver.
