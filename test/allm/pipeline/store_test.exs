defmodule ALLM.Pipeline.StoreFixtureStep do
  @moduledoc """
  Minimal `ALLM.Pipeline.Step` shape for exercising the store.

  `StepLog.log_start/4` reads `step_type/0` and `input_schema/0` off the step
  module and serializes the input struct; nothing here is ever executed, so
  only those two callbacks and the two schemas exist.
  """

  defmodule Input do
    @moduledoc false
    defstruct [:label]
    @type t :: %__MODULE__{label: String.t() | nil}
  end

  defmodule Output do
    @moduledoc false
    defstruct [:label]
    @type t :: %__MODULE__{label: String.t() | nil}
  end

  @spec step_type() :: atom()
  def step_type, do: :store_fixture_step

  @spec input_schema() :: module()
  def input_schema, do: Input
end

defmodule ALLM.Pipeline.StoreTest do
  @moduledoc """
  Pins `ALLM.Pipeline.Store` and its one adapter, `Store.Ecto`.

  ## The assertion that matters most

  `%PipelineRun{}` carries a virtual `:completion_token`, minted inside
  `PipelineRun.create/3` and required by all three terminal writers. An adapter
  that RECONSTRUCTS a run from row data instead of returning the created struct
  gives back a permanently non-owning handle — and because the field is never
  cast, never persisted and absent from every migration, no migration gate and
  no row-level round-trip can see it. `create_run/3` and `start_run/1` below
  are the only instruments that can; they are the store-side mirror of
  `pipeline_run_test.exs`'s "create/3 mints a completion token that survives
  start/1".

  ## Where this test lives, and why it can

  In the package's own tree, despite needing a database. `apps/allm_pipeline`
  depends on no umbrella app, so it cannot `alias Amesbury.Repo` — but a
  `mix test` from the UMBRELLA ROOT starts every umbrella app, so the host repo
  is running and reachable through `ALLM.Pipeline.Config.repo/0`, which is
  exactly how package code reaches it in production. Measured 2026-08-14.

  *Reachable* is not the same as *checkout-able*: `Sandbox.checkout/1` below
  needs the repo in `:manual` mode, and this package's own
  `test/test_helper.exs` is what puts it there. It deliberately does not lean
  on a sibling umbrella app's helper having run first — see the comment there.

  **Not `async: true`** — the sandbox is checked out explicitly rather than
  through a `DataCase` this tree cannot see.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.{Config, PipelineRun, StepLog, Store}
  alias ALLM.Pipeline.StoreFixtureStep

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Config.repo())
    :ok
  end

  defp new_run(name \\ "store_test") do
    {:ok, run} = Store.Ecto.create_run(name, %{}, [])
    run
  end

  defp new_step(run) do
    {:ok, step} =
      Store.Ecto.log_step_start(
        run.id,
        StoreFixtureStep,
        %StoreFixtureStep.Input{label: "in"},
        nil
      )

    step
  end

  # `impl/0`'s default and runtime resolution, and `Store.Ecto`'s `@behaviour`
  # declaration + callback conformance, are pinned once for all three seams in
  # `behaviours_test.exs`.
  describe "the behaviour's scope" do
    test "is runs and steps — no metrics, no repo, no lock" do
      names = Store.behaviour_info(:callbacks) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      # §5.3 scopes `Store` to `PipelineRun` and `StepLog` only. `Metrics` is a
      # third schema and `Lock.Advisory` sits behind a different behaviour;
      # both keep reading `Config.repo/0` directly. A callback named for either
      # means the scope moved without the design moving with it.
      refute Enum.any?(names, &String.contains?(Atom.to_string(&1), "metric"))
      refute Enum.any?(names, &String.contains?(Atom.to_string(&1), "lock"))
      refute :repo in names
    end
  end

  describe "the harness this file needs" do
    test "the package's own test_helper puts the sandbox in :manual mode" do
      # `setup` above calls `Sandbox.checkout/1`, which is meaningful only in
      # `:manual` mode. Under `:auto` these tests still pass — measured
      # 2026-08-14 — so a bare `assert` on their outcome cannot see the
      # difference. The discriminating observable is a process that never
      # checked out: `:manual` refuses it, `:auto` hands it a LIVE connection
      # whose writes commit. That is what a moved framework test file forgetting
      # its checkout would silently get.
      #
      # A bare `spawn` rather than a `Task` — Ecto resolves ownership through
      # `$callers`, which a Task would inherit and an unrelated process has not.
      parent = self()

      spawn(fn ->
        result =
          try do
            {:queried, Config.repo().aggregate("pipeline_runs", :count)}
          rescue
            error -> {:raised, error.__struct__}
          end

        send(parent, {:sandbox_probe, result})
      end)

      assert_receive {:sandbox_probe, {:raised, DBConnection.OwnershipError}}, 5_000
    end
  end

  describe "create_run/3 — the ownership token" do
    test "returns an OWNING handle, not a reconstruction" do
      run = new_run()

      assert PipelineRun.owner?(run),
             "create_run/3 returned a non-owning handle — the adapter is rebuilding the run " <>
               "instead of passing the created struct through, and every complete/2 will refuse"

      assert is_binary(run.completion_token)
      assert byte_size(run.completion_token) == 16
    end

    test "the token survives start_run/1" do
      run = new_run()
      assert {:ok, started} = Store.Ecto.start_run(run)

      assert started.status == :running
      assert started.completed_at == nil
      assert started.completion_token == run.completion_token
      assert PipelineRun.owner?(started)
    end

    test "a run re-loaded through get_run/1 is never an owner" do
      run = new_run()

      reloaded = Store.Ecto.get_run(run.id)

      assert reloaded.id == run.id
      refute PipelineRun.owner?(reloaded)
      assert {:error, :not_run_owner} = Store.Ecto.complete_run(reloaded, %{})
    end

    test "writes trigger and parent_run_id as columns, and metadata as jsonb" do
      parent = new_run("parent")

      {:ok, child} =
        Store.Ecto.create_run("child", %{"meeting_id" => "m-1"},
          trigger: "cron:child",
          parent_run_id: parent.id
        )

      persisted = Store.Ecto.get_run(child.id)

      assert persisted.trigger == "cron:child"
      assert persisted.parent_run_id == parent.id
      assert persisted.metadata == %{"meeting_id" => "m-1"}
    end

    test "an invalid run returns the changeset rather than raising" do
      assert {:error, %Ecto.Changeset{}} = Store.Ecto.create_run(nil, %{}, [])
    end
  end

  describe "the three terminal writers" do
    test "complete_run/2 stamps :success and merges metadata" do
      run = new_run()

      assert {:ok, completed} = Store.Ecto.complete_run(run, %{"processed" => 3})

      assert completed.status == :success
      assert completed.completed_at
      assert completed.metadata["processed"] == 3
    end

    test "fail_run/2 stamps :failed and records the error" do
      run = new_run()

      assert {:ok, failed} = Store.Ecto.fail_run(run, "portal down")

      assert failed.status == :failed
      assert failed.completed_at
      assert failed.metadata["error"]["message"] == "portal down"
    end

    test "cancel_run/1 stamps :cancelled" do
      run = new_run()

      assert {:ok, cancelled} = Store.Ecto.cancel_run(run)

      assert cancelled.status == :cancelled
      assert cancelled.completed_at
    end

    test "all three refuse a borrowed handle and write nothing" do
      run = new_run()
      borrowed = PipelineRun.borrow(run)

      for {label, call} <- [
            {"complete_run", fn -> Store.Ecto.complete_run(borrowed, %{}) end},
            {"fail_run", fn -> Store.Ecto.fail_run(borrowed, "boom") end},
            {"cancel_run", fn -> Store.Ecto.cancel_run(borrowed) end}
          ] do
        assert {:error, :not_run_owner} = call.(), "#{label} accepted a non-owning handle"
      end

      assert Store.Ecto.get_run(run.id).status == :pending
      assert Store.Ecto.get_run(run.id).completed_at == nil
    end
  end

  describe "step persistence" do
    test "log_step_start/4 records the step type, input schema and serialized input" do
      run = new_run()

      assert {:ok, step} =
               Store.Ecto.log_step_start(
                 run.id,
                 StoreFixtureStep,
                 %StoreFixtureStep.Input{label: "hello"},
                 nil
               )

      assert step.pipeline_run_id == run.id
      assert step.step_type == "store_fixture_step"
      assert step.input_schema == to_string(StoreFixtureStep.Input)
      assert step.input_data == %{"label" => "hello"}
      assert step.status == :running
    end

    test "log_step_start/4 threads input_step_id for lineage" do
      run = new_run()
      parent = new_step(run)

      {:ok, child} =
        Store.Ecto.log_step_start(run.id, StoreFixtureStep, %StoreFixtureStep.Input{}, parent.id)

      assert child.input_step_id == parent.id
      assert [^child] = StepLog.get_downstream_steps(parent.id)
    end

    test "log_step_success/3 closes the step and folds artifact columns in" do
      run = new_run()
      step = new_step(run)

      assert {:ok, done} =
               Store.Ecto.log_step_success(step, %StoreFixtureStep.Output{label: "out"}, %{
                 url: "memory://x",
                 size_bytes: 12,
                 checksum: "abc"
               })

      assert done.status == :success
      assert done.output_schema == to_string(StoreFixtureStep.Output)
      assert done.output_data == %{"label" => "out"}
      assert done.artifact_url == "memory://x"
      assert done.artifact_size_bytes == 12
      assert done.artifact_checksum == "abc"
    end

    test "log_step_failure/3 closes the step with a normalized error" do
      run = new_run()
      step = new_step(run)

      assert {:ok, failed} = Store.Ecto.log_step_failure(step, "selector rot", [])

      assert failed.status == :failed
      assert failed.error == %{"message" => "selector rot"}
    end

    test "log_section/3 and log_summary/4 record zero-duration steps" do
      run = new_run()

      assert {:ok, section} = Store.Ecto.log_section(run.id, "Meeting 1", nil)
      assert section.step_type == "section"
      assert section.duration_ms == 0
      assert section.input_data == %{"title" => "Meeting 1"}

      assert {:ok, summary} =
               Store.Ecto.log_summary(run.id, "video_match", %{"decided" => true}, section.id)

      assert summary.step_type == "video_match"
      assert summary.output_data == %{"decided" => true}
      assert summary.input_step_id == section.id
    end

    test "get_step/1 loads a step by id" do
      run = new_run()
      step = new_step(run)

      assert Store.Ecto.get_step(step.id).id == step.id
      assert Store.Ecto.get_step(Ecto.UUID.generate()) == nil
    end

    test "pipeline_stats/1 aggregates the run's steps and excludes sections" do
      run = new_run()

      {:ok, ok_step} =
        Store.Ecto.log_step_start(run.id, StoreFixtureStep, %StoreFixtureStep.Input{}, nil)

      {:ok, _} = Store.Ecto.log_step_success(ok_step, %StoreFixtureStep.Output{}, %{})

      {:ok, bad_step} =
        Store.Ecto.log_step_start(run.id, StoreFixtureStep, %StoreFixtureStep.Input{}, nil)

      {:ok, _} = Store.Ecto.log_step_failure(bad_step, "nope", [])

      {:ok, _} = Store.Ecto.log_section(run.id, "not counted", nil)

      stats = Store.Ecto.pipeline_stats(run.id)

      assert stats.total_steps == 2
      assert stats.successful == 1
      assert stats.failed == 1
    end
  end

  describe "what Store deliberately does NOT own" do
    test "borrow/1, owner?/1 and assume_ownership/1 stay on PipelineRun" do
      # Pure struct operations with no backend involvement. Keeping them off the
      # behaviour is what keeps the mint (create/3 + assume_ownership/1) and the
      # strip (borrow/1) to one implementation each — see PipelineRun's
      # moduledoc. An adapter surface for them would be a third mint point in
      # waiting.
      names = Store.behaviour_info(:callbacks) |> Enum.map(&elem(&1, 0))

      refute :borrow in names
      refute :owner? in names
      refute :assume_ownership in names

      run = new_run()
      assert PipelineRun.owner?(run)
      refute run |> PipelineRun.borrow() |> PipelineRun.owner?()
      assert run |> PipelineRun.borrow() |> PipelineRun.assume_ownership() |> PipelineRun.owner?()
    end
  end
end
