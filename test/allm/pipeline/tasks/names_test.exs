defmodule Mix.Tasks.AllmPipeline.NamesTest do
  @moduledoc """
  Pins the `mix allm_pipeline.names` task's pure rendering and the registry's
  `pipelines:` contract from the PACKAGE side.

  The package names no host module (this repo's `CLAUDE.md` §1), so this
  test drives a throwaway fixture registry rather than `Amesbury.Pipelines`. The
  host-side parity (registry metadata == `Runner`'s hand-maintained lists) lives
  in the Amesbury repo's `apps/amesbury_scraper/test/amesbury_scraper/runner_test.exs`, which can
  name the host.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.AllmPipeline.Names

  defmodule Fixture do
    @moduledoc false
    use ALLM.Pipeline.Registry,
      repo: NamesTest.Repo,
      store: NamesTest.Store,
      artifacts: NamesTest.Artifacts,
      lock: NamesTest.Lock,
      pipelines: [
        # `browser` omitted — exercises the default-`false` normalization.
        %{
          name: :alpha,
          entry: {NamesTest.Alpha, :run},
          run_names: ["alpha_scrape", "alpha_single"],
          schedules: [
            %{id: "AlphaCron", cron: "cron(0 1 * * ? *)", description: "alpha daily"}
          ]
        },
        # `schedules` omitted — exercises the default-`[]` normalization.
        %{
          name: :beta,
          entry: {NamesTest.Beta, :run_batch},
          browser: true,
          run_names: ["beta_scrape"]
        }
      ]
  end

  describe "registry pipelines: accessor and marker" do
    test "__registry__(:pipelines) returns the validated, normalized list" do
      [alpha, beta] = Fixture.__registry__(:pipelines)

      assert alpha.name == :alpha
      assert alpha.entry == {NamesTest.Alpha, :run}
      # normalized default
      assert alpha.browser == false
      assert alpha.run_names == ["alpha_scrape", "alpha_single"]
      assert [%{id: "AlphaCron"}] = alpha.schedules

      assert beta.name == :beta
      assert beta.browser == true
      # normalized default
      assert beta.schedules == []
    end

    test "an undeclared pipelines: defaults to []" do
      defmodule MinimalFixture do
        @moduledoc false
        use ALLM.Pipeline.Registry,
          repo: NamesTest.Repo,
          store: NamesTest.Store,
          artifacts: NamesTest.Artifacts,
          lock: NamesTest.Lock
      end

      assert MinimalFixture.__registry__(:pipelines) == []
    end

    test "the discovery marker is exported and returns true" do
      assert function_exported?(Fixture, :__allm_pipeline_registry__?, 0)
      assert Fixture.__allm_pipeline_registry__?() == true
    end
  end

  describe "Names.render/2" do
    test "json: exact single-line object, stable key order, browser filter" do
      json = Names.render(Fixture.__registry__(:pipelines), :json)

      assert json ==
               ~s({"pipeline_names":["alpha","beta"],"browser_pipelines":["beta"]})

      # Key order is load-bearing for the bash consumers: names first.
      names_at = :binary.match(json, "pipeline_names") |> elem(0)
      browser_at = :binary.match(json, "browser_pipelines") |> elem(0)
      assert names_at < browser_at

      # It parses back to the declared names in declaration order.
      assert %{"pipeline_names" => ["alpha", "beta"], "browser_pipelines" => ["beta"]} =
               Jason.decode!(json)
    end

    test "elixir: an inspectable term carrying both lists in order" do
      out = Names.render(Fixture.__registry__(:pipelines), :elixir)

      assert out ==
               inspect([pipeline_names: [:alpha, :beta], browser_pipelines: [:beta]],
                 limit: :infinity
               )
    end
  end

  describe "a malformed pipelines: declaration fails at compile time" do
    test "a duplicate name is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([
            %{name: :dup, entry: {A.X, :run}, run_names: ["x"]},
            %{name: :dup, entry: {A.Y, :run}, run_names: ["y"]}
          ])
        end).message

      assert message =~ "duplicate pipeline name"
    end

    test "a duplicate schedule id (across entries) is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([
            %{
              name: :a,
              entry: {A.X, :run},
              run_names: ["x"],
              schedules: [%{id: "Same", cron: "cron(0 1 * * ? *)", description: "a"}]
            },
            %{
              name: :b,
              entry: {A.Y, :run},
              run_names: ["y"],
              schedules: [%{id: "Same", cron: "cron(0 2 * * ? *)", description: "b"}]
            }
          ])
        end).message

      assert message =~ "duplicate schedule id"
    end

    test "a missing entry: names the key" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([%{name: :a, run_names: ["x"]}])
        end).message

      assert message =~ "entry:"
    end

    test "a non-tuple entry: is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([%{name: :a, entry: "A.X.run", run_names: ["x"]}])
        end).message

      assert message =~ "{module, function}"
    end

    test "a non-map entry is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([:not_a_map])
        end).message

      assert message =~ "must be a map"
    end

    test "a missing name: names the key" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([%{entry: {A.X, :run}, run_names: ["x"]}])
        end).message

      assert message =~ "name:"
    end

    test "a non-atom name: is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([%{name: "committee", entry: {A.X, :run}, run_names: ["x"]}])
        end).message

      assert message =~ "must be an atom"
    end

    test "a missing run_names: names the key" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([%{name: :a, entry: {A.X, :run}}])
        end).message

      assert message =~ "run_names:"
    end

    test "a run_names: that is not a list of strings is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([%{name: :a, entry: {A.X, :run}, run_names: "x"}])
        end).message

      assert message =~ "must be a list of strings"
    end

    test "a non-boolean browser: is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([%{name: :a, entry: {A.X, :run}, run_names: ["x"], browser: "yes"}])
        end).message

      assert message =~ "must be a boolean"
    end

    test "a non-list schedules: is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([%{name: :a, entry: {A.X, :run}, run_names: ["x"], schedules: "nope"}])
        end).message

      assert message =~ "must be a list of"
    end

    test "a non-map schedules entry is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([
            %{name: :a, entry: {A.X, :run}, run_names: ["x"], schedules: [:not_a_map]}
          ])
        end).message

      assert message =~ "must be a map"
    end

    test "a schedule entry missing id/cron/description names the missing key" do
      for missing <- [:id, :cron, :description] do
        schedule =
          Map.delete(%{id: "S", cron: "cron(0 1 * * ? *)", description: "d"}, missing)

        message =
          assert_raise(ArgumentError, fn ->
            compile_registry([
              %{name: :a, entry: {A.X, :run}, run_names: ["x"], schedules: [schedule]}
            ])
          end).message

        assert message =~ "#{missing}:"
      end
    end

    test "a schedule entry with a non-string field is rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_registry([
            %{
              name: :a,
              entry: {A.X, :run},
              run_names: ["x"],
              schedules: [%{id: "S", cron: 123, description: "d"}]
            }
          ])
        end).message

      assert message =~ "string `cron:`"
    end
  end

  # Compile a throwaway registry so the raise is proven where it actually
  # happens — at the host's compile time — mirroring `registry_test.exs`.
  @spec compile_registry([term()]) :: term()
  defp compile_registry(pipelines) do
    module = :"Elixir.ALLM.Pipeline.NamesTest.Bad#{System.unique_integer([:positive])}"

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use ALLM.Pipeline.Registry,
            repo: A.R,
            store: A.S,
            artifacts: A.A,
            lock: A.L,
            pipelines: unquote(Macro.escape(pipelines))
        end
      end
    )
  end
end
