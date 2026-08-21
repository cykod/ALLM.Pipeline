defmodule ALLM.Pipeline.PipelineRun do
  @moduledoc """
  Represents a single execution of a pipeline.

  Groups related step logs together for tracking and resumption.
  Each pipeline run has a name, status, timing information, and
  can hold arbitrary metadata about the execution.

  ## Terminating a run is an ownership capability

  `create/3` mints an opaque **completion token** onto the returned struct's
  virtual `:completion_token` field. **All three terminal writers — `complete/2`,
  `fail/2` and `cancel/1` — refuse to run without it.** The set is deliberate:
  each writes `completed_at` plus a terminal status, so each inflicts the same
  damage (a run reported finished while it is still executing), and guarding
  only one would be the "rule enforced in more than one shape" trap root
  `CLAUDE.md` names. `owner?/1` is the single predicate all three consult.

  Three consequences, all deliberate:

    * The creator of a run is its owner, and terminating it is not something a
      caller can perform by merely holding a `%PipelineRun{}`. Taking over a run
      you did not create is possible, but only by NAME — see the mint section
      below.
    * A run **loaded from the database** (`get/1`, `get_with_steps/1`) carries
      no token, so a read path can never stamp a run terminal.
    * A **borrowed** run — an umbrella lending its run to an inner pipeline via
      the `:pipeline_run` opt — is passed through `borrow/1` at the receiving
      boundary (`Executor.borrowed_run/1`), which strips the token. An inner
      `complete/2` (or `fail/2`) is then a detectable `{:error, :not_run_owner}`
      instead of silently stamping the run terminal mid-loop and clobbering the
      umbrella's aggregate metadata with the last item's.

  As of 2026-08-13 the guard is **inert on every live path**: all 28
  `fail`/`fail_pipeline_run` and 17 `complete` sites hold a handle that came
  straight from `create/3`. It is a membership guard against the next call site,
  not a fix for a current one.

  ## One mint implementation, two deliberate entry points

  There is exactly **one** implementation of the mint (the private
  `mint_token/1`), reached by exactly two public functions:

    * `create/3` — the run's creator becomes its owner. The overwhelmingly
      common path.
    * `assume_ownership/1` — an explicit, greppable **take-over** of a
      token-less run, for a caller that legitimately means to finish a run it
      did not create (see `Executor.resume/2`, and the orphaned-run sweeper still
      open in `.work/HANDOFF.md`).

  Do not add a third: a re-mint hidden inside a function whose name does not say
  "I am taking ownership" (`resume/2` was the near miss — user decision,
  2026-08-13) turns the ownership story back into a convention. `borrow/1` is
  the inverse and the only other writer of the field.

  The token is data, not a lock: it detects the borrowed-run mistake, which is
  the one that actually happens. It does not (and cannot) detect an orchestrator
  process that dies without terminating the run at all — that leaves a run at
  `status = running`, and needs a watchdog or sweeper, not a token. That sweeper
  takes over stranded runs via `assume_ownership/1` rather than relying on
  `fail/2` being open by omission — which it no longer is.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  require Logger

  alias ALLM.Pipeline.Encodable
  alias ALLM.Pipeline.StepLog

  @type status :: :pending | :running | :success | :failed | :cancelled
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          status: status(),
          trigger: String.t() | nil,
          parent_run_id: Ecto.UUID.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          metadata: map(),
          completion_token: binary() | nil,
          step_logs: [StepLog.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pipeline_runs" do
    field(:name, :string)
    field(:status, Ecto.Enum, values: [:pending, :running, :success, :failed, :cancelled])
    # `trigger` records what fired the run ("cron:<name>" / "cli"); `parent_run_id`
    # links a sub-pipeline child run to the orchestrator that invoked it. Both are
    # first-class indexed columns so runs are SQL/GraphQL-filterable by trigger and
    # joinable by parent (Subphase 2).
    field(:trigger, :string)
    field(:parent_run_id, :binary_id)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    # Never persisted and never cast: minted onto the struct handed back by
    # `create/3` (or by an explicit `assume_ownership/1`), stripped by
    # `borrow/1`. Those three are the only writers. See the moduledoc.
    field(:completion_token, :binary, virtual: true)

    has_many(:step_logs, StepLog)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Create a changeset for a pipeline run.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pipeline_run, attrs) do
    pipeline_run
    |> cast(attrs, [
      :name,
      :status,
      :trigger,
      :parent_run_id,
      :started_at,
      :completed_at,
      :metadata
    ])
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, [:pending, :running, :success, :failed, :cancelled])
  end

  @doc """
  Create a new pipeline run with pending status.

  `attrs` carries top-level COLUMN values (`:trigger`, `:parent_run_id`) — these
  are plain scalars set directly on the changeset, NOT routed through the
  `metadata` JSONB (so they bypass `Encodable.encode/1` and stay
  SQL/GraphQL-filterable).

  This is the primary of the completion token's **two** mint entry points (see
  the moduledoc — the other is the explicit `assume_ownership/1`): the returned
  struct is the only handle that can `complete/2` this run until someone
  deliberately takes it over.
  """
  @spec create(String.t(), map(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(name, metadata \\ %{}, attrs \\ []) do
    base = %{
      name: name,
      status: :pending,
      metadata: Encodable.encode(metadata)
    }

    case %__MODULE__{}
         |> changeset(Map.merge(base, Map.new(attrs)))
         |> repo().insert() do
      {:ok, pipeline_run} ->
        {:ok, mint_token(pipeline_run)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Take ownership of a token-less run: returns the same run carrying a fresh
  completion token, so the caller may terminate it.

  The **explicit** counterpart to `create/3`'s implicit mint, and the sanctioned
  way to finish a run you did not create. Two callers need it:

    * a driver of `Executor.resume/2`, whose handle is loaded from the database
      and therefore never an owner;
    * the orphaned-run sweeper (still open in `.work/HANDOFF.md`), which cannot
      use `fail/2` as an escape hatch now that `fail/2` and `cancel/1` are
      ownership-guarded too.

  Named rather than inlined on purpose: a re-mint is a real transfer of the
  right to stamp a run terminal, so it should be greppable and appear in a diff.
  **Do not call it to silence `{:error, :not_run_owner}`** — on a *borrowed*
  umbrella handle it re-creates precisely the mid-loop clobber the token exists
  to detect. Ask first whether this caller really is the one that should finish
  the run.
  """
  @spec assume_ownership(t()) :: t()
  def assume_ownership(%__MODULE__{} = pipeline_run), do: mint_token(pipeline_run)

  # The single mint implementation behind both entry points (see the moduledoc).
  # 16 bytes is a PRESENCE check, not a secret: the token detects a handle that
  # should not terminate the run — it does not authenticate one.
  @spec mint_token(t()) :: t()
  defp mint_token(%__MODULE__{} = pipeline_run),
    do: %{pipeline_run | completion_token: :crypto.strong_rand_bytes(16)}

  @doc """
  Return a non-owning handle on `pipeline_run` — the same run, minus the
  completion token.

  Called at the borrowed-run boundary (`Executor.borrowed_run/1`) so an inner
  pipeline handed an umbrella's run can log steps under it but cannot complete
  it. See the moduledoc.
  """
  @spec borrow(t()) :: t()
  def borrow(%__MODULE__{} = pipeline_run), do: %{pipeline_run | completion_token: nil}

  @doc """
  Whether this handle on the run is the one allowed to `complete/2` it.
  """
  @spec owner?(t()) :: boolean()
  def owner?(%__MODULE__{completion_token: token}), do: is_binary(token)

  @doc """
  Mark a pipeline run as running with a start timestamp.
  """
  @spec start(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def start(%__MODULE__{} = pipeline_run) do
    pipeline_run
    |> changeset(%{
      status: :running,
      started_at: DateTime.utc_now()
    })
    |> repo().update()
  end

  @doc """
  Mark a pipeline run as successfully completed.

  Requires an **owning** handle (see the moduledoc). A handle with no completion
  token — a borrowed umbrella run, or a run re-loaded from the database —
  returns `{:error, :not_run_owner}` and writes nothing.

  It logs at `:error` as well as returning, because almost every call site today
  discards this function's return value (`PipelineRun.complete(run, stats)` as a
  statement); the log line, not the tuple, is what surfaces the mistake in a
  real run.

  Deliberately NOT a raise: the borrowed-run idiom is live in production
  (`VideoSummaryPipeline` lends its umbrella run to `MeetingSummaryPipeline`),
  and turning a wrong-but-working path into a crash would trade a metadata bug
  for an outage. Deliberately not a silent no-op either: that is the
  "first-write-wins" idempotency fix the design doc rejects (§2.4), which only
  swaps which pipeline's metadata is lost.
  """
  @spec complete(t(), map()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}
  def complete(pipeline_run, result_metadata \\ %{})

  def complete(%__MODULE__{completion_token: nil} = pipeline_run, _result_metadata),
    do: refuse(pipeline_run, "complete")

  def complete(%__MODULE__{} = pipeline_run, result_metadata) do
    merged = Map.merge(pipeline_run.metadata || %{}, Encodable.encode(result_metadata))

    pipeline_run
    |> changeset(%{
      status: :success,
      completed_at: DateTime.utc_now(),
      metadata: merged
    })
    |> repo().update()
  end

  @doc """
  Mark a pipeline run as failed with error information.

  Requires an **owning** handle, exactly as `complete/2` does — `fail/2` writes
  the same `completed_at` + terminal status, so a borrowed or re-loaded handle
  must not reach it either. Returns `{:error, :not_run_owner}` and writes
  nothing for a handle with no completion token.

  The error is normalized by `normalize_error/1` and then passed through
  `Encodable.encode/1` like every other metadata write on this schema — an
  exception message echoing OCR'd or LLM-produced text can carry a NUL byte,
  which fails the jsonb write with `ERROR 22P05` and loses the failure record
  along with the run.
  """
  @spec fail(t(), term()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}
  def fail(%__MODULE__{completion_token: nil} = pipeline_run, _error),
    do: refuse(pipeline_run, "fail")

  def fail(%__MODULE__{} = pipeline_run, error) do
    merged =
      Map.merge(
        pipeline_run.metadata || %{},
        Encodable.encode(%{"error" => normalize_error(error)})
      )

    pipeline_run
    |> changeset(%{
      status: :failed,
      completed_at: DateTime.utc_now(),
      metadata: merged
    })
    |> repo().update()
  end

  @doc """
  Mark a pipeline run as cancelled.

  Requires an **owning** handle for the same reason `complete/2` and `fail/2`
  do — see the moduledoc.
  """
  @spec cancel(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()} | {:error, :not_run_owner}
  def cancel(%__MODULE__{completion_token: nil} = pipeline_run),
    do: refuse(pipeline_run, "cancel")

  def cancel(%__MODULE__{} = pipeline_run) do
    pipeline_run
    |> changeset(%{
      status: :cancelled,
      completed_at: DateTime.utc_now()
    })
    |> repo().update()
  end

  @doc """
  Get a pipeline run by ID.
  """
  @spec get(Ecto.UUID.t()) :: t() | nil
  def get(id), do: repo().get(__MODULE__, id)

  @doc """
  Get a pipeline run by ID with step logs preloaded.
  """
  @spec get_with_steps(Ecto.UUID.t()) :: t() | nil
  def get_with_steps(id) do
    from(p in __MODULE__,
      where: p.id == ^id,
      preload: [step_logs: ^from(s in StepLog, order_by: [asc: s.started_at])]
    )
    |> repo().one()
  end

  @doc """
  List pipeline runs with optional filters.

  ## Options

  - `:status` / `:trigger` - exact match
  - `:name` - **exact** match on the pipeline slug (`"video_summary"`). Callers
    that assert on a specific pipeline rely on this NOT matching siblings such as
    `"video_summary_single"`.
  - `:name_contains` - case-insensitive **substring** match, for the review UI's
    free-text search box (`"video"` matches `video_listing`, `video_summary`, …)
  - `:limit` / `:offset` - pagination

  Ordered newest-first. `inserted_at` alone is not a total order (a batch can
  stamp several runs in the same microsecond), so `id` breaks ties — without it
  a row can repeat on one page and vanish from the next.
  """
  @spec list(keyword()) :: [t()]
  def list(opts \\ []) do
    query =
      from(p in __MODULE__,
        order_by: [desc: p.inserted_at, desc: p.id]
      )
      |> apply_filters(opts)

    query =
      if opts[:limit] do
        from(p in query, limit: ^opts[:limit])
      else
        query
      end

    query =
      if opts[:offset] do
        from(p in query, offset: ^opts[:offset])
      else
        query
      end

    repo().all(query)
  end

  @doc """
  Count pipeline runs matching the same filters `list/1` accepts (`:limit` and
  `:offset` are ignored) — the total a paginated UI needs to size its pager.
  """
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    from(p in __MODULE__, select: count(p.id))
    |> apply_filters(opts)
    |> repo().one()
  end

  # The filter clauses shared by `list/1` and `count/1`, so a page's rows and its
  # total can never disagree about what "matching" means.
  defp apply_filters(query, opts) do
    query
    |> filter_eq(:status, opts[:status])
    |> filter_eq(:name, opts[:name])
    |> filter_eq(:trigger, opts[:trigger])
    |> filter_name_contains(opts[:name_contains])
  end

  defp filter_eq(query, _field, nil), do: query
  defp filter_eq(query, :status, value), do: from(p in query, where: p.status == ^value)
  defp filter_eq(query, :name, value), do: from(p in query, where: p.name == ^value)
  defp filter_eq(query, :trigger, value), do: from(p in query, where: p.trigger == ^value)

  defp filter_name_contains(query, nil), do: query
  defp filter_name_contains(query, ""), do: query

  defp filter_name_contains(query, term) do
    from(p in query, where: ilike(p.name, ^"%#{escape_like(term)}%"))
  end

  # `%` and `_` are LIKE wildcards, and `_` is common in pipeline slugs — an
  # unescaped `video_listing` would match `videoXlisting`. Escape the escape
  # character first, or it double-escapes the wildcards added after it.
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # The single refusal for all three terminal writers. Logged at `:error` as well
  # as returned because almost every call site discards the return value, so the
  # log line — not the tuple — is what surfaces the mistake in a real run.
  #
  # The message deliberately does NOT accuse an inner pipeline: the guard fires
  # for three distinct provenances (borrowed, re-loaded via `get/1`, resumed via
  # `Executor.resume/2`), and only the first involves a borrowing bug. Naming the
  # cause as "carries no completion token" plus the three ways that happens sends
  # the operator to the right place for all three.
  @spec refuse(t(), String.t()) :: {:error, :not_run_owner}
  defp refuse(pipeline_run, action) do
    Logger.error(
      "Refusing to #{action} pipeline run #{pipeline_run.id} (#{pipeline_run.name}): " <>
        "this handle does not own the run — it carries no completion token, so it was " <>
        "borrowed from an umbrella, re-loaded from the database, or resumed. Only a " <>
        "handle from PipelineRun.create/3 — or one deliberately taken over via " <>
        "PipelineRun.assume_ownership/1 — may write a terminal status."
    )

    {:error, :not_run_owner}
  end

  # Normalize error for storage (string keys for JSON compatibility)
  defp normalize_error(%{__exception__: true} = e) do
    %{"type" => to_string(e.__struct__), "message" => Exception.message(e)}
  end

  defp normalize_error(error) when is_binary(error), do: %{"message" => error}

  # `Encodable.render/1`, not bare `inspect/1`: this fallback catches every
  # non-exception, non-binary reason, which since Phase 4.4 includes EXITS —
  # `Lifecycle.guard/2` catches `kind, reason` and routes the tuple here, where
  # a hand-written orchestrator's bare `rescue` used to let an exit escape
  # unpersisted. An exit reason such as
  # `{:timeout, {GenServer, :call, [pid, message, 5000]}}` inlines the call's
  # message term, which is exactly where a bearer token would sit; `render/1`
  # bounds both collection depth and binary length. See its moduledoc for why
  # bounding beats erasing here (the reason IS the diagnostic), and note it is
  # NOT `Executor.render_shape/1`, which keeps type and key names only.
  # NOTE the deliberate divergence from `StepLog`'s same-named private sibling
  # (`step_log.ex`), which still uses bare `inspect/1`. That one is NOT bounded
  # on purpose: its `inspect/1` is what omits a changeset's `params` via
  # `Ecto.Changeset`'s own `Inspect` impl (see `StepLog`'s moduledoc), and
  # `render/1`'s `limit: 5` would truncate a changeset's `errors` list in the
  # column operators read to diagnose a failed step. Tracked as an open
  # `.work/HANDOFF.md` row rather than changed by the 4.4 fix pass.
  defp normalize_error(error), do: %{"message" => Encodable.render(error)}

  # The host's Ecto repo, resolved at RUNTIME. `allm_pipeline` deliberately
  # depends on no umbrella app (see `apps/allm_pipeline/mix.exs`), so this tree
  # cannot `alias Amesbury.Repo` — that is a compile error here, by design.
  @spec repo() :: module()
  defp repo, do: ALLM.Pipeline.Config.repo()
end
