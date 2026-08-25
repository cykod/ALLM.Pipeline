defmodule ALLM.Pipeline.EncodableTest do
  # Pure — no Repo, no sandbox.
  use ExUnit.Case, async: true

  alias ALLM.Pipeline.Encodable

  describe "rules inherited from Runner.normalize_metadata/1" do
    test "renders Calendar structs as ISO-8601" do
      assert Encodable.encode(~U[2026-06-16 13:30:00Z]) == "2026-06-16T13:30:00Z"
      assert Encodable.encode(~N[2026-06-16 13:30:00]) == "2026-06-16T13:30:00"
      assert Encodable.encode(~D[2026-06-16]) == "2026-06-16"
      assert Encodable.encode(~T[13:30:00]) == "13:30:00"
    end

    test "recurses into an arbitrary struct as a string-keyed map" do
      assert Encodable.encode(%Range{first: 1, last: 3, step: 1}) == %{
               "first" => 1,
               "last" => 3,
               "step" => 1
             }
    end

    test "stringifies map keys recursively" do
      assert Encodable.encode(%{a: %{b: 1}}) == %{"a" => %{"b" => 1}}
    end

    test "turns a non-empty keyword list into a map" do
      assert Encodable.encode(limit: 5, force: true) == %{"limit" => 5, "force" => true}
    end
  end

  describe "rules inherited from PipelineRun.stringify_keys/1" do
    test "renders a Decimal as a float" do
      assert Encodable.encode(Decimal.new("1.50")) == 1.5
    end

    test "flattens tuples to lists, recursively" do
      assert Encodable.encode({:llm_error, {:transport_error, :timeout}}) == [
               :llm_error,
               [:transport_error, :timeout]
             ]
    end

    test "reduces an Ecto.Changeset to its rendered errors" do
      changeset =
        %ALLM.Pipeline.PipelineRun{}
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.add_error(:name, "can't be blank")

      assert Encodable.encode(changeset) == %{
               "changeset_errors" => %{"name" => ["can't be blank"]}
             }
    end
  end

  describe "the two divergences the unification had to settle" do
    # `Keyword.keyword?([])` is true, so `normalize_metadata/1` turned every empty
    # list into `%{}` while `stringify_keys/1` left it a list. The two paths
    # already disagreed; the unified rule keeps `[]` a list.
    test "an empty list stays a list, not an empty map" do
      assert Encodable.encode([]) == []
      assert Encodable.encode(%{errors: [], options: []}) == %{"errors" => [], "options" => []}
    end

    # Neither predecessor scrubbed binaries, but an un-scrubbed NUL or invalid
    # UTF-8 byte fails the metadata jsonb write with 22P05 — which on the
    # `complete/2` path aborts a run after every item was already processed.
    test "scrubs NUL bytes and invalid UTF-8 out of binaries" do
      assert Encodable.encode(%{note: "before" <> <<0>> <> "after"}) == %{
               "note" => "beforeafter"
             }

      assert Encodable.encode(<<"ok", 0xFF, "fine">>) == "okfine"
    end
  end

  describe "idempotency" do
    # The create path applied BOTH predecessors in sequence to the same term
    # (`Runner.create_pipeline_run/3` normalized, `PipelineRun.create/3`
    # stringified), so the unified implementation must be a fixed point after one
    # pass or those terms corrupt.
    test "encode/1 is a fixed point on a composite term" do
      changeset =
        %ALLM.Pipeline.PipelineRun{}
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.add_error(:name, "can't be blank")

      term = %{
        options: [limit: 5, today: ~D[2026-06-16]],
        amount: Decimal.new("2.25"),
        range: %Range{first: 1, last: 3, step: 1},
        errors: [
          {"2026-105", changeset},
          {"abc", {:llm_error, {:api_error, 503, "reset" <> <<0>>}}}
        ],
        empty: [],
        at: ~U[2026-06-16 13:30:00Z]
      }

      once = Encodable.encode(term)
      assert Encodable.encode(once) == once
      # ...and a third pass, since the fixed point must not merely alternate.
      assert once |> Encodable.encode() |> Encodable.encode() == once
    end
  end

  describe "there is exactly ONE implementation" do
    # Membership guard (root CLAUDE.md: "a rule enforced in more than one shape
    # needs a MEMBERSHIP guard"). Two divergent copies is precisely the defect
    # this module was created to retire, so pin that no sibling framework module
    # grows a third.
    test "no other pipeline module defines a jsonb-normalizer" do
      # Scans THIS repo's `lib/` only. The invariant still spans the repo split
      # — a HOST module (a pipeline, a loader) can grow a second normalizer just
      # as easily — but the host tree is a different repo now (Phase 8.1
      # narrowing). The host half lives in its own twin:
      # `AmesburyScraper.Pipeline.FrameworkBoundaryGuardsTest`, "normalizer
      # uniqueness"
      # (`apps/amesbury_scraper/test/amesbury_scraper/pipeline/framework_boundary_guards_test.exs`
      # in the Amesbury umbrella).
      # Glob + fail-open floor live in the shared scaffold (extracted in Phase
      # 8.4, Rule of 3 — see `ALLM.Pipeline.TestSupport.LibScan`'s moduledoc).
      offenders =
        ALLM.Pipeline.TestSupport.LibScan.lib_files!()
        |> Enum.reject(&(Path.basename(&1) == "encodable.ex"))
        |> Enum.filter(fn path ->
          File.read!(path) =~ ~r/def(p)?\s+(normalize_metadata|stringify_keys)\s*\(/
        end)
        |> Enum.map(&Path.relative_to(&1, ALLM.Pipeline.TestSupport.LibScan.root()))

      assert offenders == [],
             "these modules re-implement jsonb normalization instead of calling " <>
               "ALLM.Pipeline.Encodable.encode/1: #{inspect(offenders)}"
    end
  end
end
