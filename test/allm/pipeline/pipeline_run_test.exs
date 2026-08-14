defmodule ALLM.Pipeline.PipelineRunTest.FixtureStep do
  @moduledoc """
  A minimal `ALLM.Pipeline.Step` shape, standing in for the host scraper this
  file used before batch 1.D moved it into the package tree.

  `StepLog.log_start/4` reads only `step_type/0` and `input_schema/0` off the
  step module and serializes the input struct; nothing here is ever executed.
  Every assertion in this file is about `PipelineRun` / `StepLog`, and none of
  them reads the step module's identity — the host scraper was an arbitrary
  "some module implementing Step", which is why substituting this one preserves
  what the tests assert. (Defined in the test file on purpose, like
  `executor_test.exs`'s `TestStep` and `executor_store_dispatch_test.exs`'s
  `SentinelStore`: a module in the test tree is absent from
  `Application.spec(:allm_pipeline, :modules)` and so cannot be mistaken for a
  shipped part of the package.)
  """

  defmodule Input do
    @moduledoc false
    defstruct [:source_url]
    @type t :: %__MODULE__{source_url: String.t() | nil}
  end

  defmodule Output do
    @moduledoc false
    defstruct [:source_url]
    @type t :: %__MODULE__{source_url: String.t() | nil}
  end

  @spec step_type() :: atom()
  def step_type, do: :fixture_step

  @spec input_schema() :: module()
  def input_schema, do: Input
end

defmodule ALLM.Pipeline.PipelineRunTest do
  @moduledoc """
  Pins `ALLM.Pipeline.PipelineRun`.

  Moved here from `apps/amesbury_scraper/test/` in batch 1.D. Two substitutions
  the move forced, both mechanical and neither touching an assertion:
  `use AmesburyScraper.DataCase` became the sandbox setup below (a faithful port
  of that template's `setup_sandbox/1`, `shared:` semantics included), and the
  host scraper used as an arbitrary Step module became `FixtureStep` above.
  `Amesbury.Repo` — reached directly for one raw `insert_all` — became
  `Config.repo/0`, which is how package code names the host repo everywhere.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ALLM.Pipeline.{Config, PipelineRun, Executor, StepLog}
  alias ALLM.Pipeline.PipelineRunTest.FixtureStep

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "create/2" do
    test "creates pipeline run with name" do
      {:ok, pipeline_run} = PipelineRun.create("committee_scrape")

      assert pipeline_run.name == "committee_scrape"
      assert pipeline_run.status == :pending
      assert pipeline_run.id != nil
    end

    test "creates pipeline run with metadata" do
      {:ok, pipeline_run} =
        PipelineRun.create("test", %{source: "manual", opts: %{dry_run: true}})

      assert pipeline_run.metadata["source"] == "manual"
      assert pipeline_run.metadata["opts"]["dry_run"] == true
    end

    test "stores trigger + parent_run_id as top-level columns (Subphase 2)" do
      {:ok, parent} = PipelineRun.create("project_refresh", %{}, trigger: "cron:project_refresh")

      {:ok, child} =
        PipelineRun.create("project_enrichment", %{},
          trigger: "cron:project_refresh",
          parent_run_id: parent.id
        )

      # The columns are set on the struct (not buried in metadata) ...
      assert parent.trigger == "cron:project_refresh"
      assert parent.parent_run_id == nil
      assert child.trigger == "cron:project_refresh"
      assert child.parent_run_id == parent.id
      refute Map.has_key?(parent.metadata, "trigger")

      # ... and round-trip through the Postgres columns on reload.
      reloaded = PipelineRun.get(child.id)
      assert reloaded.trigger == "cron:project_refresh"
      assert reloaded.parent_run_id == parent.id
    end

    test "trigger / parent_run_id default to nil when not supplied" do
      {:ok, run} = PipelineRun.create("test")
      assert run.trigger == nil
      assert run.parent_run_id == nil
    end
  end

  describe "status transitions" do
    test "tracks pipeline status transitions: pending -> running" do
      {:ok, pipeline_run} = PipelineRun.create("test")
      assert pipeline_run.status == :pending

      {:ok, started} = PipelineRun.start(pipeline_run)
      assert started.status == :running
      assert started.started_at != nil
    end

    test "tracks pipeline status transitions: running -> success" do
      {:ok, pipeline_run} = PipelineRun.create("test")
      {:ok, started} = PipelineRun.start(pipeline_run)

      {:ok, completed} = PipelineRun.complete(started)
      assert completed.status == :success
      assert completed.completed_at != nil
    end

    test "complete/2 serializes an Ecto.Changeset stashed in metadata errors (no Jason crash)" do
      {:ok, pipeline_run} = PipelineRun.create("test")
      {:ok, started} = PipelineRun.start(pipeline_run)

      # A failed loader returns its changeset; pipelines stash {id, changeset}
      # pairs in metadata["errors"]. A raw changeset has no Jason.Encoder and
      # used to crash the jsonb write on complete/2.
      changeset =
        %PipelineRun{}
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.add_error(:name, "can't be blank")

      {:ok, completed} = PipelineRun.complete(started, %{errors: [{"2026-105", changeset}]})

      assert completed.status == :success
      assert [["2026-105", err]] = completed.metadata["errors"]
      assert err["changeset_errors"]["name"] == ["can't be blank"]
    end

    test "tracks pipeline status transitions: running -> failed" do
      {:ok, pipeline_run} = PipelineRun.create("test")
      {:ok, started} = PipelineRun.start(pipeline_run)

      {:ok, failed} = PipelineRun.fail(started, "Something went wrong")
      assert failed.status == :failed
      assert failed.completed_at != nil
      assert failed.metadata["error"]["message"] == "Something went wrong"
    end

    test "tracks pipeline status transitions: running -> cancelled" do
      {:ok, pipeline_run} = PipelineRun.create("test")
      {:ok, started} = PipelineRun.start(pipeline_run)

      {:ok, cancelled} = PipelineRun.cancel(started)
      assert cancelled.status == :cancelled
      assert cancelled.completed_at != nil
    end
  end

  describe "stores pipeline metadata" do
    test "complete/2 merges result metadata" do
      {:ok, pipeline_run} = PipelineRun.create("test", %{initial: "value"})
      {:ok, started} = PipelineRun.start(pipeline_run)

      {:ok, completed} = PipelineRun.complete(started, %{steps_run: 5, success_count: 4})

      assert completed.metadata["initial"] == "value"
      assert completed.metadata["steps_run"] == 5
      assert completed.metadata["success_count"] == 4
    end

    test "fail/2 stores normalized error" do
      {:ok, pipeline_run} = PipelineRun.create("test")
      {:ok, started} = PipelineRun.start(pipeline_run)

      error = %RuntimeError{message: "Test error"}
      {:ok, failed} = PipelineRun.fail(started, error)

      assert failed.metadata["error"]["type"] == "Elixir.RuntimeError"
      assert failed.metadata["error"]["message"] == "Test error"
    end

    test "complete/2 flattens tuple-bearing metadata to JSON-safe lists" do
      # Regression: summary pipeline stashes `errors: [{meeting_id, reason}]`
      # in metrics, and `reason` is itself a nested tuple like
      # `{:llm_error, {:transport_error, :timeout}}`. Postgres encodes this
      # column via Jason, which has no Encoder for tuples — the whole write
      # used to crash on the first failed meeting.
      {:ok, pipeline_run} = PipelineRun.create("summary")
      {:ok, started} = PipelineRun.start(pipeline_run)

      meeting_id = "bc23e1a8-9e3f-4987-a6c6-6cf84eaa5b49"

      metrics = %{
        processed: 103,
        failed: 2,
        errors: [
          {meeting_id, {:llm_error, {:transport_error, :timeout}}},
          {"5939d936-d16e-458d-beb6-09021f14c87e",
           {:llm_error, {:api_error, 503, "upstream connection reset"}}}
        ]
      }

      {:ok, completed} = PipelineRun.complete(started, metrics)

      # In memory, atoms survive `Encodable.encode/1` — Jason converts them
      # to strings on the way to Postgres. Re-fetching confirms the column
      # actually round-trips through the JSON write that used to crash.
      [first_error, second_error] = completed.metadata["errors"]
      assert first_error == [meeting_id, [:llm_error, [:transport_error, :timeout]]]

      assert second_error == [
               "5939d936-d16e-458d-beb6-09021f14c87e",
               [:llm_error, [:api_error, 503, "upstream connection reset"]]
             ]

      reloaded = PipelineRun.get(completed.id)
      [first_decoded, second_decoded] = reloaded.metadata["errors"]
      assert first_decoded == [meeting_id, ["llm_error", ["transport_error", "timeout"]]]

      assert second_decoded == [
               "5939d936-d16e-458d-beb6-09021f14c87e",
               ["llm_error", ["api_error", 503, "upstream connection reset"]]
             ]
    end
  end

  describe "get/1" do
    test "retrieves pipeline run by id" do
      {:ok, pipeline_run} = PipelineRun.create("test")

      retrieved = PipelineRun.get(pipeline_run.id)

      assert retrieved.id == pipeline_run.id
      assert retrieved.name == "test"
    end

    test "returns nil for non-existent id" do
      assert PipelineRun.get(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_with_steps/1" do
    test "retrieves pipeline run with step_logs preloaded" do
      {:ok, pipeline_run} = PipelineRun.create("test")
      input = %FixtureStep.Input{}

      {:ok, _step1} = StepLog.log_start(pipeline_run.id, FixtureStep, input, nil)
      {:ok, _step2} = StepLog.log_start(pipeline_run.id, FixtureStep, input, nil)

      retrieved = PipelineRun.get_with_steps(pipeline_run.id)

      assert length(retrieved.step_logs) == 2
    end
  end

  describe "list/1" do
    test "lists pipeline runs ordered by inserted_at desc" do
      {:ok, run1} = PipelineRun.create("first")
      Process.sleep(1)
      {:ok, run2} = PipelineRun.create("second")
      Process.sleep(1)
      {:ok, run3} = PipelineRun.create("third")

      runs = PipelineRun.list()

      assert Enum.map(runs, & &1.id) == [run3.id, run2.id, run1.id]
    end

    test "filters by status" do
      {:ok, pending} = PipelineRun.create("pending")
      {:ok, running} = PipelineRun.create("running")
      {:ok, running} = PipelineRun.start(running)

      pending_runs = PipelineRun.list(status: :pending)
      running_runs = PipelineRun.list(status: :running)

      assert length(pending_runs) == 1
      assert hd(pending_runs).id == pending.id

      assert length(running_runs) == 1
      assert hd(running_runs).id == running.id
    end

    test "filters by name" do
      {:ok, _run1} = PipelineRun.create("committee_scrape")
      {:ok, _run2} = PipelineRun.create("meeting_scrape")
      {:ok, _run3} = PipelineRun.create("committee_scrape")

      committee_runs = PipelineRun.list(name: "committee_scrape")

      assert length(committee_runs) == 2
    end

    test "filters by trigger" do
      {:ok, _cron1} = PipelineRun.create("video_summary", %{}, trigger: "cron:video_summary")
      {:ok, _cli} = PipelineRun.create("video_summary", %{}, trigger: "cli")
      {:ok, _cron2} = PipelineRun.create("ordinance_scrape", %{}, trigger: "cron:ordinance")

      cron_video = PipelineRun.list(trigger: "cron:video_summary")

      assert length(cron_video) == 1
      assert hd(cron_video).name == "video_summary"
    end

    test "limits results" do
      {:ok, _} = PipelineRun.create("run1")
      {:ok, _} = PipelineRun.create("run2")
      {:ok, _} = PipelineRun.create("run3")

      limited = PipelineRun.list(limit: 2)

      assert length(limited) == 2
    end

    test "name is an exact match, not a prefix of sibling pipelines" do
      {:ok, _} = PipelineRun.create("video_summary")
      {:ok, _} = PipelineRun.create("video_summary_single")

      assert [run] = PipelineRun.list(name: "video_summary")
      assert run.name == "video_summary"
    end

    test "name_contains matches any substring, case-insensitively" do
      {:ok, _} = PipelineRun.create("video_listing")
      {:ok, _} = PipelineRun.create("video_summary")
      {:ok, _} = PipelineRun.create("committee_scrape")

      names = fn opts -> PipelineRun.list(opts) |> Enum.map(& &1.name) |> Enum.sort() end

      assert names.(name_contains: "video") == ["video_listing", "video_summary"]
      assert names.(name_contains: "VIDEO") == ["video_listing", "video_summary"]
      assert names.(name_contains: "listing") == ["video_listing"]
      assert names.(name_contains: "scrape") == ["committee_scrape"]
    end

    test "name_contains escapes LIKE wildcards rather than honoring them" do
      {:ok, _} = PipelineRun.create("video_listing")

      # `_` is a single-char LIKE wildcard; unescaped, this would match.
      assert PipelineRun.list(name_contains: "videoXlisting") == []
      # `%` would otherwise match everything.
      assert PipelineRun.list(name_contains: "%") == []
      # The literal underscore still matches itself.
      assert [%{name: "video_listing"}] = PipelineRun.list(name_contains: "video_listing")
    end

    test "an empty name_contains is treated as no filter" do
      {:ok, _} = PipelineRun.create("committee_scrape")

      assert length(PipelineRun.list(name_contains: "")) == 1
    end

    test "offset pages through results without repeating or skipping a row" do
      for i <- 1..5 do
        {:ok, _} = PipelineRun.create("run#{i}")
        Process.sleep(1)
      end

      page1 = PipelineRun.list(limit: 2, offset: 0) |> Enum.map(& &1.id)
      page2 = PipelineRun.list(limit: 2, offset: 2) |> Enum.map(& &1.id)
      page3 = PipelineRun.list(limit: 2, offset: 4) |> Enum.map(& &1.id)

      assert length(page1) == 2
      assert length(page2) == 2
      assert length(page3) == 1

      all = page1 ++ page2 ++ page3
      assert length(Enum.uniq(all)) == 5
      assert all == PipelineRun.list() |> Enum.map(& &1.id)
    end

    test "ordering is total, so runs sharing an inserted_at still page cleanly" do
      # `insert_all` stamps one timestamp across every row, collapsing the
      # `inserted_at` ordering and leaving `id` as the only tiebreak.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for i <- 1..6 do
          %{
            id: Ecto.UUID.bingenerate(),
            name: "batch#{i}",
            status: "pending",
            metadata: %{},
            inserted_at: now,
            updated_at: now
          }
        end

      Config.repo().insert_all("pipeline_runs", rows)

      pages =
        Enum.flat_map(0..2, fn p -> PipelineRun.list(limit: 2, offset: p * 2) end)
        |> Enum.map(& &1.id)

      assert length(Enum.uniq(pages)) == 6
    end
  end

  describe "count/1" do
    test "counts all runs, ignoring limit and offset" do
      for i <- 1..4, do: {:ok, _} = PipelineRun.create("run#{i}")

      assert PipelineRun.count() == 4
      assert PipelineRun.count(limit: 2, offset: 2) == 4
    end

    test "applies the same filters as list/1" do
      {:ok, _} = PipelineRun.create("video_listing")
      {:ok, _} = PipelineRun.create("video_summary")
      {:ok, running} = PipelineRun.create("video_summary")
      {:ok, _} = PipelineRun.start(running)
      {:ok, _} = PipelineRun.create("committee_scrape")

      assert PipelineRun.count(name_contains: "video") == 3
      assert length(PipelineRun.list(name_contains: "video")) == 3

      assert PipelineRun.count(name: "video_summary") == 2
      assert PipelineRun.count(status: :running) == 1
      assert PipelineRun.count(name_contains: "video", status: :running) == 1
    end
  end

  describe "completion ownership (Phase 0 item 3)" do
    test "create/3 mints a completion token that survives start/1" do
      {:ok, created} = PipelineRun.create("owned")
      assert PipelineRun.owner?(created)
      assert is_binary(created.completion_token)

      # `Repo.update` carries `changeset.data`'s virtual fields through, so
      # `Executor.create_pipeline_run/3`'s create -> start pair keeps ownership.
      {:ok, started} = PipelineRun.start(created)
      assert started.completion_token == created.completion_token
      assert {:ok, _} = PipelineRun.complete(started, %{done: true})
    end

    test "borrow/1 returns the same run without the token" do
      {:ok, run} = PipelineRun.create("umbrella")
      borrowed = PipelineRun.borrow(run)

      assert borrowed.id == run.id
      assert borrowed.name == run.name
      refute PipelineRun.owner?(borrowed)
      assert borrowed.completion_token == nil
    end

    # The `Logger.error` — not the returned tuple — is the designated practical
    # detector: `complete/2`'s own `@doc` says almost every call site discards the
    # return value. Asserting only the tuple would let a refactor that drops the
    # log line, downgrades it to `:debug`, or crashes interpolating a nil `id`
    # pass every test in the suite. Capturing it also silences the `[error]` noise
    # these refusal cases would otherwise print.
    test "complete/2 on a borrowed run is rejected, logs at :error, and writes nothing" do
      {:ok, run} = PipelineRun.create("umbrella")
      {:ok, run} = PipelineRun.start(run)

      log =
        capture_log(fn ->
          assert {:error, :not_run_owner} =
                   PipelineRun.complete(PipelineRun.borrow(run), %{meeting_id: "m-1"})
        end)

      assert log =~ "[error]"
      assert log =~ "does not own the run"
      assert log =~ "Refusing to complete"
      assert log =~ run.id
      assert log =~ "umbrella"

      reloaded = PipelineRun.get(run.id)
      assert reloaded.status == :running
      assert reloaded.completed_at == nil
      refute Map.has_key?(reloaded.metadata, "meeting_id")
    end

    test "a run re-loaded from the database is never an owner" do
      {:ok, run} = PipelineRun.create("owned")
      {:ok, run} = PipelineRun.start(run)

      reloaded = PipelineRun.get(run.id)
      refute PipelineRun.owner?(reloaded)

      log =
        capture_log(fn -> assert {:error, :not_run_owner} = PipelineRun.complete(reloaded) end)

      assert log =~ "[error]"
      assert log =~ reloaded.id
      # The message must NOT pin the blame on an inner pipeline: this handle was
      # re-loaded, not borrowed, and there is no borrowing bug to go looking for.
      assert log =~ "re-loaded from the database"

      assert PipelineRun.get(run.id).status == :running
    end

    # `complete/2`, `fail/2` and `cancel/1` all write `completed_at` plus a
    # terminal status, so the ownership rule is enforced in three shapes. Pin the
    # SET, not just the one member that shipped first (root CLAUDE.md: "a rule
    # enforced in more than one shape needs a MEMBERSHIP guard") — otherwise a
    # borrowed inner pipeline's error arm stamps the umbrella `:failed` mid-loop,
    # which is the same damage `complete/2` was guarded against.
    #
    # The other axis is PROVENANCE: a token-less handle arises three ways
    # (borrowed, re-loaded via `get/1`, resumed via `Executor.resume/2`), and
    # `resume/2` is the one whose name promises a caller it can finish the run.
    # It cannot — deliberately, since re-minting there would make `resume/2` a
    # second implicit mint point (user decision, 2026-08-13). The take-over is
    # spelled `assume_ownership/1`, asserted at the bottom.
    test "every terminal writer refuses a non-owning handle" do
      {:ok, run} = PipelineRun.create("umbrella")
      {:ok, run} = PipelineRun.start(run)

      {:ok, step} =
        StepLog.log_start(run.id, FixtureStep, %FixtureStep.Input{}, nil)

      provenances = [
        {"borrowed", fn -> PipelineRun.borrow(run) end},
        {"re-loaded", fn -> PipelineRun.get(run.id) end},
        {"resumed",
         fn ->
           {:ok, resumed} = Executor.resume(run.id, step.id)
           resumed
         end}
      ]

      for {provenance, build_handle} <- provenances,
          {label, call} <- [
            {"complete", fn handle -> PipelineRun.complete(handle, %{done: true}) end},
            {"fail", fn handle -> PipelineRun.fail(handle, "boom") end},
            {"cancel", fn handle -> PipelineRun.cancel(handle) end}
          ] do
        handle = build_handle.()
        refute PipelineRun.owner?(handle), "a #{provenance} handle must not own the run"

        log = capture_log(fn -> assert {:error, :not_run_owner} = call.(handle) end)
        assert log =~ "Refusing to #{label} pipeline run #{run.id}"

        reloaded = PipelineRun.get(run.id)

        assert reloaded.status == :running,
               "#{label}/x wrote a terminal status through a #{provenance} handle"

        assert reloaded.completed_at == nil
        refute Map.has_key?(reloaded.metadata, "error")
      end

      # ...and the sanctioned way out, for a caller that really is taking over:
      # the same resumed handle completes once passed through `assume_ownership/1`.
      {:ok, resumed} = Executor.resume(run.id, step.id)

      assert {:ok, completed} =
               resumed |> PipelineRun.assume_ownership() |> PipelineRun.complete(%{done: true})

      assert completed.status == :success
      assert PipelineRun.get(run.id).status == :success
    end

    # `fail/2` was the one metadata write site the `Encodable` unification did not
    # reach: it merged `normalize_error/1`'s output raw, so a NUL byte in a binary
    # error — or in an exception message echoing OCR'd/LLM-produced text — aborted
    # the jsonb write with `ERROR 22P05`, losing the failure record and the run.
    test "fail/2 scrubs its error message like every other metadata write" do
      {:ok, run} = PipelineRun.create("scrubbing")
      {:ok, run} = PipelineRun.start(run)

      assert {:ok, failed} = PipelineRun.fail(run, "before" <> <<0>> <> "after")
      assert failed.metadata["error"]["message"] == "beforeafter"
      assert PipelineRun.get(run.id).metadata["error"]["message"] == "beforeafter"
    end

    test "fail/2 scrubs a NUL carried in an exception message" do
      {:ok, run} = PipelineRun.create("scrubbing_exception")
      {:ok, run} = PipelineRun.start(run)

      assert {:ok, failed} =
               PipelineRun.fail(run, %RuntimeError{message: "bad" <> <<0>> <> "text"})

      assert failed.metadata["error"]["message"] == "badtext"
      assert failed.metadata["error"]["type"] == "Elixir.RuntimeError"
    end

    # The design doc's named pinning test (§3.4). An inner pipeline running under
    # a BORROWED umbrella run attempts to complete it mid-loop; the umbrella must
    # still be the sole completer, so the finished row carries the umbrella's
    # aggregate and none of the inner item's metadata.
    test "an inner pipeline cannot complete a borrowed umbrella run mid-loop" do
      {:ok, umbrella} = PipelineRun.create("video_summary", %{options: %{limit: 3}})
      {:ok, umbrella} = PipelineRun.start(umbrella)

      # Three items; each inner call gets the borrowed handle the umbrella lends
      # through the `:pipeline_run` opt, and each mistakenly tries to finish.
      for meeting_id <- ~w(m-1 m-2 m-3) do
        inner_handle = PipelineRun.borrow(umbrella)

        assert {:error, :not_run_owner} =
                 PipelineRun.complete(inner_handle, %{meeting_id: meeting_id, processed: 1})

        # Not stamped :success early — the umbrella is still running.
        assert PipelineRun.get(umbrella.id).status == :running
      end

      {:ok, _} = PipelineRun.complete(umbrella, %{processed: 3})

      metadata = PipelineRun.get(umbrella.id).metadata
      assert metadata["processed"] == 3
      refute Map.has_key?(metadata, "meeting_id")
    end
  end

  describe "associates step logs via pipeline_run_id" do
    test "step logs reference the pipeline run" do
      {:ok, pipeline_run} = PipelineRun.create("test")
      input = %FixtureStep.Input{}

      {:ok, step} = StepLog.log_start(pipeline_run.id, FixtureStep, input, nil)

      assert step.pipeline_run_id == pipeline_run.id

      # Verify relationship works
      retrieved = PipelineRun.get_with_steps(pipeline_run.id)
      assert hd(retrieved.step_logs).id == step.id
    end
  end
end
