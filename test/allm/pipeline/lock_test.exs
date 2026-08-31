defmodule ALLM.Pipeline.LockTest.FixtureLock do
  @moduledoc """
  A `Lock` adapter that exists only to be OBSERVED. `Lock.with_lock/2` reaching
  it is the only way this return value can appear, so it discriminates "dispatch
  is live" from "`with_lock/2` happens to behave like `Noop`" — which the three
  pass-through assertions below cannot, since `Noop` also returns `fun.()`.
  Defined as a sibling top-level module (the `PipelineRunTest.FixtureStep`
  precedent), never nested.
  """
  @behaviour ALLM.Pipeline.Lock

  @impl true
  @spec with_lock(ALLM.Pipeline.Lock.name(), (-> any())) :: {:dispatched_to_fixture, atom()}
  def with_lock(name, _fun), do: {:dispatched_to_fixture, name}
end

defmodule ALLM.Pipeline.LockTest do
  @moduledoc """
  Pins the `ALLM.Pipeline.Lock` seam and its dormant-by-default dispatch.

  ## Two tests did NOT come with this file, deliberately

  Batch 1.D moved it out of `apps/amesbury_scraper/test/pipeline_lock_test.exs`.
  Its last describe asserted that `Advisory.lock_key_for/1` collapses
  `:project`/`:project_refresh` and `:video_summary`/`:poi_thumbnails` onto one
  key — but those four names are Amesbury's `lock_keys:` DECLARATION, which
  batch 1.C moved off the framework and onto `Amesbury.Pipelines` precisely so
  the framework would stop naming host pipelines. Re-asserting them from the
  package tree puts that knowledge back one tree over, so they moved to the
  Amesbury repo's `apps/amesbury_scraper/test/amesbury/pipelines_declared_values_test.exs`
  instead — the same carve-out `metrics_test.exs`'s three membership tests took,
  for the same reason.

  Nothing was lost by the move: `runner_test.exs` already drives both collapses
  through the public `Runner.lock_key_for/1`, and `pipelines_test.exs` guards the
  derived SET (declaration ⇔ what `Config.lock_keys/0` resolves).

  What stays here is the part that is genuinely the framework's: `impl/0`'s
  resolution (fallback, configured value, and the key-present-but-`:impl`-absent
  case), and `with_lock/2`'s three pass-through behaviours under `Noop` plus the
  dispatch itself. The pipeline atoms below (`:rich_summary`, `:meeting`,
  `:video`) are opaque — no assertion depends on their being real Amesbury
  pipelines.

  ## Why this file establishes the `:impl` env itself

  `:allm_pipeline` IS started while this package's suite runs (that is how
  `ALLM.Pipeline.Config.repo/0` resolves for the sandbox setups next door), and
  `ALLM.Pipeline.Registry.__install__/1` writes `impl: Noop` into
  `Application.get_env(:allm_pipeline, ALLM.Pipeline.Lock)` from
  `Amesbury.Pipelines`' `lock:` declaration at boot. So a bare
  `assert Lock.impl() == Noop` observes **Amesbury's declaration**, not the
  framework's fallback — flipping `impl/0`'s default to `Advisory` would leave it
  green. That is the same carve-out rule 1.D applied to the two `lock_keys:`
  tests: *does the assertion depend on a value the DESTINATION does not own?*
  Every test below therefore sets the env it depends on and restores it, so the
  file asserts framework behaviour rather than the host's wiring.
  """

  # `async: false`: every test here mutates the global application env.
  use ExUnit.Case, async: false

  alias ALLM.Pipeline.Lock
  alias ALLM.Pipeline.Lock.Noop
  alias ALLM.Pipeline.LockTest.FixtureLock

  setup do
    previous = Application.get_env(:allm_pipeline, Lock)

    on_exit(fn ->
      if previous do
        Application.put_env(:allm_pipeline, Lock, previous)
      else
        Application.delete_env(:allm_pipeline, Lock)
      end
    end)

    :ok
  end

  describe "impl/0" do
    test "falls back to Noop when the host configures no :impl (advisory lock retired)" do
      # The fallback is only observable with the host's declaration removed. The
      # dropped-lock default must be Noop so runs don't pin a connection via
      # Repo.checkout for the whole run.
      Application.delete_env(:allm_pipeline, Lock)

      assert Lock.impl() == Noop
    end

    test "returns a configured :impl rather than the fallback" do
      # A fixture adapter, not a real one: neither the fallback nor any host
      # declaration can produce this value, so the assertion cannot be satisfied
      # by the default the previous test pins.
      Application.put_env(:allm_pipeline, Lock, impl: FixtureLock)

      assert Lock.impl() == FixtureLock
    end

    test "falls back to Noop when the key exists but carries no :impl" do
      Application.put_env(:allm_pipeline, Lock, some_other_key: :ignored)

      assert Lock.impl() == Noop
    end
  end

  describe "with_lock/2 under Noop" do
    setup do
      # Establish the premise locally instead of inheriting it from
      # `Amesbury.Pipelines`' declaration — see the moduledoc.
      Application.put_env(:allm_pipeline, Lock, impl: Noop)
      :ok
    end

    test "runs the function and returns its result, never :already_running" do
      assert Lock.with_lock(:rich_summary, fn -> {:ok, :ran} end) == {:ok, :ran}
    end

    test "does not swallow the function's own error return" do
      assert Lock.with_lock(:meeting, fn -> {:error, :boom} end) == {:error, :boom}
    end

    test "propagates a raise from the function (no lock bookkeeping to mask it)" do
      assert_raise RuntimeError, "kaboom", fn ->
        Lock.with_lock(:video, fn -> raise "kaboom" end)
      end
    end

    test "dispatches through impl/0 rather than hard-coding Noop" do
      # The three assertions above are all satisfied by `fun.()` alone, so a
      # `with_lock/2` rewritten to call `Noop.with_lock/2` directly — or to run
      # the function itself — would keep them green. `FixtureLock` returns
      # something only a live dispatch can produce, and does NOT call the
      # function, so the discriminating observable is the value's PROVENANCE.
      Application.put_env(:allm_pipeline, Lock, impl: FixtureLock)

      assert Lock.with_lock(:rich_summary, fn -> {:ok, :ran} end) ==
               {:dispatched_to_fixture, :rich_summary}
    end
  end
end
