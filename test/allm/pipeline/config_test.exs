defmodule ALLM.Pipeline.ConfigTest do
  @moduledoc """
  Pins `ALLM.Pipeline.Config.repo/0`'s contract — including both raise branches,
  which are the module's whole reason for existing.

  `Config` is the only host-collaborator seam in the package, and its `@doc`
  promises it raises "rather than returning `nil` and failing later inside Ecto
  with a message that names neither this key nor this package". Nothing enforced
  that promise until this file: the assertions below are on the message NAMING
  the key and the package, not merely on something being raised.

  **Not `async: true`** — every test here mutates `:amesbury_scraper`'s
  application env, which is global to the VM.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.Config

  setup do
    original = Application.fetch_env(:amesbury_scraper, :repo)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:amesbury_scraper, :repo, value)
        :error -> Application.delete_env(:amesbury_scraper, :repo)
      end
    end)

    :ok
  end

  describe "repo/0" do
    test "returns the configured module" do
      Application.put_env(:amesbury_scraper, :repo, SomeHost.Repo)

      assert Config.repo() == SomeHost.Repo
    end

    test "resolves at runtime, not at compile time" do
      Application.put_env(:amesbury_scraper, :repo, First.Repo)
      assert Config.repo() == First.Repo

      Application.put_env(:amesbury_scraper, :repo, Second.Repo)
      assert Config.repo() == Second.Repo
    end

    test "raises naming the config key and the package when unconfigured" do
      Application.delete_env(:amesbury_scraper, :repo)

      message = assert_raise(RuntimeError, fn -> Config.repo() end).message

      assert message =~ "ALLM.Pipeline"
      assert message =~ ":amesbury_scraper"
      assert message =~ "repo:"
    end

    test "raises naming the config key, the package and the bad value for a non-module" do
      # The plausible typo: a quoted module name. Before this clause existed it
      # raised a bare CaseClauseError, naming neither the key nor the package.
      Application.put_env(:amesbury_scraper, :repo, "Amesbury.Repo")

      message = assert_raise(RuntimeError, fn -> Config.repo() end).message

      assert message =~ "ALLM.Pipeline"
      assert message =~ ":amesbury_scraper"
      assert message =~ "repo:"
      assert message =~ ~s("Amesbury.Repo")
    end

    test "raises for a non-module of any shape, not just a string" do
      for bad <- [42, %{repo: SomeHost.Repo}, {:ok, SomeHost.Repo}, [SomeHost.Repo]] do
        Application.put_env(:amesbury_scraper, :repo, bad)

        message = assert_raise(RuntimeError, fn -> Config.repo() end).message
        assert message =~ ":amesbury_scraper"
      end
    end
  end
end
