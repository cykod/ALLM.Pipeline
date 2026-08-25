defmodule ALLM.Pipeline.TestSupport.LibScan do
  @moduledoc """
  Shared scaffold for the package's `lib/`-scanning membership guards —
  `encodable_test.exs` ("normalizer uniqueness"), `executor_test.exs`
  ("borrowed-run funnel") and `fan_out_test.exs` ("fan-out site census").

  Extracted in Phase 8.4 (8.1 code review F3, Rule of 3): the glob + fail-open
  floor scaffold was verbatim in all three tests. The floor is the load-bearing
  half — a grep guard whose success signal is "found nothing" fails OPEN, so
  the glob must be asserted to have matched a plausible tree before an empty
  offender list is trusted (the Amesbury repo's root `CLAUDE.md`: "whenever a
  procedure's success signal is 'nothing changed', add a step confirming
  something did"). The host twins of these guards share the same shape via
  their own `scraper_lib_files!/0` helper in
  `AmesburyScraper.Pipeline.FrameworkBoundaryGuardsTest` (Amesbury repo).
  """

  import ExUnit.Assertions

  # Deliberately slack: well under the live count (40 on 2026-08-25 —
  # `find lib -name '*.ex' | wc -l`, the command to re-derive rather than trust
  # the integer), so ordinary file growth/removal doesn't trip it; only a tree
  # that MOVED does.
  @floor 10

  @doc """
  This repo's root, resolved from this file's location. For turning absolute
  scan paths back into repo-relative ones (`Path.relative_to(path, root())`).
  """
  @spec root() :: Path.t()
  def root, do: Path.expand(Path.join([__DIR__, "..", ".."]))

  @doc """
  Every `.ex` file under this repo's `lib/`, floor-asserted (> #{@floor} files)
  so a moved tree fails loudly instead of letting the caller's filter pass
  vacuously over an empty list.
  """
  @spec lib_files!() :: [Path.t()]
  def lib_files! do
    lib = Path.join(root(), "lib")
    matched = lib |> Path.join("**/*.ex") |> Path.wildcard()

    assert length(matched) > @floor,
           "the guard glob matched only #{length(matched)} files under #{lib} — " <>
             "the tree moved and this test is no longer scanning it. Re-point the guard."

    matched
  end
end
