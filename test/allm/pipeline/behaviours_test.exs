defmodule ALLM.Pipeline.BehavioursTest do
  @moduledoc """
  The membership guard for the package's three seams — `Store`, `Artifacts` and
  `Lock` — and their adapters.

  ## Why one file rather than three per-behaviour checks

  The three behaviours enforce the same two rules in three structurally
  identical shapes: *an adapter declares `@behaviour` and implements every
  mandatory callback*, and *the behaviour resolves its implementation at
  runtime through an `impl/0` that defaults to a shipped adapter*. Root
  `CLAUDE.md`'s rule for a rule enforced in more than one shape is to pin the
  SET rather than test the instances — so `@seams` below is the set.

  `@behaviour` alone is not sufficient enforcement: the compiler warns on a
  missing callback, but a module that simply never declares `@behaviour` is
  invisible to it, and so is an adapter dropped from a wrapper's dispatch. Both
  are what this asserts.

  ## How the SET stays honest, and what it can and cannot see

  `@seams` is a hand-written literal, so on its own it pins the *conformance*
  of a list rather than its *membership* — a Phase 7 `Artifacts.S3` added
  without joining it would fail nothing. The "the SET is discovered, not
  declared" describe below closes that: it enumerates
  `Application.spec(:allm_pipeline, :modules)` and fails when a module in the
  package declares a seam `@behaviour` without joining `@seams`, or declares a
  behaviour of its own that is neither a seam nor an acknowledged non-seam
  (`@not_seams`).

  Its scope is **modules inside `:allm_pipeline`**, which is the right scope for
  a package guard but narrower than "the SET" alone implies: a host-side adapter
  living in `apps/amesbury_scraper` is invisible to it. If one ever ships, this
  guard must grow a second application to walk.

  `Store.Memory` is deliberately absent from the store's adapter list and is
  **not planned in any phase** — the lineage tree is a recursive CTE with no
  ETS equivalent (extraction plan §3.2).

  **Not `async: true`** — the runtime-resolution test rewrites
  `:amesbury_scraper` application env, which is global to the VM.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.{Artifacts, Lock, Store}

  # {behaviour, adapters, default impl}
  @seams [
    {Store, [Store.Ecto], Store.Ecto},
    {Artifacts, [Artifacts.Dynamo, Artifacts.Filesystem, Artifacts.Memory], Artifacts.Dynamo},
    {Lock, [Lock.Advisory, Lock.Noop], Lock.Noop}
  ]

  # Behaviours in this package that are deliberately NOT adapter seams, so the
  # discovery guard below can tell "a fourth seam landed and nobody registered
  # it" from "a behaviour exists that was never meant to be one". `Step` is the
  # unit-of-work contract every pipeline step implements — dozens of
  # implementations, no `impl/0`, no swappable default. Adding to this list is
  # a decision; that is the point of having to make it.
  @not_seams [ALLM.Pipeline.Step]

  describe "every seam" do
    test "declares at least one mandatory callback" do
      for {behaviour, _adapters, _default} <- @seams do
        Code.ensure_loaded!(behaviour)

        mandatory =
          behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks)

        assert mandatory != [],
               "#{inspect(behaviour)} declares no mandatory callbacks — a behaviour whose " <>
                 "whole contract is optional enforces nothing"
      end
    end

    test "has every adapter declare @behaviour and implement every mandatory callback" do
      for {behaviour, adapters, _default} <- @seams, adapter <- adapters do
        declared = declared_behaviours(adapter)

        assert behaviour in declared,
               "#{inspect(adapter)} does not declare @behaviour #{inspect(behaviour)} — the " <>
                 "compiler cannot check a callback it was never told about"

        mandatory =
          behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks)

        for {fun, arity} <- mandatory do
          assert function_exported?(adapter, fun, arity),
                 "#{inspect(adapter)} does not implement #{fun}/#{arity}"
        end
      end
    end

    test "resolves its implementation at runtime, defaulting to a shipped adapter" do
      for {behaviour, adapters, default} <- @seams do
        original = Application.get_env(:amesbury_scraper, behaviour)

        try do
          Application.delete_env(:amesbury_scraper, behaviour)

          assert behaviour.impl() == default,
                 "#{inspect(behaviour)}.impl/0 does not default to #{inspect(default)}"

          assert default in adapters

          # Runtime, not compile time: two successive reads must both take
          # effect. A module attribute would return the first value twice.
          for adapter <- adapters do
            Application.put_env(:amesbury_scraper, behaviour, impl: adapter)
            assert behaviour.impl() == adapter
          end
        after
          case original do
            nil -> Application.delete_env(:amesbury_scraper, behaviour)
            value -> Application.put_env(:amesbury_scraper, behaviour, value)
          end
        end
      end
    end
  end

  describe "the SET is discovered, not declared" do
    # Without these two, `@seams` pins only the CONFORMANCE of a hand-written
    # list: a Phase 7 `Artifacts.S3` (or a fourth behaviour) added without
    # joining it fails nothing, which is exactly the shape root `CLAUDE.md`'s
    # "a rule enforced in more than one shape needs a membership guard" warns
    # about. `Application.spec/2` enumerates every module the package ships, so
    # the population is derived rather than remembered.

    test "every module in the package declaring a seam @behaviour is listed in @seams" do
      seam_behaviours = Enum.map(@seams, fn {behaviour, _adapters, _default} -> behaviour end)

      discovered =
        for module <- package_modules(),
            behaviour <- declared_behaviours(module),
            behaviour in seam_behaviours,
            do: {behaviour, module}

      listed = for {behaviour, adapters, _default} <- @seams, a <- adapters, do: {behaviour, a}

      assert Enum.sort(discovered) == Enum.sort(listed),
             "a module in apps/allm_pipeline declares a seam @behaviour without joining @seams " <>
               "(or @seams lists an adapter that no longer declares one)"
    end

    test "every behaviour the package defines is either a seam or an acknowledged non-seam" do
      seam_behaviours = Enum.map(@seams, fn {behaviour, _adapters, _default} -> behaviour end)

      discovered = Enum.filter(package_modules(), &behaviour?/1)

      # A floor, so a broken enumeration cannot pass by returning nothing —
      # `assert offenders == []` over an empty population is the fail-open shape.
      assert length(discovered) >= length(seam_behaviours) + length(@not_seams)

      assert Enum.sort(discovered) == Enum.sort(seam_behaviours ++ @not_seams),
             "a behaviour was added to apps/allm_pipeline without joining @seams or @not_seams — " <>
               "decide which it is rather than letting it default to unguarded"
    end
  end

  defp package_modules do
    modules = Application.spec(:allm_pipeline, :modules)

    # `nil` if the application is not loaded, in which case both assertions
    # above would vacuously pass over an empty list.
    assert is_list(modules) and modules != [],
           "Application.spec(:allm_pipeline, :modules) returned #{inspect(modules)} — the " <>
             "guard cannot enumerate the package and would pass vacuously"

    modules
  end

  defp behaviour?(module) do
    Code.ensure_loaded!(module)
    function_exported?(module, :behaviour_info, 1)
  end

  # `module_info(:attributes)` is a keyword list with one `:behaviour` entry PER
  # declaration, and duplicate keys are legal there — so `attributes[:behaviour]`
  # returns only the FIRST and silently hides every later one. Measured
  # 2026-08-14 on a module carrying two: `[behaviour: [Lock], behaviour:
  # [Artifacts]]`, Access lookup → `[Lock]`. A mutant adding a second
  # declaration survived the discovery guard because of exactly this. Collect
  # them all.
  defp declared_behaviours(module) do
    Code.ensure_loaded!(module)

    for {:behaviour, behaviours} <- module.module_info(:attributes),
        behaviour <- behaviours,
        do: behaviour
  end

  describe "the seams stay disjoint" do
    test "no adapter serves two behaviours" do
      all = Enum.flat_map(@seams, fn {_b, adapters, _d} -> adapters end)

      assert all == Enum.uniq(all)
    end

    test "no seam's callbacks name another seam's concern" do
      # §5.3 scopes each behaviour narrowly, and the scope is what makes
      # `ALLM.Pipeline.Config.repo/0` a package-level handle rather than
      # something `Store` absorbs. A `repo` callback on ANY of the three would
      # quietly create a second resolution path for the repo.
      for {behaviour, _adapters, _default} <- @seams do
        names = behaviour.behaviour_info(:callbacks) |> Enum.map(&elem(&1, 0))

        refute :repo in names,
               "#{inspect(behaviour)} declares a repo callback — the package resolves the repo " <>
                 "in exactly one place, ALLM.Pipeline.Config.repo/0"
      end
    end
  end
end
