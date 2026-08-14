defmodule ALLM.Pipeline.SentinelStore do
  @moduledoc """
  A `ALLM.Pipeline.Store` adapter that answers sentinels instead of touching a
  database, so `ALLM.Pipeline.ExecutorStoreDispatchTest` can tell "Executor went
  through the configured seam" from "Executor called `Store.Ecto` directly".

  Only the two callbacks that test drives are meaningful; the rest raise, which
  is the right default for a stub (a stub that silently succeeds is vacuity
  grammar 7 — a degradation that erases the discriminator).

  Lives in the test tree, so it is absent from
  `Application.spec(:allm_pipeline, :modules)` and therefore invisible to
  `behaviours_test.exs`'s package-wide discovery guards — which is correct: it
  is not a shipped adapter and must not join `@seams`.
  """

  @behaviour ALLM.Pipeline.Store

  @known_run_id "11111111-1111-1111-1111-111111111111"

  @impl true
  def get_run(@known_run_id), do: :sentinel_run
  def get_run(_id), do: nil

  @impl true
  def pipeline_stats(_run_id), do: %{sentinel: true}

  @impl true
  def create_run(_name, _metadata, _attrs), do: raise("SentinelStore: create_run not stubbed")
  @impl true
  def start_run(_run), do: raise("SentinelStore: start_run not stubbed")
  @impl true
  def complete_run(_run, _metadata), do: raise("SentinelStore: complete_run not stubbed")
  @impl true
  def fail_run(_run, _error), do: raise("SentinelStore: fail_run not stubbed")
  @impl true
  def cancel_run(_run), do: raise("SentinelStore: cancel_run not stubbed")
  @impl true
  def log_step_start(_id, _mod, _in, _parent), do: raise("SentinelStore: log_step_start")
  @impl true
  def log_step_success(_step, _out, _info), do: raise("SentinelStore: log_step_success")
  @impl true
  def log_step_failure(_step, _error, _opts), do: raise("SentinelStore: log_step_failure")
  @impl true
  def log_section(_id, _title, _parent), do: raise("SentinelStore: log_section")
  @impl true
  def log_summary(_id, _type, _data, _parent), do: raise("SentinelStore: log_summary")
  @impl true
  def get_step(_id), do: raise("SentinelStore: get_step not stubbed")
end

defmodule ALLM.Pipeline.ExecutorStoreDispatchTest do
  @moduledoc """
  Proves `ALLM.Pipeline.Executor` reaches run/step persistence through
  `ALLM.Pipeline.Store.impl/0` — the configured seam — rather than through a
  module it names directly.

  ## Why this file exists

  Batch 1.C re-pointed `Executor`'s 16 persistence call sites off `PipelineRun`
  / `StepLog` and onto `store()`. Every other test drives that path with
  `Store.Ecto` configured, which is also the module the schema functions live
  on — so a `defp store, do: ALLM.Pipeline.Store.Ecto` that ignores the
  configuration entirely produces byte-identical behaviour and reddens nothing.
  Measured, not supposed: that was mutant **M7** of mutation pass `p1c` and it
  **survived the whole suite**. This file is the survivor's fix, and it is the
  only assertion in the tree that can distinguish "dispatches through the seam"
  from "happens to name the same module".

  The two calls `Executor` deliberately does NOT route through the seam —
  `PipelineRun.borrow/1` and `assume_ownership/1`, the completion-token
  operations — are covered by `pipeline_run_test.exs`; routing them through an
  adapter is how a third token mint point gets created (`ALLM.Pipeline.Store`,
  "Not callbacks").

  **Not `async: true`** — it rewrites `:amesbury_scraper` application env,
  which is global to the VM. No database: the stub answers, so nothing reaches
  a repo.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.{Executor, SentinelStore, Store}

  setup do
    original = Application.fetch_env(:amesbury_scraper, Store)
    Application.put_env(:amesbury_scraper, Store, impl: SentinelStore)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:amesbury_scraper, Store, value)
        :error -> Application.delete_env(:amesbury_scraper, Store)
      end
    end)

    :ok
  end

  test "a read through the seam reaches the CONFIGURED adapter, not Store.Ecto" do
    # `get_status/1` is the cheapest public entry point making two DISTINCT
    # Store calls (`get_run/1` then `pipeline_stats/1`). Both sentinels must
    # appear, so a half-re-pointed function is visible too.
    assert {:ok, status} = Executor.get_status("11111111-1111-1111-1111-111111111111")

    assert status.pipeline_run == :sentinel_run
    assert status.stats == %{sentinel: true}
  end

  test "the not-found branch also comes from the configured adapter" do
    # Positive control for the assertion above: the same adapter answers `nil`
    # for a different id, so `:sentinel_run` is evidence the ADAPTER was
    # consulted rather than evidence that any map came back.
    assert Executor.get_status("00000000-0000-0000-0000-000000000000") ==
             {:error, :not_found}
  end

  test "deleting the config restores the shipped default — Store.Ecto is not hardcoded" do
    Application.delete_env(:amesbury_scraper, Store)
    assert Store.impl() == Store.Ecto
  end
end
