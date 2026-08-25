defmodule ALLM.Pipeline.MetricsTest do
  @moduledoc """
  Pins `ALLM.Pipeline.Metrics` and `PipelineMetric`.

  ## Three tests did NOT come with this file, deliberately

  Batch 1.D moved this file out of `apps/amesbury_scraper/test/`. Three of its
  tests asserted MEMBERSHIP of Amesbury's `alert_on_empty:` declaration —
  `committee_scrape` / `meeting_agenda_scrape` / `rvcs_board_meetings` in,
  `ordinance_scrape` / `poi_thumbnails` out. Those names are host domain
  knowledge, which batch 1.C moved OUT of the framework and onto
  `Amesbury.Pipelines`; re-asserting them here would put it straight back, one
  tree over. They live in the Amesbury repo's
  `apps/amesbury_scraper/test/amesbury/pipelines_declared_values_test.exs`,
  beside `pipelines_test.exs`'s derived-SET guard, which is where
  `pipelines_test.exs`'s own moduledoc says the concrete values stay pinned.

  A fixture registry inside this file was rejected for the same reason (see
  PHASE_1 §5.5): it would pin the framework's mechanism with invented values and
  leave Amesbury's real three names asserted nowhere.

  Every remaining host name here (`"committee_scrape"` in the `history/2` and
  `alert_reasons/2` cases, and so on) is an **opaque run-name string** whose
  value no assertion depends on — `Metrics.status/1` on a `found: 5` metric is
  `:ok` regardless of the name.

  ## The sandbox setup

  A faithful port of `AmesburyScraper.DataCase.setup_sandbox/1`, which this tree
  cannot see; `errors_on/1` is inlined from the same template for the two
  changeset assertions below. `Config.repo/0` is how package code names the host
  repo.
  """

  use ExUnit.Case, async: true

  import Ecto.Query

  alias ALLM.Pipeline.{Config, Metrics, PipelineMetric, PipelineRun}

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  # Verbatim from `AmesburyScraper.DataCase`, which the package tree cannot see.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Seed a completed PipelineRun via the real context (no ExMachina factory in the
  # scraper test tree). Returns the persisted run.
  defp completed_run(name) do
    {:ok, run} = PipelineRun.create(name)
    {:ok, run} = PipelineRun.complete(run)
    run
  end

  # Backdate a row's inserted_at so ordering is deterministic (inserted_at alone can
  # tie within a microsecond). `table` is the string table name; `id` the binary_id.
  # Schemaless query against a string source: Ecto can't infer the binary_id type, so
  # the UUID must be dumped to its 16-byte binary form (raw inserts/queries bypass casting).
  defp backdate(table, id, %DateTime{} = at) do
    raw_id = Ecto.UUID.dump!(id)

    from(r in table, where: r.id == ^raw_id)
    |> Config.repo().update_all(set: [inserted_at: at])
  end

  describe "record/3" do
    test "inserts a row with the run's id + name, funnel counts + tokens, defaulting absent keys to 0" do
      run = completed_run("committee_scrape")

      assert {:ok, metric} = Metrics.record(run, "committees", %{found: 5, tokens: 4200})

      assert metric.pipeline_run_id == run.id
      assert metric.pipeline_name == "committee_scrape"
      assert metric.entity_type == "committees"
      assert metric.found == 5
      assert metric.tokens == 4200
      # absent keys default to 0
      assert metric.mapped == 0
      assert metric.processed == 0
      assert metric.skipped == 0
      assert metric.failed == 0
    end

    test "with a negative count returns {:error, changeset} and does not raise" do
      run = completed_run("committee_scrape")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Metrics.record(run, "committees", %{found: -1})

      refute changeset.valid?
      assert %{found: [_ | _]} = errors_on(changeset)
    end

    test "validates tokens as non-negative too" do
      run = completed_run("ordinance_scrape")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Metrics.record(run, "ordinances", %{tokens: -5})

      assert %{tokens: [_ | _]} = errors_on(changeset)
    end

    test "best-effort rescue: a raise inside the write path returns {:error, exception}, never raises" do
      run = completed_run("committee_scrape")

      # The changeset/FK error paths return {:error, changeset} cleanly and never
      # reach the rescue. To exercise the "backstop for everything else" clause we
      # need a genuine raise inside record/3's body: a non-map funnel trips
      # `Map.take/2` with a BadMapError before Repo.insert is ever called. The
      # best-effort contract must swallow it — log and return {:error, e}, not raise.
      assert {:error, %BadMapError{}} = Metrics.record(run, "committees", :not_a_map)
    end
  end

  describe "latest_per_pipeline/0" do
    test "returns exactly one row per pipeline_name — the newest" do
      run1 = completed_run("meeting_agenda_scrape")
      run2 = completed_run("meeting_agenda_scrape")

      {:ok, older} = Metrics.record(run1, "meetings", %{found: 1})
      {:ok, newer} = Metrics.record(run2, "meetings", %{found: 2})

      # Backdate the earlier metric row so ordering is deterministic.
      backdate("pipeline_metrics", older.id, ~U[2020-01-01 00:00:00.000000Z])

      results = Metrics.latest_per_pipeline()

      assert [%PipelineMetric{} = row] =
               Enum.filter(results, &(&1.pipeline_name == "meeting_agenda_scrape"))

      assert row.id == newer.id
      assert row.found == 2
    end

    test "distinct across multiple pipeline names" do
      a = completed_run("committee_scrape")
      b = completed_run("rvcs_board_meetings")

      {:ok, _} = Metrics.record(a, "committees", %{found: 3})
      {:ok, _} = Metrics.record(b, "meetings", %{found: 7})

      names = Metrics.latest_per_pipeline() |> Enum.map(& &1.pipeline_name)

      assert "committee_scrape" in names
      assert "rvcs_board_meetings" in names
      assert length(names) == length(Enum.uniq(names))
    end
  end

  describe "latest_run_per_pipeline/0" do
    test "returns a %{name => run} map with the newest run per name; absent name missing" do
      run1 = completed_run("meeting_agenda_scrape")
      run2 = completed_run("meeting_agenda_scrape")

      backdate("pipeline_runs", run1.id, ~U[2020-01-01 00:00:00.000000Z])

      map = Metrics.latest_run_per_pipeline()

      assert %PipelineRun{id: id} = map["meeting_agenda_scrape"]
      assert id == run2.id
      refute Map.has_key?(map, "never_ran_pipeline")
    end
  end

  describe "history/2" do
    test "returns rows newest-first honoring limit" do
      run = completed_run("ordinance_scrape")

      {:ok, m1} = Metrics.record(run, "ordinances", %{found: 1})
      {:ok, m2} = Metrics.record(run, "ordinances", %{found: 2})
      {:ok, _m3} = Metrics.record(run, "ordinances", %{found: 3})

      # Backdate two of them so newest-first order is deterministic: m1 oldest, m2 middle.
      backdate("pipeline_metrics", m1.id, ~U[2020-01-01 00:00:00.000000Z])
      backdate("pipeline_metrics", m2.id, ~U[2021-01-01 00:00:00.000000Z])

      rows = Metrics.history("ordinance_scrape", 2)

      assert length(rows) == 2
      # newest (m3, found=3) first, then m2 (found=2); m1 excluded by limit
      assert Enum.map(rows, & &1.found) == [3, 2]
    end

    test "history/1 (default limit) returns every row newest-first" do
      run = completed_run("ordinance_scrape")

      {:ok, m1} = Metrics.record(run, "ordinances", %{found: 1})
      {:ok, _m2} = Metrics.record(run, "ordinances", %{found: 2})
      {:ok, _m3} = Metrics.record(run, "ordinances", %{found: 3})

      # Backdate the first row so it's unambiguously the oldest (hence last).
      backdate("pipeline_metrics", m1.id, ~U[2020-01-01 00:00:00.000000Z])

      # No explicit limit → exercises the `history/1` arity and the default of 30.
      rows = Metrics.history("ordinance_scrape")

      assert length(rows) == 3
      assert List.last(rows).found == 1
    end
  end

  describe "status/1 (metric-intrinsic)" do
    test "failed=0, found>0 is :ok, even with a nonzero unmapped baseline" do
      metric = %PipelineMetric{
        pipeline_name: "meeting_agenda_scrape",
        found: 10,
        mapped: 8,
        failed: 0
      }

      assert Metrics.status(metric) == :ok
    end

    test "failed>0 is :alert" do
      metric = %PipelineMetric{pipeline_name: "project_enrichment", found: 10, failed: 2}
      assert Metrics.status(metric) == :alert
    end

    # The two `found: 0` cases — one allowlisted name, one not — moved to
    # the Amesbury repo's `apps/amesbury_scraper/test/amesbury/pipelines_declared_values_test.exs`
    # in batch 1.D, together with the whole `expects_data?/1` describe. All
    # three depend on WHICH names Amesbury declares under `alert_on_empty:`,
    # which is host domain knowledge; see this module's moduledoc.
  end

  describe "overall_status/2 + alert_reasons/2 (dashboard)" do
    test "green metric with nil last run is :ok, []" do
      metric = %PipelineMetric{pipeline_name: "committee_scrape", found: 5, failed: 0}

      assert Metrics.alert_reasons(metric, nil) == []
      assert Metrics.overall_status(metric, nil) == :ok
    end

    test "green metric with a :success last run is :ok, []" do
      metric = %PipelineMetric{pipeline_name: "committee_scrape", found: 5, failed: 0}
      run = %PipelineRun{name: "committee_scrape", status: :success}

      assert Metrics.alert_reasons(metric, run) == []
      assert Metrics.overall_status(metric, run) == :ok
    end

    test "stale-green: green metric with a :failed last run is :alert, [\"last run failed\"]" do
      metric = %PipelineMetric{pipeline_name: "rvcs_board_meetings", found: 5, failed: 0}
      run = %PipelineRun{name: "rvcs_board_meetings", status: :failed}

      assert Metrics.alert_reasons(metric, run) == ["last run failed"]
      assert Metrics.overall_status(metric, run) == :alert
    end

    test "stale-green: green metric with a :cancelled last run is :alert, [\"last run cancelled\"]" do
      metric = %PipelineMetric{pipeline_name: "rvcs_board_meetings", found: 5, failed: 0}
      run = %PipelineRun{name: "rvcs_board_meetings", status: :cancelled}

      assert Metrics.alert_reasons(metric, run) == ["last run cancelled"]
      assert Metrics.overall_status(metric, run) == :alert
    end

    test "failed=2 metric with a :success run is :alert, [\"2 failed\"]" do
      metric = %PipelineMetric{pipeline_name: "project_enrichment", found: 10, failed: 2}
      run = %PipelineRun{name: "project_enrichment", status: :success}

      assert Metrics.alert_reasons(metric, run) == ["2 failed"]
      assert Metrics.overall_status(metric, run) == :alert
    end
  end
end
