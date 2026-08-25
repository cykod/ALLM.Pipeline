defmodule ALLM.Pipeline.TestHarnessTest do
  @moduledoc """
  Pins the standalone harness wiring the whole suite silently depends on.

  `test/test_helper.exs` installs `ALLM.Pipeline.TestSupport.Registry` and
  starts `ALLM.Pipeline.TestRepo` before any test runs. A harness regression —
  a registry that silently failed to install, or an env overlay shadowing it —
  would otherwise present as ~18 files of confusing DB-backed reds (or, worse,
  a suite green against the wrong adapter). These assertions fail FIRST, by
  name.

  `async: false` and read-only on purpose: the application env is VM-global,
  and this file only OBSERVES what the helper installed — the seam-boundary
  rules for tests that WRITE env are in `CLAUDE.md` §5.
  """

  use ExUnit.Case, async: false

  test "the registry install wired the TestRepo as the framework repo" do
    assert ALLM.Pipeline.Config.repo() == ALLM.Pipeline.TestRepo
  end

  test "the registry install wired the Tiered artifact adapter" do
    # Guards the wrong-implementation a silently-failed install would leave:
    # `Artifacts.impl/0` falls back to `Artifacts.Dynamo` when the seam key is
    # absent, so asserting the resolved value alone could observe the fallback.
    # Pin the raw env first (AGENT_IMPLEMENTATION_SPEC: "pin the raw
    # application env, never only the resolved value").
    raw = Application.get_env(:amesbury_scraper, ALLM.Pipeline.Artifacts, [])
    assert raw[:impl] == ALLM.Pipeline.Artifacts.Tiered

    assert ALLM.Pipeline.Artifacts.impl() == ALLM.Pipeline.Artifacts.Tiered
  end

  test "the Tiered adapter's small/large opts were installed" do
    opts = Application.get_env(:amesbury_scraper, ALLM.Pipeline.Artifacts.Tiered, [])
    assert opts[:small] == ALLM.Pipeline.Artifacts.Dynamo
    assert opts[:large] == ALLM.Pipeline.Artifacts.S3
  end
end
