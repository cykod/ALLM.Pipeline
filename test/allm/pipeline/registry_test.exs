defmodule ALLM.Pipeline.RegistryTest do
  @moduledoc """
  Pins `ALLM.Pipeline.Registry`'s two contracts:

    1. **It FEEDS the framework's config keys rather than forking them.** Every
       assertion below reads the value back through the framework's own
       accessor (`Config.repo/0`, `Store.impl/0`, …), never through the
       registry module — because "the registry wrote a key" is worth nothing if
       it is not the key the framework reads. The negative half is the
       "generates no accessor" describe: a `repo/0` on the registry would be
       the second resolution path batch 1.B's decision exists to prevent.
    2. **It rejects a malformed declaration at COMPILE time.** A registry is
       read once, at boot, by code that then fails somewhere else entirely — so
       every validation here is proven by compiling a bad declaration, not by
       calling a validator directly.

  **Not `async: true`** — `install/0` writes `:amesbury_scraper` application
  env, which is global to the VM.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.{Artifacts, Config, LLM, Lock, Store}

  # DERIVED, not a fourth hand-written copy of the seam set beside
  # `@module_keys`, `@optional_module_keys` and `@seam_keys`. A new seam key
  # joins these loops on its own; the per-seam assertions below stay explicit
  # because those are the per-member verification, not the set.
  @seam_keys ALLM.Pipeline.Registry.__seam_keys__()
  @seam_behaviours Keyword.values(@seam_keys)
  @env_keys [:repo, :alert_on_empty, :lock_keys] ++ @seam_behaviours

  setup do
    originals = Enum.map(@env_keys, &{&1, Application.fetch_env(:amesbury_scraper, &1)})

    on_exit(fn ->
      for {key, original} <- originals do
        case original do
          {:ok, value} -> Application.put_env(:amesbury_scraper, key, value)
          :error -> Application.delete_env(:amesbury_scraper, key)
        end
      end
    end)

    :ok
  end

  defmodule Fixture do
    @moduledoc false
    use ALLM.Pipeline.Registry,
      repo: RegistryTest.Repo,
      store: RegistryTest.Store,
      artifacts: RegistryTest.Artifacts,
      lock: RegistryTest.Lock,
      llm: RegistryTest.LLM,
      alert_on_empty: ~w(alpha_scrape beta_scrape),
      lock_keys: [beta_refresh: :beta]
  end

  defmodule MinimalFixture do
    @moduledoc false
    use ALLM.Pipeline.Registry,
      repo: Minimal.Repo,
      store: Minimal.Store,
      artifacts: Minimal.Artifacts,
      lock: Minimal.Lock
  end

  describe "install/0 feeds the keys the framework already reads" do
    test "the repo lands where ALLM.Pipeline.Config.repo/0 looks for it" do
      Application.delete_env(:amesbury_scraper, :repo)

      assert :ok = Fixture.install()

      # Read back through the framework's accessor, not through the registry.
      assert Config.repo() == RegistryTest.Repo
    end

    test "each seam's impl lands where that seam's impl/0 looks for it" do
      for behaviour <- @seam_behaviours,
          do: Application.delete_env(:amesbury_scraper, behaviour)

      assert :ok = Fixture.install()

      assert Store.impl() == RegistryTest.Store
      assert Artifacts.impl() == RegistryTest.Artifacts
      assert Lock.impl() == RegistryTest.Lock
      assert LLM.impl() == RegistryTest.LLM
    end

    test "EVERY declared wiring key is installed under its behaviour" do
      # The set-producing half of the assertion above, which names its four
      # members and therefore cannot notice a fifth. A wiring key present in
      # `@module_keys`/`@optional_module_keys` but missing from `@seam_keys`
      # validates at compile time and then installs NOTHING — it declares clean
      # and stays silently unwired, which is the failure mode `optional_module!/3`
      # relies on deliberately for `:llm`. `registry.ex` also carries a
      # compile-time assertion over the key list itself; this is the behavioural
      # half, over the values.
      for behaviour <- @seam_behaviours,
          do: Application.delete_env(:amesbury_scraper, behaviour)

      assert :ok = Fixture.install()

      for {key, behaviour} <- @seam_keys do
        assert Application.get_env(:amesbury_scraper, behaviour)[:impl] ==
                 Fixture.__registry__(key),
               "`#{key}:` was declared but no `impl:` reached #{inspect(behaviour)}"
      end
    end

    test "an UNDECLARED llm: installs nothing, so the seam stays loudly unwired" do
      # `llm:` is the one optional wiring key (there is no package adapter to
      # fall back to). The failure mode a lax implementation buys is not a
      # crash but a `nil` written into the seam's `impl:`, which then reaches a
      # step's `call_llm/1` as a `BadFunctionError` naming neither the key nor
      # the package.
      Application.delete_env(:amesbury_scraper, LLM)

      assert :ok = MinimalFixture.install()

      assert MinimalFixture.__registry__(:llm) == nil
      assert Application.get_env(:amesbury_scraper, LLM) == nil
      assert_raise RuntimeError, ~r/llm:/, fn -> LLM.impl() end
    end

    test "the two domain collections land where Config looks for them" do
      Application.delete_env(:amesbury_scraper, :alert_on_empty)
      Application.delete_env(:amesbury_scraper, :lock_keys)

      assert :ok = Fixture.install()

      assert Config.alert_on_empty() == ~w(alpha_scrape beta_scrape)
      assert Config.lock_keys() == %{beta_refresh: :beta}
    end

    test "an undeclared collection installs as empty, so the framework degrades neutrally" do
      assert :ok = MinimalFixture.install()

      assert Config.alert_on_empty() == []
      assert Config.lock_keys() == %{}
    end

    test "it merges into a seam's config rather than replacing it" do
      # A seam's key can legitimately carry adapter options beside `:impl`
      # (`Artifacts.Filesystem`'s `:root` is the live example). Replacing the
      # whole keyword would silently drop them at boot.
      Application.put_env(:amesbury_scraper, Artifacts, root: "/tmp/artifacts")

      assert :ok = Fixture.install()

      config = Application.get_env(:amesbury_scraper, Artifacts)
      assert Keyword.get(config, :impl) == RegistryTest.Artifacts
      assert Keyword.get(config, :root) == "/tmp/artifacts"
    end

    test "it is idempotent" do
      assert :ok = Fixture.install()
      first = Enum.map(@env_keys, &Application.get_env(:amesbury_scraper, &1))

      assert :ok = Fixture.install()
      assert Enum.map(@env_keys, &Application.get_env(:amesbury_scraper, &1)) == first
    end
  end

  describe "a config-file impl: outranks the declaration" do
    # Config files are applied BEFORE `Application.start/2`, so `install/0` is
    # the last writer. Writing the seams with `put` made every documented
    # adapter escape hatch inert at boot with no signal — `Artifacts.Filesystem`'s
    # "zero cloud infrastructure" and `Lock`'s advisory-lock restore are both
    # documented as a config-file `impl:`. These two tests are the mechanism
    # behind that documentation; without them the docs are a promise nothing
    # keeps.

    test "an explicitly-configured seam impl survives install/0" do
      # `Store` is the control: left unconfigured, so it must take the
      # declaration while the other two keep their override.
      Application.delete_env(:amesbury_scraper, Store)

      # Models a config file: set before `install/0`, as boot ordering does.
      Application.put_env(:amesbury_scraper, Artifacts, impl: ConfigFile.Artifacts)
      Application.put_env(:amesbury_scraper, Lock, impl: ConfigFile.Lock)

      assert :ok = Fixture.install()

      assert Artifacts.impl() == ConfigFile.Artifacts,
             "install/0 clobbered a config-file `impl:` — the documented adapter " <>
               "escape hatch is inert"

      assert Lock.impl() == ConfigFile.Lock

      # The seam nobody configured still gets the declaration.
      assert Store.impl() == RegistryTest.Store
    end

    test "the non-seam keys are written unconditionally — the registry owns them" do
      Application.put_env(:amesbury_scraper, :repo, ConfigFile.Repo)
      Application.put_env(:amesbury_scraper, :alert_on_empty, ~w(stale_scrape))
      Application.put_env(:amesbury_scraper, :lock_keys, %{stale: :stale})

      assert :ok = Fixture.install()

      assert Config.repo() == RegistryTest.Repo
      assert Config.alert_on_empty() == ~w(alpha_scrape beta_scrape)
      assert Config.lock_keys() == %{beta_refresh: :beta}
    end
  end

  describe "it generates no accessor for anything it installs" do
    test "no repo/0 — the package resolves the repo in exactly one place" do
      # Batch 1.B decided `ALLM.Pipeline.Config.repo/0` is the package's single,
      # permanent host-repo handle: two of its four consumers (`Metrics`,
      # `Lock.Advisory`) sit outside `Store` entirely. A `repo/0` here would be
      # a second resolution path with nothing tying the two together, and an
      # advisory lock taken through one pool while the pipeline writes through
      # another is a guard that silently guards nothing.
      refute function_exported?(Fixture, :repo, 0)
    end

    test "no store/0, artifacts/0, lock/0 or llm/0 either" do
      for name <- [:store, :artifacts, :lock, :llm] do
        refute function_exported?(Fixture, name, 0),
               "the registry generated #{name}/0 — the framework must read every seam " <>
                 "through that seam's own impl/0, not through the host's registry"
      end
    end

    test "__registry__/1 reads the DECLARATION, and normalizes lock_keys to a map" do
      # Introspection for guards and tooling only — nothing in the framework
      # calls it. It is what lets a host-side test assert "what the framework
      # resolves equals what the registry declared" without hand-mirroring
      # either side.
      assert Fixture.__registry__(:repo) == RegistryTest.Repo
      assert Fixture.__registry__(:store) == RegistryTest.Store
      assert Fixture.__registry__(:alert_on_empty) == ~w(alpha_scrape beta_scrape)
      assert Fixture.__registry__(:lock_keys) == %{beta_refresh: :beta}
    end
  end

  describe "a malformed declaration fails at compile time" do
    test "a missing wiring key names the key and says why it is mandatory" do
      for key <- [:repo, :store, :artifacts, :lock] do
        declaration =
          Keyword.delete(
            [repo: A.Repo, store: A.Store, artifacts: A.Artifacts, lock: A.Lock],
            key
          )

        message = assert_raise(ArgumentError, fn -> compile_registry(declaration) end).message

        assert message =~ "#{key}:"
        assert message =~ "requires"
      end
    end

    test "a declared llm: must still be a module — optional is not unvalidated" do
      # The optional key's validation is the SAME as a mandatory one's once it
      # is present. Skipping it would write a non-module into the seam at boot,
      # and the failure would surface at a step's first LLM call.
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry(
            repo: A.R,
            store: A.S,
            artifacts: A.A,
            lock: A.L,
            llm: "MyApp.Pipelines.LLM"
          )
        end).message

      assert message =~ "llm:"
      assert message =~ "must be a module"
    end

    test "a non-module wiring value is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry(repo: "Amesbury.Repo", store: A.S, artifacts: A.A, lock: A.L)
        end).message

      assert message =~ "repo:"
      assert message =~ "must be a module"
    end

    test "alert_on_empty must be run-name STRINGS, not cron atoms" do
      # The namespaces do not line up: one pipeline module emits several run
      # names by mode (extraction plan §3.8a), so an atom here would silently
      # never match and the empty-scrape alert would go quiet.
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry(
            repo: A.R,
            store: A.S,
            artifacts: A.A,
            lock: A.L,
            alert_on_empty: [:committee_scrape]
          )
        end).message

      assert message =~ "alert_on_empty:"
      assert message =~ "STRINGS"
    end

    test "lock_keys must be a keyword list of atom => atom" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry(
            repo: A.R,
            store: A.S,
            artifacts: A.A,
            lock: A.L,
            lock_keys: %{"project_refresh" => "project"}
          )
        end).message

      assert message =~ "lock_keys:"
    end

    test "an unknown option is rejected, and the message says values do not belong here" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry(
            repo: A.R,
            store: A.S,
            artifacts: A.A,
            lock: A.L,
            dynamo_table: "amesbury_artifacts"
          )
        end).message

      assert message =~ ":dynamo_table"
      assert message =~ "VALUES"
    end
  end

  # Compile a throwaway registry so the raise is proven where it actually
  # happens — at the host's compile time — rather than by calling the validator.
  @spec compile_registry(keyword()) :: term()
  defp compile_registry(declaration) do
    module = :"Elixir.ALLM.Pipeline.RegistryTest.Bad#{System.unique_integer([:positive])}"

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use ALLM.Pipeline.Registry, unquote(Macro.escape(declaration))
        end
      end
    )
  end
end
