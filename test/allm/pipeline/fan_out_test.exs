defmodule ALLM.Pipeline.FanOutTest do
  @moduledoc """
  Membership guard for the fan-out safety rule (root `CLAUDE.md`: "a rule
  enforced in more than one shape needs a MEMBERSHIP guard").

  `Task.async_stream` **links** its children, so an uncaught raise or exit in
  one item kills the caller before the stream emits anything for it. The fix
  belongs in the CHILD, and `ALLM.Pipeline.FanOut`'s moduledoc carries a table
  of every site with how each one is kept safe. Until now that table was prose
  with nothing pinning it, so a new fan-out could be added with no signal — the
  item `.work/HANDOFF.md` has carried since Phase 0 batch 1.

  This does NOT try to verify each site's safety mechanism, which is not
  mechanically checkable. It pins the SET, so adding a fan-out fails here by
  name and forces the author to add its row.
  """

  use ExUnit.Case, async: true

  alias ALLM.Pipeline.FanOut

  # `{app-relative path, call-site count}`. Re-derive with:
  #
  #   python3 scripts/refsweep.py 'Task\.async_stream\(' apps --include '*.ex' \
  #     --format hits | grep -v '/test/'
  #
  # The paren is load-bearing: `lib/` mentions `Task.async_stream` in prose 24
  # more times than it calls it — re-derived 2026-08-21, after 4.4's port:
  # 29 hits without the paren, 5 with (same sweep, `--include '*.ex'`,
  # `grep -vc '/test/'`). A bare-substring guard would pin comment churn
  # instead of call sites.
  @sites [
    {"allm_pipeline/lib/allm/pipeline/dsl/runtime.ex", 1},
    # `committee_pipeline.ex` had three until Phase 4.4 ported it onto
    # `use ALLM.Pipeline`: its detail/transform/load fan-outs are now the
    # framework's one `Task.async_stream`, which is the DSL centralizing fan-out
    # exactly as designed. This guard failed by name when they went away, which
    # is it working.
    {"amesbury_scraper/lib/amesbury_scraper/pipelines/poi_thumbnail_step.ex", 1},
    {"amesbury_scraper/lib/amesbury_scraper/processors/document_text_collector.ex", 1},
    {"amesbury_scraper/lib/amesbury_scraper/scrapers/http_scraper.ex", 1},
    {"amesbury_scraper/lib/amesbury_scraper/services/project_scale_rescale.ex", 1}
  ]

  describe "the Task.async_stream site set" do
    test "every fan-out in the repo is a known site, with a known call count" do
      # Scans BOTH trees: the rule spans the app split — `FanOut` lives in
      # `allm_pipeline` and most of its consumers are host pipelines.
      # `Path.join([__DIR__, "..", "..", "..", ".."])` resolves to `apps/` from
      # both `apps/<app>/test/<ns>/pipeline/` layouts; do NOT "fix" it.
      apps = Path.join([__DIR__, "..", "..", "..", ".."])

      trees = [
        {"allm_pipeline (the framework)", Path.join([apps, "allm_pipeline", "lib"]), 10},
        {"amesbury_scraper (the host)", Path.join([apps, "amesbury_scraper", "lib"]), 100}
      ]

      # FLOOR FIRST. A grep guard whose success signal is "found nothing" fails
      # OPEN: a zero-file glob makes the filter below yield `[]` and the test
      # reports green while guarding nothing. Each tree carries its own floor so
      # moving one cannot be masked by the other still matching. Floors sit well
      # under the live counts — 35 and 211 on 2026-08-20
      # (`find apps/<app>/lib -name '*.ex' | wc -l`), which is the command to
      # re-derive rather than trust these two integers. They are deliberately
      # slack: a floor tracking the real count would red on every file added.
      # (Corrected 2026-08-20: this comment read 32 and 216 — drifted in
      # OPPOSITE directions, so it was never a stale pre-batch measurement.)
      files =
        Enum.flat_map(trees, fn {label, lib, floor} ->
          matched = lib |> Path.join("**/*.ex") |> Path.wildcard()

          assert length(matched) > floor,
                 "the guard glob matched only #{length(matched)} files under #{lib} " <>
                   "(#{label}) — that tree moved and this test is no longer scanning " <>
                   "it. Re-point the guard."

          matched
        end)

      found =
        files
        |> Enum.map(fn path ->
          count =
            path
            |> File.read!()
            |> then(&Regex.scan(~r/Task\.async_stream\(/, &1))
            |> length()

          {Path.relative_to(path, apps), count}
        end)
        |> Enum.reject(&(elem(&1, 1) == 0))
        |> Enum.sort()

      # POSITIVE CONTROL: the scan found something at all. Without it, a regex
      # that stopped matching would report an empty set and the `--` diffs below
      # would both be empty.
      # Floor sits BELOW the current set size (5) on purpose: at `>= 5` a
      # legitimate REMOVAL of a fan-out trips this control first and reports
      # "the pattern stopped matching" — the wrong diagnosis — instead of
      # reaching the informative set diff below.
      assert length(found) >= 4,
             "the scan found only #{length(found)} fan-out files — the pattern stopped " <>
               "matching, and the set comparison below would pass vacuously."

      expected = Enum.sort(@sites)

      assert found == expected,
             "the Task.async_stream site set changed.\n" <>
               "  added/changed: #{inspect(found -- expected)}\n" <>
               "  removed:       #{inspect(expected -- found)}\n" <>
               "Update @sites here AND the Sites table in ALLM.Pipeline.FanOut's moduledoc — " <>
               "the table states how each site is kept safe, which this test cannot check."
    end

    test "the moduledoc's Sites table has a row for every scanned file" do
      # Scoped to the TABLE, not the whole moduledoc. The prose below the table
      # names `Pipelines.CommitteePipeline` twice (explaining why its three rows
      # left in 4.4), so a whole-doc `=~` would report a row exists for any file
      # merely DISCUSSED in the moduledoc — including, specifically, the one
      # module most likely to regain a fan-out. Markdown table rows are the only
      # lines starting with `|`.
      rows =
        FanOut
        |> moduledoc!()
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(String.trim_leading(&1), "|"))
        |> Enum.join("\n")

      # POSITIVE CONTROL: an empty-string `rows` makes every `=~` below fail,
      # but a table that merely lost its leading pipes would too — assert the
      # extraction found a plausible table before trusting it.
      assert length(String.split(rows, "\n")) >= length(@sites),
             "the Sites-table extraction found #{length(String.split(rows, "\n"))} `|` " <>
               "lines for #{length(@sites)} sites — the table's markdown changed and this " <>
               "guard is no longer reading it."

      # The table is keyed by MODULE name, not by path, so map each site file to
      # the last two segments of its module path — enough to be unambiguous and
      # stable against a rename of the app directory.
      for {path, _count} <- @sites do
        module_hint = path |> Path.basename(".ex") |> Macro.camelize()

        assert rows =~ module_hint,
               "ALLM.Pipeline.FanOut's Sites TABLE has no row mentioning #{module_hint} " <>
                 "(from #{path}). Every fan-out gets a row saying how it is kept safe — " <>
                 "a mention in the surrounding prose does not count."
      end
    end

    test "the Sites table's scope line covers BOTH trees" do
      # It said `apps/amesbury_scraper/lib` while the framework's own
      # `Dsl.Runtime.run_concurrent/7` — the first real fan-out in
      # `apps/allm_pipeline/lib` — had no row: defensible as written, and wrong
      # for two subphases (`.work/HANDOFF.md`, 4.1 code review F10.2).
      doc = moduledoc!(FanOut)

      assert doc =~ "in this repo"
      refute doc =~ "Every `Task.async_stream` in `apps/amesbury_scraper/lib`"
    end
  end

  describe "tag_uncaught/4" do
    test "returns the tagged tuple every consumer degrades to" do
      assert {:uncaught, :exit, :boom} =
               FanOut.tag_uncaught("item 1", :exit, :boom, [])
    end
  end

  defp moduledoc!(module) do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(module)
    doc
  end
end
