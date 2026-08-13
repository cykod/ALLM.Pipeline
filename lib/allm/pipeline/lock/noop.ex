defmodule ALLM.Pipeline.Lock.Noop do
  @moduledoc """
  No-op `ALLM.Pipeline.Lock` — the current default.

  Runs the pipeline directly with no cross-run serialization and, crucially,
  without a `Repo.checkout/2` pinning a connection for the run's duration (the
  failure mode described in `ALLM.Pipeline.Lock`). Two concurrent
  runs of the same pipeline are therefore possible again; if that becomes a
  real problem, restore a connection-free guard rather than
  `ALLM.Pipeline.Lock.Advisory`.
  """

  @behaviour ALLM.Pipeline.Lock

  @impl true
  @spec with_lock(ALLM.Pipeline.Lock.name(), (-> result)) :: result when result: var
  def with_lock(_name, fun), do: fun.()
end
