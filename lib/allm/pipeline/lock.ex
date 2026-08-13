defmodule ALLM.Pipeline.Lock do
  @moduledoc """
  Serialization guard for pipeline runs — the abstraction behind "don't let two
  runs of the same pipeline overlap on the shared database".

  ## Current state: NO-OP

  The active implementation is `ALLM.Pipeline.Lock.Noop`, which runs
  the pipeline directly with **no** locking. The Postgres
  session-advisory-lock implementation is preserved in
  `ALLM.Pipeline.Lock.Advisory` and can be restored by
  configuring:

      config :amesbury_scraper, ALLM.Pipeline.Lock,
        impl: ALLM.Pipeline.Lock.Advisory

  ## Why the advisory lock was dropped

  The advisory lock is *session*-scoped, so it required pinning ONE Postgres
  connection (via `Repo.checkout/2`) for the ENTIRE run. During long LLM-bound
  steps (e.g. `NarrativeGenerator`'s ~40s of OpenAI calls) that pinned
  connection sits idle at the protocol level, and a checked-out connection is
  NOT kept warm by DBConnection's idle ping — so if anything reaps the idle
  socket (an RDS `idle_session_timeout`, a network idle timeout) the run's
  lock-holding connection dies mid-run, killing the run with a
  `DBConnection.ConnectionError` at the next query.

  Dropping the lock removes the checkout, and with it that entire failure mode.
  The overlap guard it provided is, for the pipelines that get their own key,
  mostly a cost / duplicate-work guard (`rich_summary`) rather than a
  correctness invariant; the genuinely correctness-critical cases
  (`poi_thumbnails`/`video_summary` full-replace-embed clobber,
  `project`/`project_refresh` shared OpenGov session) can be reintroduced in a
  form that does NOT hold a connection for the run's duration — e.g. a lease
  row claimed with short queries — if overlap becomes a real problem. The
  serialization mapping (which names must share a key) is preserved on
  `Advisory` so it isn't lost.
  """

  @typedoc "A pipeline name, e.g. `:rich_summary`."
  @type name :: atom()

  @doc """
  Run `fun` under whatever serialization the configured implementation
  provides, returning `fun`'s result.

  An implementation MAY return `{:error, :already_running}` instead of running
  `fun` when a concurrent run holds the guard. `Noop` never does — it always
  runs `fun`.
  """
  @callback with_lock(name(), (-> result)) :: result | {:error, :already_running}
            when result: var

  @doc """
  Dispatch to the configured `ALLM.Pipeline.Lock` implementation
  (default `ALLM.Pipeline.Lock.Noop`).
  """
  @spec with_lock(name(), (-> result)) :: result | {:error, :already_running} when result: var
  def with_lock(name, fun) when is_atom(name) and is_function(fun, 0) do
    impl().with_lock(name, fun)
  end

  @doc "The currently-configured lock implementation module."
  @spec impl() :: module()
  def impl do
    Application.get_env(:amesbury_scraper, __MODULE__, [])
    |> Keyword.get(:impl, ALLM.Pipeline.Lock.Noop)
  end
end
