defmodule ALLM.Pipeline.BehavioursTest do
  @moduledoc """
  The membership guard for the package's seams — `Store`, `Artifacts` and
  `Lock`, which ship package adapters, plus the host seam `LLM`, which by
  design does not — and their adapters.

  ## Why one file rather than three per-behaviour checks

  The adapter behaviours enforce the same two rules in structurally identical
  shapes: *an adapter declares `@behaviour` and implements every
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
  living in a consumer repo (Amesbury's `apps/amesbury_scraper`) is invisible to it. If one ever ships, this
  guard must grow a second application to walk.

  `Store.Memory` is deliberately absent from the store's adapter list and is
  **not planned in any phase** — the lineage tree is a recursive CTE with no
  ETS equivalent (extraction plan §3.2).

  **Not `async: true`** — the runtime-resolution test rewrites
  `:allm_pipeline` application env, which is global to the VM.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.{Artifacts, LLM, Lock, Store}

  # {behaviour, adapters, default impl}
  @seams [
    {Store, [Store.Ecto], Store.Ecto},
    {Artifacts,
     [Artifacts.Dynamo, Artifacts.Filesystem, Artifacts.Memory, Artifacts.S3, Artifacts.Tiered],
     Artifacts.Dynamo},
    {Lock, [Lock.Advisory, Lock.Noop], Lock.Noop}
  ]

  # Seams whose implementation is necessarily HOST-side, so the package ships no
  # adapter and `impl/0` has nothing to default to. They are seams in every other
  # respect — a behaviour, a runtime `impl/0`, a registry key — and they are kept
  # apart from `@seams` only because the "defaults to a shipped adapter"
  # assertion below is exactly what must NOT hold for them: an LLM adapter is a
  # provider integration with credentials, a retry policy and logging, none of
  # which the package can supply, and a silently-neutral default would let a step
  # report success having called no model.
  #
  # Their conformance is asserted on the HOST side, where the adapter lives
  # (Amesbury repo: `apps/amesbury_scraper/test/amesbury_scraper/pipelines/llm_test.exs`). This
  # file's scope is modules inside `:allm_pipeline`, which is why it can see the
  # behaviour and not its only implementation.
  @host_seams [LLM]

  # Behaviours in this package that are deliberately NOT adapter seams, so the
  # discovery guard below can tell "another seam landed and nobody registered
  # it" from "a behaviour exists that was never meant to be one". `Step` is the
  # unit-of-work contract every pipeline step implements — dozens of
  # implementations, no `impl/0`, no swappable default. Adding to this list is
  # a decision; that is the point of having to make it.
  @not_seams [ALLM.Pipeline.Step]

  describe "every seam" do
    test "declares at least one mandatory callback" do
      for behaviour <- Enum.map(@seams, &elem(&1, 0)) ++ @host_seams do
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
        original = Application.get_env(:allm_pipeline, behaviour)

        try do
          Application.delete_env(:allm_pipeline, behaviour)

          assert behaviour.impl() == default,
                 "#{inspect(behaviour)}.impl/0 does not default to #{inspect(default)}"

          assert default in adapters

          # Runtime, not compile time: two successive reads must both take
          # effect. A module attribute would return the first value twice.
          for adapter <- adapters do
            Application.put_env(:allm_pipeline, behaviour, impl: adapter)
            assert behaviour.impl() == adapter
          end
        after
          case original do
            nil -> Application.delete_env(:allm_pipeline, behaviour)
            value -> Application.put_env(:allm_pipeline, behaviour, value)
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
      # Host seams join the LEFT side with no adapters on the right, so a package
      # module that declared `@behaviour ALLM.Pipeline.LLM` — i.e. a package LLM
      # adapter, the thing `@host_seams` says does not exist — fails here.
      seam_behaviours =
        Enum.map(@seams, fn {behaviour, _adapters, _default} -> behaviour end) ++ @host_seams

      discovered =
        for module <- package_modules(),
            behaviour <- declared_behaviours(module),
            behaviour in seam_behaviours,
            do: {behaviour, module}

      listed = for {behaviour, adapters, _default} <- @seams, a <- adapters, do: {behaviour, a}

      assert Enum.sort(discovered) == Enum.sort(listed),
             "a module in this package declares a seam @behaviour without joining @seams " <>
               "(or @seams lists an adapter that no longer declares one)"
    end

    test "every behaviour the package defines is either a seam or an acknowledged non-seam" do
      registered =
        Enum.map(@seams, fn {behaviour, _adapters, _default} -> behaviour end) ++
          @host_seams ++ @not_seams

      discovered = Enum.filter(package_modules(), &behaviour?/1)

      # A floor, so a broken enumeration cannot pass by returning nothing —
      # `assert offenders == []` over an empty population is the fail-open shape.
      assert length(discovered) >= length(registered)

      assert Enum.sort(discovered) == Enum.sort(registered),
             "a behaviour was added to this package without joining @seams, @host_seams " <>
               "or @not_seams — decide which it is rather than letting it default to unguarded"
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

  describe "a host seam has no package default" do
    # The inverse of "resolves its implementation at runtime, defaulting to a
    # shipped adapter". Both halves matter: unwired must RAISE (a neutral
    # default would let a step report success having called no model), and a
    # wired one must resolve at runtime rather than at compile time.
    #
    # A host registry (or config) may have installed a real `llm:` in this VM,
    # so the unwired half is only observable by deleting the key and restoring
    # it — this repo's `CLAUDE.md` §5.
    test "impl/0 raises when the host declared none, and resolves one when it did" do
      for behaviour <- @host_seams do
        original = Application.get_env(:allm_pipeline, behaviour)

        try do
          Application.delete_env(:allm_pipeline, behaviour)

          message = assert_raise(RuntimeError, fn -> behaviour.impl() end).message

          assert message =~ "llm:",
                 "#{inspect(behaviour)}.impl/0 raised without naming the registry key that " <>
                   "fixes it — the message IS the remedy"

          for adapter <- [HostSeam.First, HostSeam.Second] do
            Application.put_env(:allm_pipeline, behaviour, impl: adapter)
            assert behaviour.impl() == adapter
          end
        after
          case original do
            nil -> Application.delete_env(:allm_pipeline, behaviour)
            value -> Application.put_env(:allm_pipeline, behaviour, value)
          end
        end
      end
    end

    test "a non-module impl raises rather than reaching a call site" do
      for behaviour <- @host_seams do
        original = Application.get_env(:allm_pipeline, behaviour)

        try do
          Application.put_env(:allm_pipeline, behaviour, impl: "MyApp.Pipelines.LLM")

          assert assert_raise(RuntimeError, fn -> behaviour.impl() end).message =~
                   "must be a module"
        after
          case original do
            nil -> Application.delete_env(:allm_pipeline, behaviour)
            value -> Application.put_env(:allm_pipeline, behaviour, value)
          end
        end
      end
    end
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
      for behaviour <- Enum.map(@seams, &elem(&1, 0)) ++ @host_seams do
        names = behaviour.behaviour_info(:callbacks) |> Enum.map(&elem(&1, 0))

        refute :repo in names,
               "#{inspect(behaviour)} declares a repo callback — the package resolves the repo " <>
                 "in exactly one place, ALLM.Pipeline.Config.repo/0"
      end
    end

    test "exactly one module in the package exposes a repo accessor" do
      # The guard above covers the three BEHAVIOURS by callback name. Batch 1.C
      # added `ALLM.Pipeline.Registry`, which is neither a behaviour nor an
      # adapter and so is invisible to it — and a generated `repo/0` on a host
      # registry is precisely the second resolution path 1.B's option-(b)
      # decision exists to prevent. This walks the whole package instead, so a
      # future module of any shape is covered without widening a list.
      #
      # Scope, and its boundary: modules inside `:allm_pipeline` only. A
      # host-side registry lives in the consumer app and is invisible here —
      # `ALLM.Pipeline.RegistryTest`'s "it generates no accessor for anything
      # it installs" pins the GENERATED shape (which is what a host gets), and
      # `Amesbury.PipelinesTest` pins the live host module.
      exposing =
        for module <- package_modules(),
            function_exported?(module, :repo, 0),
            do: module

      assert exposing == [ALLM.Pipeline.Config],
             "the package resolves the repo in exactly one place, " <>
               "ALLM.Pipeline.Config.repo/0 — found: #{inspect(exposing)}"
    end
  end
end
