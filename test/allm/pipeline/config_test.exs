defmodule ALLM.Pipeline.ConfigTest do
  @moduledoc """
  Pins the contract of all three of `ALLM.Pipeline.Config`'s accessors —
  including every raise branch, which are the module's whole reason for
  existing.

  `Config` is the only host-collaborator seam in the package, and its `@doc`
  promises it raises "rather than returning `nil` and failing later inside Ecto
  with a message that names neither this key nor this package". Nothing enforced
  that promise until this file: the assertions below are on the message NAMING
  the key and the package, not merely on something being raised.

  `alert_on_empty/0` and `lock_keys/0` held no shape check at all until the
  Phase 1 polish pass — the registry validates its own options, but a host
  writing the config key directly (documented as supported on `repo/0`) bypassed
  it, and both failed OPEN: a wrongly-shaped `alert_on_empty` degraded to a
  permanent `false` from `Metrics.expects_data?/1`, and the keyword form of
  `lock_keys` — the exact shape the registry accepts — reached
  `Advisory.canonical_lock_name/1` as a `BadMapError`.

  **Not `async: true`** — every test here mutates `:allm_pipeline`'s
  application env, which is global to the VM.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.Config

  setup do
    # The host installs all three of these at `:allm_pipeline` boot, so each
    # test establishes the value it depends on and restores what it found (see
    # this repo's CLAUDE.md §5).
    originals =
      Map.new([:repo, :alert_on_empty, :lock_keys], fn key ->
        {key, Application.fetch_env(:allm_pipeline, key)}
      end)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:allm_pipeline, key, value)
        {key, :error} -> Application.delete_env(:allm_pipeline, key)
      end)
    end)

    :ok
  end

  describe "repo/0" do
    test "returns the configured module" do
      Application.put_env(:allm_pipeline, :repo, SomeHost.Repo)

      assert Config.repo() == SomeHost.Repo
    end

    test "resolves at runtime, not at compile time" do
      Application.put_env(:allm_pipeline, :repo, First.Repo)
      assert Config.repo() == First.Repo

      Application.put_env(:allm_pipeline, :repo, Second.Repo)
      assert Config.repo() == Second.Repo
    end

    test "raises naming the config key and the package when unconfigured" do
      Application.delete_env(:allm_pipeline, :repo)

      message = assert_raise(RuntimeError, fn -> Config.repo() end).message

      assert message =~ "ALLM.Pipeline"
      assert message =~ ":allm_pipeline"
      assert message =~ "repo:"
    end

    test "raises naming the config key, the package and the bad value for a non-module" do
      # The plausible typo: a quoted module name. Before this clause existed it
      # raised a bare CaseClauseError, naming neither the key nor the package.
      Application.put_env(:allm_pipeline, :repo, "Amesbury.Repo")

      message = assert_raise(RuntimeError, fn -> Config.repo() end).message

      assert message =~ "ALLM.Pipeline"
      assert message =~ ":allm_pipeline"
      assert message =~ "repo:"
      assert message =~ ~s("Amesbury.Repo")
    end

    test "raises for a non-module of any shape, not just a string" do
      for bad <- [42, %{repo: SomeHost.Repo}, {:ok, SomeHost.Repo}, [SomeHost.Repo]] do
        Application.put_env(:allm_pipeline, :repo, bad)

        message = assert_raise(RuntimeError, fn -> Config.repo() end).message
        assert message =~ ":allm_pipeline"
      end
    end
  end

  describe "alert_on_empty/0" do
    test "defaults to [] when the host declares nothing" do
      Application.delete_env(:allm_pipeline, :alert_on_empty)

      assert Config.alert_on_empty() == []
    end

    test "returns the configured run-name strings" do
      Application.put_env(:allm_pipeline, :alert_on_empty, ["meeting", "committee_list"])

      assert Config.alert_on_empty() == ["meeting", "committee_list"]
    end

    test "raises naming the key and the package for a wrongly-shaped value" do
      # The plausible mistake is cron ATOMS: `alert_on_empty:` keys on
      # `PipelineRun.name` strings. Left ungated it degrades to a permanent
      # `false` from `Metrics.expects_data?/1` — the alert simply never fires.
      for bad <- [[:meeting], "meeting", %{meeting: true}, ["ok", :bad]] do
        Application.put_env(:allm_pipeline, :alert_on_empty, bad)

        message = assert_raise(RuntimeError, fn -> Config.alert_on_empty() end).message

        assert message =~ "ALLM.Pipeline"
        assert message =~ ":allm_pipeline"
        assert message =~ "alert_on_empty"
        assert message =~ inspect(bad)
      end
    end
  end

  describe "lock_keys/0" do
    test "defaults to %{} when the host declares nothing" do
      Application.delete_env(:allm_pipeline, :lock_keys)

      assert Config.lock_keys() == %{}
    end

    test "returns the map the registry normalizes to" do
      Application.put_env(:allm_pipeline, :lock_keys, %{project_refresh: :project})

      assert Config.lock_keys() == %{project_refresh: :project}
    end

    test "accepts the keyword form a directly-configuring host would write" do
      # The registry ACCEPTS `lock_keys: [project_refresh: :project]` and
      # normalizes it; a host writing the same natural form straight into
      # config/config.exs used to reach `Map.get/3` inside
      # `Advisory.canonical_lock_name/1` as a BadMapError, far from the cause.
      Application.put_env(:allm_pipeline, :lock_keys, project_refresh: :project)

      assert Config.lock_keys() == %{project_refresh: :project}
    end

    test "raises naming the key and both accepted shapes for anything else" do
      for bad <- [[:project_refresh], "project", 42, [{"project_refresh", :project}]] do
        Application.put_env(:allm_pipeline, :lock_keys, bad)

        message = assert_raise(RuntimeError, fn -> Config.lock_keys() end).message

        assert message =~ "ALLM.Pipeline"
        assert message =~ ":allm_pipeline"
        assert message =~ "lock_keys"
        assert message =~ inspect(bad)
      end
    end
  end
end
