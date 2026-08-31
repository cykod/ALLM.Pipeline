defmodule ALLM.Pipeline.LLMCallLogTest do
  @moduledoc """
  Tests for the per-step LLM-call collector. Each test owns its own process
  state (an `Agent` pid stashed in the test process's dictionary), so the suite
  is async-safe.
  """

  use ExUnit.Case, async: true

  alias ALLM.Pipeline.LLMCallLog

  describe "activate/0 → record/1 → drain/0" do
    test "drain returns recorded entries in chronological (call) order" do
      :ok = LLMCallLog.activate()
      :ok = LLMCallLog.record(%{seq: 0})
      :ok = LLMCallLog.record(%{seq: 1})

      assert LLMCallLog.drain() == [%{seq: 0}, %{seq: 1}]
    end
  end

  describe "drain/0 without activate" do
    test "returns [] when no collector was activated" do
      assert LLMCallLog.drain() == []
    end

    test "a second drain after a real drain returns [] (key deleted, agent stopped)" do
      :ok = LLMCallLog.activate()
      :ok = LLMCallLog.record(%{seq: 0})

      assert [%{seq: 0}] = LLMCallLog.drain()
      assert LLMCallLog.drain() == []
    end
  end

  describe "$callers fan-out" do
    test "drain in the parent captures an entry recorded from a child task" do
      :ok = LLMCallLog.activate()

      Task.async(fn -> LLMCallLog.record(%{seq: :from_child}) end)
      |> Task.await()

      assert LLMCallLog.drain() == [%{seq: :from_child}]
    end

    test "Task.async_stream workers all record into the parent collector" do
      :ok = LLMCallLog.activate()

      [1, 2, 3]
      |> Task.async_stream(fn n -> LLMCallLog.record(%{seq: n}) end)
      |> Stream.run()

      entries = LLMCallLog.drain()
      assert MapSet.new(entries) == MapSet.new([%{seq: 1}, %{seq: 2}, %{seq: 3}])
    end
  end

  describe "logging disabled" do
    setup do
      original = Application.get_env(:allm_pipeline, LLMCallLog, [])
      Application.put_env(:allm_pipeline, LLMCallLog, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:allm_pipeline, LLMCallLog, original) end)
      :ok
    end

    test "enabled?/0 reflects the flag" do
      refute LLMCallLog.enabled?()
    end

    test "activate stores no pid and record/drain are no-ops" do
      :ok = LLMCallLog.activate()
      refute Process.get(:llm_call_log)

      :ok = LLMCallLog.record(%{seq: 0})
      assert LLMCallLog.drain() == []
    end
  end
end
