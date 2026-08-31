defmodule ALLM.Pipeline.Lock.Advisory do
  @moduledoc """
  Postgres session-advisory-lock implementation of `ALLM.Pipeline.Lock`.

  **PRESERVED, NOT ACTIVE.** The active implementation is
  `ALLM.Pipeline.Lock.Noop` — see `ALLM.Pipeline.Lock` for
  why the lock was dropped and how to restore this one. This module is kept
  intact so the guarantee can be brought back deliberately rather than
  reconstructed from scratch. The serialization mapping it applies is no longer
  its own — batch 1.C moved it onto the host's `ALLM.Pipeline.Registry`
  (`lock_keys:`); the host-side membership guard is a consumer repo's
  registry-declared-values test, with its runner test pinning the derived
  lock keys.

  ## Mechanism

  Scheduled cron runs of the same pipeline can overlap if a previous run is
  slow (e.g. an ordinance pipeline still grinding through PDFs when the next
  weekly trigger fires). To prevent overlap on the shared Postgres database,
  each invocation acquires a session-scoped advisory lock keyed on the pipeline
  name.

    - We use `pg_try_advisory_lock(key)` (NOT the `_xact_` variant) so the lock
      survives across the many transactions inside a long pipeline.
    - The lock is held by a single dedicated connection, checked out via
      `c:Ecto.Repo.checkout/2`. `pg_try_advisory_lock` is bound to the connection that
      ran it; releasing on a different connection is silently a no-op, so we
      MUST run lock + work + unlock on the same checked-out connection. **This
      pinned connection is exactly the fragility that motivated the switch to
      `Noop`** — it sits idle during long LLM-bound steps and can be reaped.
    - The key is derived from the pipeline name (`:erlang.phash2/1`), stable
      within a process lifetime and small enough for Postgres's `bigint`.
      Different pipelines get different keys, so unrelated pipelines run
      concurrently. EXCEPTIONS collapse to one key via `canonical_lock_name/1`.
    - On contention `pg_try_advisory_lock` returns `false` and we return
      `{:error, :already_running}` immediately, without invoking the pipeline.
    - `try/after` releases the lock on every exit path, including raises. An
      advisory lock is also session-bound, so even a hard crash releases it
      when the connection dies.
  """

  @behaviour ALLM.Pipeline.Lock

  require Logger

  alias ALLM.Pipeline.{Config, Lock}

  @impl true
  @spec with_lock(Lock.name(), (-> result)) :: result | {:error, :already_running}
        when result: var
  def with_lock(name, fun) do
    lock_key = lock_key_for(name)

    repo().checkout(fn ->
      case acquire_lock(lock_key) do
        :ok ->
          Logger.info("Lock.Advisory: acquired advisory lock #{lock_key} for #{inspect(name)}")

          try do
            fun.()
          after
            release_lock(name, lock_key)
          end

        :busy ->
          Logger.warning(
            "Lock.Advisory: pipeline #{inspect(name)} is already running " <>
              "(advisory lock #{lock_key} held by another session)"
          )

          {:error, :already_running}
      end
    end)
  end

  @doc """
  The Postgres advisory-lock key a pipeline holds for the duration of a run.

  Pipelines that must serialize against each other collapse to the SAME key via
  `canonical_lock_name/1`. Exposed publicly so `runner_test.exs` can assert the
  real derivation rather than a hand-mirrored copy that could drift.
  """
  @spec lock_key_for(Lock.name()) :: non_neg_integer()
  def lock_key_for(name), do: :erlang.phash2(canonical_lock_name(name))

  @doc """
  Map pipelines that must serialize against each other to one canonical name.

  WHICH pipelines must serialize is host domain knowledge — it depends on what
  external session they share and which rows they replace — so the mapping is
  declared as `lock_keys:` on the host's `ALLM.Pipeline.Registry` (batch 1.C
  moved it off two hardcoded clauses here) and resolved at runtime by
  `ALLM.Pipeline.Config.lock_keys/0`. The per-pair reasons travel WITH the
  values, on that declaration.

  An undeclared pipeline maps to itself, so it gets its own key and runs
  concurrently with everything else.
  """
  @spec canonical_lock_name(Lock.name()) :: atom()
  def canonical_lock_name(name), do: Map.get(Config.lock_keys(), name, name)

  @spec acquire_lock(non_neg_integer()) :: :ok | :busy
  defp acquire_lock(lock_key) do
    %{rows: [[acquired?]]} =
      Ecto.Adapters.SQL.query!(repo(), "SELECT pg_try_advisory_lock($1)", [lock_key])

    if acquired?, do: :ok, else: :busy
  end

  @spec release_lock(Lock.name(), non_neg_integer()) :: :ok
  defp release_lock(name, lock_key) do
    case Ecto.Adapters.SQL.query(repo(), "SELECT pg_advisory_unlock($1)", [lock_key]) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        # The lock is session-scoped, so a failure here means the connection is
        # gone — at which point the lock is gone too. Swallow rather than
        # re-raise in `after` (which would mask the pipeline's return).
        Logger.warning(
          "Lock.Advisory: pg_advisory_unlock failed for #{inspect(name)} " <>
            "(lock_key=#{lock_key}, connection likely dead): #{inspect(reason)}"
        )

        :ok
    end
  end

  # The host's Ecto repo, resolved at RUNTIME. `allm_pipeline` deliberately
  # depends on no host app (see this repo's `mix.exs`), so this tree
  # cannot `alias` a host repo module — that is a compile error here, by design.
  @spec repo() :: module()
  defp repo, do: Config.repo()
end
