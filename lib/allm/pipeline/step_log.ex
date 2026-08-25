defmodule ALLM.Pipeline.StepLog do
  @moduledoc """
  Persists step execution logs to PostgreSQL for observability and lineage tracking.

  Key design decisions:
  - `pipeline_run_id` stored directly for efficient querying (no recursive joins needed)
  - `input_step_id` enables lineage tree reconstruction when needed
  - Timing fields capture execution performance metrics
  - Input/output schemas stored as JSONB for debugging and replay

  ## Two-layer serialization

  `input_data` / `output_data` are produced by `serialize_struct/2`, which keeps
  heavy bodies out of Postgres using **two** layers:

  - **Layer 1 — per-field flags.** A struct whose module exports
    `__allm_schema__/1` (i.e. one built with `ALLM.Pipeline.Schema`) contributes
    `__allm_schema__(:dropped)` — `log: false` or `artifact: true` — and
    `__allm_schema__(:redacted)`.
  - **Layer 2 — `@fallback_drop`,** a package-level list of four *generic* field
    names that applies to **every** struct, DSL or not. It is what covers plain
    `defstruct`s and live Ecto structs reached through recursion, which carry no
    flags at all.

  The two are **additive**: the drop set is
  `:dropped ∪ (@fallback_drop − :kept)`. Flags do not replace the fallback — an
  unflagged `field :content, …` on a DSL struct is still dropped, which is the
  point (`AmesburyScraper.Digest.DigestRenderStep.Output` relies on it). The one
  escape in the other direction is an explicit `log: true`.

  ⚠️ The predicate is `__allm_schema__/1`, **never** `__schema__/1`: every
  `Ecto.Schema` module exports the latter, `__schema__(:fields)` *succeeds* with
  a colliding shape, and `__schema__(:dropped)` raises `FunctionClauseError` —
  on this un-rescued write path. See `ALLM.Pipeline.Schema`'s moduledoc.

  Recursion carries a depth budget of 16 levels and **truncates** rather than
  raising; see `@max_depth`.

  ## An `%Ecto.Changeset{}` reaching the serializer flattens SILENTLY

  `Ecto.Changeset` is the one declared divergence from `ALLM.Pipeline.Encodable`'s
  leaf rules (`Encodable` renders it as `%{"changeset_errors" => …}`; this module
  treats it as an ordinary struct), and subphase 2.2's tuple clause turned that
  divergence from a loud failure into a quiet write. A changeset now flattens to
  all **fifteen** `defstruct` keys and persists `params`, `data`, `types`,
  `changes` and `errors` **in full** — so a changeset built from user or LLM
  input writes those raw params into `input_data` / `output_data`, where
  `redact:` cannot reach them (no field declares a changeset type, so layer 1 has
  no flags to read). This is the same "loud failure turned QUIET" shape
  `ALLM.Pipeline.Encodable`'s moduledoc documents for its own `is_struct`
  widening, mirrored here because `StepLog` is the path that reaches a row.

  The quiet write is **not** total, which is the trap: measured 2026-08-14, a
  changeset that has been through `Ecto.Changeset.prepare_changes/2` carries
  anonymous functions in `:prepare`, which reach `Jason` unchanged and still
  raise `Protocol.UndefinedError` on the un-rescued `log_start/4` path. So the
  same type both writes and raises depending on how it was built.

  **No field DECLARES a changeset type today**, and that is the exact scope of
  the claim — the sweep is type-declaration-based while the hazard is not.
  Re-derive it NUL-safely and across both extensions (2026-08-14):

      python3 scripts/refsweep.py 'field\\(.*Changeset' apps scripts steering \\
        --include '*.ex' --include '*.exs' --format hits

  → **1 hit, and it is this moduledoc**, at the line just below quoting the
  superseded command `grep -rna "field(.*Changeset" apps/ --include=*.ex` (which
  could not see `.exs` at all). Real declarations: **zero**. Read the expected
  count as "every hit is prose", not as a number — this paragraph supplies its
  own match, so a bare `→ 1` would stop meaning anything the moment someone
  rewords it.

  What no such sweep can see is a field declared `term()`, `map()` or
  `[map()]` that *holds* a changeset at runtime — which is exactly how one would
  arrive, since Step Outputs routinely carry `term()`-typed result collections.
  That half is not closed by any grep. It was closed once, by tracing, and the
  trace is **not re-derivable from this file**: subphase 2.3's security review
  (`.work/security-reviews/2026-08-14-allm-p2c.md`, Informational 4) walked the
  five loaders and found a changeset surfacing only as a failure return (→
  `normalize_error/1`, which since Phase 5.10 renders it params-free via
  `Encodable.encode/1`'s `changeset_errors` leaf) and via `Encodable.encode/1`
  (→ `changeset_errors` only),
  so none reaches this serializer. That is a **dated observation about the
  loaders**, not a property of this module, and a new `term()`-typed Step Output
  can falsify it without touching anything here.

  Which is why the standing fix is not a wider sweep: give `serialize_struct/2`
  an `%Ecto.Changeset{}` clause mirroring `Encodable`'s `changeset_errors` leaf.
  It closes the silent write, the `prepare_changes/2` raise, and the declared
  divergence at once, and it needs no dated evidence. Tracked as an open item in
  `.work/HANDOFF.md`.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias ALLM.Pipeline.Encodable
  alias ALLM.Pipeline.PipelineRun
  alias ALLM.Pipeline.Text

  @type status :: :pending | :running | :success | :failed | :skipped
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          step_type: String.t() | nil,
          status: status(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          queue_time_ms: non_neg_integer() | nil,
          input_schema: String.t() | nil,
          input_data: map() | nil,
          output_schema: String.t() | nil,
          output_data: map() | nil,
          artifact_url: String.t() | nil,
          artifact_size_bytes: non_neg_integer() | nil,
          artifact_checksum: String.t() | nil,
          llm_artifact_url: String.t() | nil,
          llm_artifact_size_bytes: non_neg_integer() | nil,
          llm_artifact_checksum: String.t() | nil,
          llm_call_count: non_neg_integer() | nil,
          llm_total_tokens: non_neg_integer() | nil,
          error: map() | nil,
          retry_count: non_neg_integer(),
          pipeline_run_id: Ecto.UUID.t() | nil,
          pipeline_run: PipelineRun.t() | Ecto.Association.NotLoaded.t(),
          input_step_id: Ecto.UUID.t() | nil,
          input_step: t() | Ecto.Association.NotLoaded.t() | nil,
          downstream_steps: [t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "step_logs" do
    # Step identification
    field(:step_type, :string)

    # Status tracking
    field(:status, Ecto.Enum, values: [:pending, :running, :success, :failed, :skipped])

    # Timing data
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:duration_ms, :integer)
    field(:queue_time_ms, :integer)

    # Typed I/O (serialized schemas)
    field(:input_schema, :string)
    field(:input_data, :map)
    field(:output_schema, :string)
    field(:output_data, :map)

    # Artifact reference
    field(:artifact_url, :string)
    field(:artifact_size_bytes, :integer)
    field(:artifact_checksum, :string)

    # LLM-call artifact reference (the full prompts/responses for every LLM
    # call this step made; lands in DynamoDB keyed by "<step_log.id>:llm").
    field(:llm_artifact_url, :string)
    field(:llm_artifact_size_bytes, :integer)
    field(:llm_artifact_checksum, :string)
    field(:llm_call_count, :integer)
    field(:llm_total_tokens, :integer)

    # Error tracking
    field(:error, :map)
    field(:retry_count, :integer, default: 0)

    # Relationships
    belongs_to(:pipeline_run, PipelineRun)
    belongs_to(:input_step, __MODULE__, foreign_key: :input_step_id)
    has_many(:downstream_steps, __MODULE__, foreign_key: :input_step_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Create a changeset for a step log.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(step_log, attrs) do
    step_log
    |> cast(attrs, [
      :step_type,
      :status,
      :started_at,
      :completed_at,
      :duration_ms,
      :queue_time_ms,
      :input_schema,
      :input_data,
      :output_schema,
      :output_data,
      :artifact_url,
      :artifact_size_bytes,
      :artifact_checksum,
      :llm_artifact_url,
      :llm_artifact_size_bytes,
      :llm_artifact_checksum,
      :llm_call_count,
      :llm_total_tokens,
      :error,
      :retry_count,
      :pipeline_run_id,
      :input_step_id
    ])
    |> validate_required([:step_type, :status, :pipeline_run_id])
    |> foreign_key_constraint(:pipeline_run_id)
    |> foreign_key_constraint(:input_step_id)
  end

  @doc """
  Log the start of a step execution.
  """
  @spec log_start(Ecto.UUID.t(), module(), struct(), Ecto.UUID.t() | nil) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def log_start(pipeline_run_id, step_module, input_struct, input_step_id \\ nil) do
    %__MODULE__{}
    |> changeset(%{
      pipeline_run_id: pipeline_run_id,
      step_type: to_string(step_module.step_type()),
      status: :running,
      started_at: DateTime.utc_now(),
      input_step_id: input_step_id,
      input_schema: to_string(step_module.input_schema()),
      input_data: serialize_struct(input_struct)
    })
    |> repo().insert()
  end

  @doc """
  Log successful completion with output and artifact.
  """
  @spec log_success(t(), struct(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def log_success(step_log, output_struct, artifact_info \\ %{}) do
    completed_at = DateTime.utc_now()
    duration_ms = DateTime.diff(completed_at, step_log.started_at, :millisecond)

    base_attrs = %{
      status: :success,
      completed_at: completed_at,
      duration_ms: duration_ms,
      output_schema: to_string(output_struct.__struct__),
      output_data: serialize_struct(output_struct),
      artifact_url: artifact_info[:url],
      artifact_size_bytes: artifact_info[:size_bytes],
      artifact_checksum: artifact_info[:checksum]
    }

    step_log
    |> changeset(merge_llm_info(base_attrs, artifact_info))
    |> repo().update()
  end

  @doc """
  Log step failure with error details.
  """
  @spec log_failure(t(), term(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def log_failure(step_log, error, opts \\ []) do
    completed_at = DateTime.utc_now()
    duration_ms = DateTime.diff(completed_at, step_log.started_at, :millisecond)

    base_attrs = %{
      status: :failed,
      completed_at: completed_at,
      duration_ms: duration_ms,
      error: normalize_error(error),
      retry_count: step_log.retry_count + if(opts[:is_retry], do: 1, else: 0)
    }

    step_log
    |> changeset(merge_llm_info(base_attrs, opts[:llm_info] || %{}))
    |> repo().update()
  end

  # Fold the LLM-call artifact columns into a changeset's attrs, dropping nil
  # keys so a step that made no LLM calls writes nothing to these columns.
  # The keys come from `Executor.drain_and_store_llm/2` (atom-keyed): a successful
  # store carries all five; a store failure carries only the cheap counts; a
  # zero-LLM step carries `%{}`.
  @spec merge_llm_info(map(), map()) :: map()
  defp merge_llm_info(attrs, llm_info) do
    llm_attrs =
      llm_info
      |> Map.take([
        :llm_artifact_url,
        :llm_artifact_size_bytes,
        :llm_artifact_checksum,
        :llm_call_count,
        :llm_total_tokens
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    Map.merge(attrs, llm_attrs)
  end

  @doc """
  Log an already-started step as skipped (UPDATE path).

  Takes a `%StepLog{}` whose `started_at` is set and closes it `:skipped`,
  computing `duration_ms` from that timestamp. This is NOT the path a
  `*ProcessingDecision` skip takes — that decision happens *before* any step log
  exists (no struct, no `started_at`), so it uses `create_skipped/4` instead.
  """
  @spec log_skipped(t(), String.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def log_skipped(step_log, reason) do
    completed_at = DateTime.utc_now()
    duration_ms = DateTime.diff(completed_at, step_log.started_at, :millisecond)

    step_log
    |> changeset(%{
      status: :skipped,
      completed_at: completed_at,
      duration_ms: duration_ms,
      error: %{reason: reason}
    })
    |> repo().update()
  end

  @doc """
  Create a zero-duration `:skipped` step from scratch — the visible record of a
  gate decision that declined to process an item.

  Unlike `log_skipped/2` (which UPDATES a row a step already started), this is a
  CREATE path: a `*ProcessingDecision` skip fires before any step log exists, so
  there is no `%StepLog{}` and no `started_at` to diff against — `started_at` and
  `completed_at` are both `now`, giving `duration_ms: 0`. Promoted to a `Store`
  callback and wired to the three `ProcessingDecision` skip branches in Phase 7.4
  so a skip is a queryable `:skipped` row (counted by `get_pipeline_stats/1`)
  rather than the invisible `{:skipped, …}` return it was through Phase 6.

  `reason` is an arbitrary term (the pipelines pass a `{scraper_identifier,
  reason}` payload). It is made jsonb-safe by `Encodable.encode/1` — which
  flattens the tuple to a list and scrubs binaries — and stored under
  `output_data["reason"]` (the audit-artifact column, as `log_summary/4` uses,
  NOT `error`: a skip is a benign decision, not a failure). `input_step_id`
  should be the same lineage parent the processed step would have carried, so the
  skip appears in `build_lineage_tree/1` at the position the work would occupy.
  """
  @spec create_skipped(Ecto.UUID.t(), String.t(), term(), Ecto.UUID.t() | nil) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create_skipped(pipeline_run_id, step_type, reason, input_step_id \\ nil) do
    now = DateTime.utc_now()

    %__MODULE__{}
    |> changeset(%{
      pipeline_run_id: pipeline_run_id,
      step_type: step_type,
      status: :skipped,
      started_at: now,
      completed_at: now,
      duration_ms: 0,
      input_step_id: input_step_id,
      output_data: %{"reason" => Encodable.encode(reason)}
    })
    |> repo().insert()
  end

  @doc """
  Log a section marker for visual grouping in the admin UI.

  Creates a step_log with step_type "section" that serves as a visual divider
  in the pipeline review interface. Sections are excluded from pipeline stats.

  The title is `ALLM.Pipeline.Text.scrub/1`-ed. It is the one field on this row
  that comes from OUTSIDE — the DSL's `section:` hook derives it from a scraped
  or OCR'd item — and a NUL byte or an invalid UTF-8 sequence in it fails the
  insert with Postgres `22P05`, aborting a fan-out mid-run for a value that is
  only ever displayed. Same treatment `ALLM.Pipeline.Encodable.encode/1` gives
  run metadata.
  """
  @spec log_section(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def log_section(pipeline_run_id, title, input_step_id \\ nil) do
    now = DateTime.utc_now()

    %__MODULE__{}
    |> changeset(%{
      pipeline_run_id: pipeline_run_id,
      step_type: "section",
      status: :success,
      started_at: now,
      completed_at: now,
      duration_ms: 0,
      input_step_id: input_step_id,
      input_data: %{"title" => Text.scrub(title)}
    })
    |> repo().insert()
  end

  @doc """
  Create a successful, zero-duration step that carries structured `output_data`.

  Unlike `log_section/3` (which only holds a title for visual grouping), this
  records a real audit artifact — e.g. the video↔meeting match-decision log —
  that the pipeline-review UI renders. `output_data` must be JSON-serializable.
  """
  @spec log_summary(Ecto.UUID.t(), String.t(), map(), Ecto.UUID.t() | nil) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def log_summary(pipeline_run_id, step_type, output_data, input_step_id \\ nil) do
    now = DateTime.utc_now()

    %__MODULE__{}
    |> changeset(%{
      pipeline_run_id: pipeline_run_id,
      step_type: step_type,
      status: :success,
      started_at: now,
      completed_at: now,
      duration_ms: 0,
      input_step_id: input_step_id,
      output_data: output_data
    })
    |> repo().insert()
  end

  @doc """
  Get a step log by ID.
  """
  @spec get(Ecto.UUID.t()) :: t() | nil
  def get(id), do: repo().get(__MODULE__, id)

  @doc """
  Get all steps for a pipeline run (efficient direct query via pipeline_run_id).
  """
  @spec get_pipeline_steps(Ecto.UUID.t()) :: [t()]
  def get_pipeline_steps(pipeline_run_id) do
    from(s in __MODULE__,
      where: s.pipeline_run_id == ^pipeline_run_id,
      order_by: [asc: s.started_at]
    )
    |> repo().all()
  end

  @doc """
  Per-`step_type` row counts for a run, as `%{step_type => %{status => count}}`.

  The aggregate form of "how many rows of type X, and how many of those
  succeeded". Use this — not `get_pipeline_steps/1` + `Enum.group_by/2` — when
  the answer is a COUNT: `get_pipeline_steps/1` is `select *` and materialises
  every row's `input_data`/`output_data` jsonb, which is a few kilobytes for a
  31-item run and **megabytes** for a large one (the biggest
  `meeting_agenda_scrape` runs in dev are ~2600 rows / ~5 MB, measured
  2026-08-21). A `use ALLM.Pipeline` pipeline folding run-level counters in a
  `stage :tally` is the canonical caller.

  Sections are INCLUDED (unlike `get_pipeline_stats/1`, which excludes them):
  callers key on a specific `Step.step_type()`, so a `"section"` bucket is
  simply never read, and excluding it here would make the function unusable for
  anyone who wanted to count them.
  """
  @spec count_by_step_type(Ecto.UUID.t()) :: %{String.t() => %{atom() => non_neg_integer()}}
  def count_by_step_type(pipeline_run_id) do
    from(s in __MODULE__,
      where: s.pipeline_run_id == ^pipeline_run_id,
      group_by: [s.step_type, s.status],
      select: {s.step_type, s.status, count(s.id)}
    )
    |> repo().all()
    |> Enum.reduce(%{}, fn {step_type, status, count}, acc ->
      Map.update(acc, step_type, %{status => count}, &Map.put(&1, status, count))
    end)
  end

  @doc """
  Get pipeline statistics.
  """
  @spec get_pipeline_stats(Ecto.UUID.t()) :: map()
  def get_pipeline_stats(pipeline_run_id) do
    from(s in __MODULE__,
      where: s.pipeline_run_id == ^pipeline_run_id and s.step_type != "section",
      select: %{
        total_steps: count(s.id),
        successful: count(fragment("CASE WHEN status = 'success' THEN 1 END")),
        failed: count(fragment("CASE WHEN status = 'failed' THEN 1 END")),
        skipped: count(fragment("CASE WHEN status = 'skipped' THEN 1 END")),
        total_duration_ms: sum(s.duration_ms),
        avg_duration_ms: avg(s.duration_ms)
      }
    )
    |> repo().one()
  end

  @doc """
  Build lineage tree from step logs using recursive CTE query.

  Returns steps from the root (oldest ancestor) to the given step.
  """
  @spec build_lineage_tree(Ecto.UUID.t()) :: {:ok, [map()]} | {:error, term()}
  def build_lineage_tree(step_id) do
    query = """
    WITH RECURSIVE lineage AS (
      -- Base case: the starting step
      SELECT id, input_step_id, step_type, status, artifact_url, 0 as depth
      FROM step_logs
      WHERE id = $1

      UNION ALL

      -- Recursive case: parent steps
      SELECT s.id, s.input_step_id, s.step_type, s.status, s.artifact_url, l.depth + 1
      FROM step_logs s
      INNER JOIN lineage l ON s.id = l.input_step_id
    )
    SELECT id, input_step_id, step_type, status, artifact_url, depth
    FROM lineage
    ORDER BY depth DESC
    """

    case repo().query(query, [Ecto.UUID.dump!(step_id)]) do
      {:ok, %{rows: rows, columns: columns}} ->
        results =
          Enum.map(rows, fn row ->
            columns
            |> Enum.zip(row)
            |> Enum.into(%{}, fn
              {"id", value} -> {:id, Ecto.UUID.load!(value)}
              {"input_step_id", nil} -> {:input_step_id, nil}
              {"input_step_id", value} -> {:input_step_id, Ecto.UUID.load!(value)}
              {key, value} -> {String.to_atom(key), value}
            end)
          end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get all root steps (steps with no input_step_id).
  """
  @spec get_root_steps(Ecto.UUID.t()) :: [t()]
  def get_root_steps(pipeline_run_id) do
    from(s in __MODULE__,
      where: s.pipeline_run_id == ^pipeline_run_id and is_nil(s.input_step_id),
      order_by: [asc: s.started_at]
    )
    |> repo().all()
  end

  @doc """
  Get all downstream steps (children) of a given step.
  """
  @spec get_downstream_steps(Ecto.UUID.t()) :: [t()]
  def get_downstream_steps(step_id) do
    from(s in __MODULE__,
      where: s.input_step_id == ^step_id,
      order_by: [asc: s.started_at]
    )
    |> repo().all()
  end

  @doc """
  Get steps by type for a pipeline run.
  """
  @spec get_steps_by_type(Ecto.UUID.t(), String.t()) :: [t()]
  def get_steps_by_type(pipeline_run_id, step_type) do
    from(s in __MODULE__,
      where: s.pipeline_run_id == ^pipeline_run_id and s.step_type == ^step_type,
      order_by: [asc: s.started_at]
    )
    |> repo().all()
  end

  @doc """
  Get failed steps for a pipeline run.
  """
  @spec get_failed_steps(Ecto.UUID.t()) :: [t()]
  def get_failed_steps(pipeline_run_id) do
    from(s in __MODULE__,
      where: s.pipeline_run_id == ^pipeline_run_id and s.status == :failed,
      order_by: [asc: s.started_at]
    )
    |> repo().all()
  end

  # LAYER 2 of the two-layer drop (see the moduledoc). Four GENERIC field names,
  # dropped on every struct this module serializes — DSL structs included, and
  # plain `defstruct` / live Ecto structs reached through recursion, which carry
  # no flags at all. Domain-specific names do NOT belong here: a name on this
  # list is stripped from every struct that happens to reuse it, which is the
  # wart per-field `log: false` exists to remove. The four that stay are generic
  # enough that no struct wants them persisted:
  #
  # - `:content` — the convention for a Step Output's heavy artifact body
  #   (Markdown / large text). Naming a field `:content` opts it OUT of
  #   `output_data` for free, so only the lightweight envelope is persisted (the
  #   body lives in DynamoDB). Renaming a producer field away from `:content`
  #   (e.g. `DigestRenderStep.Output`) silently re-bloats every step log.
  # - `:raw_html` / `:html` — a scraper Output's whole fetched page.
  # - `:engine` — a transient `%ALLM.Engine{}` injected into some extractor
  #   inputs (parent-process engine resolution for `Task.async` safety). It
  #   carries adapter opts — including the test Fake's `{:scripts, ...}` keyword
  #   — that Jason cannot encode and that have no value in the step log.
  #
  # Pinned as an exact set by `step_log_serialization_test.exs` so a fifth name
  # cannot be added silently. To drop a field on ONE struct, declare
  # `log: false` on it; to keep a field whose name is on this list, `log: true`.
  @fallback_drop [:raw_html, :html, :content, :engine]

  # D4: a bound on UNREVIEWED nesting depth, not a cycle guard — Elixir terms are
  # acyclic by construction and nothing today fails to terminate. The serializer
  # recurses into arbitrary structs it does not own (live Ecto structs with their
  # `__meta__` and `%NotLoaded{}` placeholders, `%ALLM.Engine{}`), and the depth
  # of that walk is otherwise whatever the caller's struct graph happens to be.
  #
  # 16 is 2× the observed maximum of 8, measured over all 43,571 non-null
  # `input_data` + `output_data` values in the dev database. Re-derive with
  # `python3 scripts/steplog_depth.py input_data` and the `output_data` twin —
  # and match that script's convention, which this module implements: the
  # serialized struct is level 1 and its field values are level 2, so a flat map
  # of scalars is depth 2.
  #
  # TRUNCATE, NEVER RAISE. `serialize_struct/2` runs inside `log_start/4`, whose
  # `{:ok, step_log} = …` bang-match in `ALLM.Pipeline.Executor` is reached
  # BEFORE the executor's rescue. A raise here loses the whole step log — and,
  # through a `Task.async_stream` fan-out, the caller — rather than one field.
  @max_depth 16
  @truncated "[truncated: max depth #{@max_depth}]"

  # D3: `redact: true` applies at SERIALIZATION, not at construction — a step
  # that receives a credential needs the credential. This is the single choke
  # point where a field value crosses into persistence. Note the coverage is
  # exactly `input_data` / `output_data`: `artifact_content/1`, the Executor's
  # validation error messages, `log_summary/4` and `inspect/1` are NOT covered,
  # and `ALLM.Pipeline.Schema`'s moduledoc enumerates all four.
  @redacted "[REDACTED]"

  @spec serialize_struct(struct() | nil) :: map() | nil
  defp serialize_struct(nil), do: nil
  defp serialize_struct(struct), do: serialize_struct(struct, 1)

  # `level` is the nesting level of `struct` itself under the convention above.
  @spec serialize_struct(struct(), pos_integer()) :: map()
  defp serialize_struct(struct, level) do
    {drop, redact} = drop_and_redact(struct.__struct__)

    struct
    |> Map.from_struct()
    |> Map.drop(drop)
    |> Enum.into(%{}, fn {key, value} ->
      {to_string(key), serialize_field(key, value, redact, level + 1)}
    end)
  end

  # The two-layer drop set, resolved per MODULE. Layer 1 is the module's own
  # field flags; layer 2 is `@fallback_drop`, minus anything the module declares
  # `log: true`. `:dropped` already unions `artifact: true` into `log: false`,
  # and `:dropped` / `:kept` are disjoint by construction (`log:` is one option,
  # and `artifact: true` + `log: true` is a compile-time `ArgumentError`), so the
  # two operations cannot conflict.
  @spec drop_and_redact(module()) :: {[atom()], [atom()]}
  defp drop_and_redact(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__allm_schema__, 1) do
      kept = module.__allm_schema__(:kept)

      {module.__allm_schema__(:dropped) ++ (@fallback_drop -- kept),
       module.__allm_schema__(:redacted)}
    else
      {@fallback_drop, []}
    end
  end

  @spec serialize_field(atom(), term(), [atom()], pos_integer()) :: term()
  defp serialize_field(key, value, redact, level) do
    if key in redact, do: @redacted, else: maybe_serialize(value, level)
  end

  # Leaves shared with `ALLM.Pipeline.Encodable` are DELEGATED to it rather than
  # re-implemented: Calendar structs (which carry a `microsecond: {n, precision}`
  # tuple Jason cannot encode), `Decimal`, and binaries — where the scrub strips
  # NUL bytes / invalid UTF-8 that PostgreSQL's jsonb columns reject. OCR'd PDF
  # text and LLM output occasionally carry them, and without scrubbing a single
  # bad byte fails the step_log insert/update with
  # `ERROR 22P05 (untranslatable_character)` and the whole meeting is lost.
  #
  # The delegation is deliberately LEAF-ONLY, for two reasons that are OBSERVABLE
  # in the persisted row:
  #
  #   1. This module's container clauses recurse through `serialize_field/4`, so
  #      the drop set, the `redact:` substitution and the depth budget apply
  #      INSIDE every map/list/tuple. `Encodable.encode/1` applies none of them,
  #      so a delegated container would persist a nested `:raw_html` body and a
  #      nested `redact:` value verbatim.
  #   2. `Encodable` folds a non-empty keyword list into a map; this module maps
  #      it to a list of two-element lists. That is a genuine shape difference in
  #      `output_data`.
  #
  # (Corrected 2026-08-14 by the 2.2 fix pass, code review F3: this comment used
  # to lead with "`Encodable` stringifies every key, so delegating changes
  # `output_data`'s shape". That reason is NOT observable — `output_data` is
  # dumped through Jason, which stringifies atom keys anyway. Atom keys are
  # preserved in the in-memory term only. The DECISION was and is right; only
  # the reason was wrong.)
  #
  # Container rules are re-stated here instead, and the tuple rule (tuple → list)
  # matches `Encodable`'s semantics while staying inside this module's contract.
  @spec maybe_serialize(term(), pos_integer()) :: term()
  defp maybe_serialize(%DateTime{} = v, _level), do: Encodable.encode(v)
  defp maybe_serialize(%NaiveDateTime{} = v, _level), do: Encodable.encode(v)
  defp maybe_serialize(%Date{} = v, _level), do: Encodable.encode(v)
  defp maybe_serialize(%Time{} = v, _level), do: Encodable.encode(v)
  defp maybe_serialize(%Decimal{} = v, _level), do: Encodable.encode(v)

  # The budget is spent by CONTAINERS only: a scalar at the limit is kept (it
  # adds no level), a container at the limit is replaced, so the emitted term is
  # never deeper than `@max_depth`.
  defp maybe_serialize(v, level)
       when level >= @max_depth and (is_map(v) or is_list(v) or is_tuple(v)),
       do: @truncated

  defp maybe_serialize(v, level) when is_struct(v), do: serialize_struct(v, level)

  defp maybe_serialize(v, level) when is_map(v),
    do: Map.new(v, fn {k, val} -> {k, maybe_serialize(val, level + 1)} end)

  defp maybe_serialize(v, level) when is_list(v),
    do: Enum.map(v, &maybe_serialize(&1, level + 1))

  defp maybe_serialize(v, level) when is_tuple(v),
    do: v |> Tuple.to_list() |> Enum.map(&maybe_serialize(&1, level + 1))

  defp maybe_serialize(v, _level) when is_binary(v), do: Encodable.encode(v)
  defp maybe_serialize(v, _level), do: v

  defp normalize_error(%{__exception__: true} = e) do
    %{"type" => to_string(e.__struct__), "message" => Exception.message(e)}
  end

  # A failed loader returns its `Ecto.Changeset`; render it to its structured,
  # params-free validation errors via `Encodable.encode/1`'s `changeset_errors`
  # leaf, the same rule that covers a changeset reaching run metadata. This is
  # NOT truncated (unlike the bounded fallback below), so the `errors` list the
  # column operators read to diagnose a failed step survives in full — which is
  # what let the generic fallback become bounded (Phase 5.10).
  defp normalize_error(%Ecto.Changeset{} = changeset), do: Encodable.encode(changeset)

  defp normalize_error(error) when is_binary(error), do: %{"message" => error}

  # BOUNDED, not bare `inspect/1`: an exit reason such as
  # `{:timeout, {GenServer, :call, [pid, message, 5000]}}` inlines the call's
  # message term — exactly where a bearer token or session handle would sit — and
  # this column is `step_logs.error`. `Encodable.render/1` caps collection depth
  # and binary length; the changeset clause above removes the tension the old
  # unbounded form existed for (a small `limit:` truncating a changeset's errors).
  # Mirrors `PipelineRun.normalize_error/1`'s bounded fallback.
  defp normalize_error(error), do: %{"message" => Encodable.render(error)}

  # The host's Ecto repo, resolved at RUNTIME. `allm_pipeline` deliberately
  # depends on no host app (see this repo's `mix.exs`), so this tree
  # cannot `alias Amesbury.Repo` — that is a compile error here, by design.
  @spec repo() :: module()
  defp repo, do: ALLM.Pipeline.Config.repo()
end
