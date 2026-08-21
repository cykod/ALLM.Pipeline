defmodule ALLM.Pipeline.LifecycleTest do
  @moduledoc """
  Pins `ALLM.Pipeline.Lifecycle.owned_run/4` — the affordance a HAND-WRITTEN
  entry point calls to get the guarantee `use ALLM.Pipeline` generates: the run
  reaches a terminal status on every exit path, including an exit and a throw.

  The point of the affordance is that it is not a third copy. `Dsl.Runtime` and
  this function share `guard/2` and `settle/4`, so the two paths cannot drift —
  and the drift is what the tree already paid for: four entry points that
  terminated their run on no path, two orchestrators with no `rescue` at all.
  """

  use ExUnit.Case, async: true

  import Ecto.Query

  alias ALLM.Pipeline.{Config, Lifecycle, PipelineRun}

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  defp only_run(name), do: from(r in PipelineRun, where: r.name == ^name) |> Config.repo().one!()

  describe "owned_run/4 terminates the run on every exit path" do
    test "success: completes with the metadata the body returned" do
      assert {:ok, :the_value} =
               Lifecycle.owned_run("lifecycle_ok", %{seed: 1}, [], fn _run ->
                 {:ok, :the_value, %{"counted" => 3}}
               end)

      run = only_run("lifecycle_ok")
      assert run.status == :success
      assert run.completed_at
      assert run.metadata["counted"] == 3
      assert run.metadata["seed"] == 1
    end

    test "the two-element success shape completes with empty metadata" do
      assert {:ok, :v} =
               Lifecycle.owned_run("lifecycle_ok2", %{}, [], fn _run -> {:ok, :v} end)

      assert only_run("lifecycle_ok2").status == :success
    end

    test "a named failure fails the run and returns the reason" do
      assert {:error, :nope} =
               Lifecycle.owned_run("lifecycle_err", %{}, [], fn _run -> {:error, :nope} end)

      run = only_run("lifecycle_err")
      assert run.status == :failed
      assert run.metadata["error"]
    end

    test "a RAISE fails the run and is re-raised unchanged" do
      assert_raise RuntimeError, "boom", fn ->
        Lifecycle.owned_run("lifecycle_raise", %{}, [], fn _run -> raise "boom" end)
      end

      run = only_run("lifecycle_raise")
      assert run.status == :failed
      assert run.completed_at
    end

    test "an EXIT fails the run and is re-raised unchanged" do
      # The gap this affordance closes. `rescue` never sees an exit, so a
      # hand-written entry point with only a `rescue` strands its run here.
      assert catch_exit(
               Lifecycle.owned_run("lifecycle_exit", %{}, [], fn _run -> exit(:gone) end)
             ) == :gone

      run = only_run("lifecycle_exit")
      assert run.status == :failed
      assert run.completed_at
    end

    test "a THROW fails the run and is re-raised unchanged" do
      assert catch_throw(
               Lifecycle.owned_run("lifecycle_throw", %{}, [], fn _run -> throw(:tossed) end)
             ) == :tossed

      assert only_run("lifecycle_throw").status == :failed
    end
  end

  describe "ownership" do
    test "the body receives a BORROWED handle and cannot complete its own run" do
      assert {:ok, refusal} =
               Lifecycle.owned_run("lifecycle_borrow", %{}, [], fn run ->
                 refute PipelineRun.owner?(run)
                 {:ok, PipelineRun.complete(run, %{clobbered: true})}
               end)

      assert refusal == {:error, :not_run_owner}

      run = only_run("lifecycle_borrow")
      assert run.status == :success
      refute run.metadata["clobbered"]
    end
  end

  describe "attrs" do
    test "parent_run_id reaches the column, not metadata" do
      {:ok, parent} = ALLM.Pipeline.Executor.create_pipeline_run("lifecycle_parent")

      {:ok, _} =
        Lifecycle.owned_run("lifecycle_child", %{}, [parent_run_id: parent.id], fn _run ->
          {:ok, :done}
        end)

      assert only_run("lifecycle_child").parent_run_id == parent.id
    end
  end

  describe "contract violations" do
    test "a body returning something else raises AND still terminates the run" do
      assert_raise ArgumentError, ~r/Return `\{:ok, value, metadata\}`/, fn ->
        Lifecycle.owned_run("lifecycle_bad", %{}, [], fn _run -> :whatever end)
      end

      # The two assertions every sibling in "terminates the run on every exit
      # path" makes, and the ones this test used to omit. Without them the shape
      # normalizer could run OUTSIDE `guard/2` — as it did — and strand the run
      # at `:running` while this test still passed on the raise alone.
      run = only_run("lifecycle_bad")
      assert run.status == :failed
      assert run.completed_at
    end
  end

  describe "settle/4 does not report success it did not achieve" do
    test "a refused terminal write returns {:error, {:not_completed, …}}, not {:ok, …}" do
      # Reachable only by calling `settle/4` directly with a NON-owning handle —
      # both in-tree consumers hold an owning one by construction. The write is
      # correctly refused either way; what this pins is the REPORT. `{:ok, …}`
      # here would announce success for a row still at `:running`, on the one
      # function whose whole job is the terminal write.
      {:ok, owning} = ALLM.Pipeline.Executor.create_pipeline_run("lifecycle_unowned")
      borrowed = PipelineRun.borrow(owning)

      assert {:error, {:not_completed, :not_run_owner}} =
               Lifecycle.settle("lifecycle_unowned", borrowed, {:ok, :the_value, %{}}, [])

      run = only_run("lifecycle_unowned")
      assert run.status == :running
      refute run.completed_at
    end
  end

  describe "guard/2" do
    test "passes a value through untouched" do
      assert Lifecycle.guard("probe", fn -> :value end) == {:ok, :value}
    end

    test "tags all three kinds, so settle/4 can re-raise the right one" do
      assert {:raised, :error, %RuntimeError{}, _} = Lifecycle.guard("p", fn -> raise "x" end)
      assert {:raised, :exit, :x, _} = Lifecycle.guard("p", fn -> exit(:x) end)
      assert {:raised, :throw, :x, _} = Lifecycle.guard("p", fn -> throw(:x) end)
    end
  end
end
