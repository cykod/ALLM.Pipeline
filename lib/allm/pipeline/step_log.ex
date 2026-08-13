defmodule ALLM.Pipeline.StepLog do
  @moduledoc """
  Persists step execution logs to PostgreSQL for observability and lineage tracking.

  Key design decisions:
  - `pipeline_run_id` stored directly for efficient querying (no recursive joins needed)
  - `input_step_id` enables lineage tree reconstruction when needed
  - Timing fields capture execution performance metrics
  - Input/output schemas stored as JSONB for debugging and replay
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias ALLM.Pipeline.Text
  alias ALLM.Pipeline.PipelineRun

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
  # The keys come from `Runner.drain_and_store_llm/2` (atom-keyed): a successful
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
  Log step as skipped.
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
  Log a section marker for visual grouping in the admin UI.

  Creates a step_log with step_type "section" that serves as a visual divider
  in the pipeline review interface. Sections are excluded from pipeline stats.
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
      input_data: %{"title" => title}
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

  # Serialize struct to map with string keys, excluding artifact content to keep
  # step logs lightweight. `:engine` is dropped: it is a transient
  # `%ALLM.Engine{}` injected into some extractor inputs (parent-process engine
  # resolution for `Task.async` safety) and carries adapter opts — including the
  # test Fake's `{:scripts, ...}` keyword — that Jason cannot encode and that have
  # no value in the step log.
  defp serialize_struct(nil), do: nil

  defp serialize_struct(struct) do
    # `:content` is the convention for a Step Output's heavy artifact body
    # (Markdown / large text): naming a field `:content` opts it OUT of
    # `output_data` so only the lightweight envelope is persisted (the body
    # lives in DynamoDB). Renaming a producer field away from `:content` (e.g.
    # `DigestRenderStep.Output`) would silently start bloating every step log.
    # `:bill_catalog` is dropped for the same lightweight-row reason as `:content`:
    # the meeting-summary Input carries a per-year ordinance catalog (~150 rows)
    # for LLM bill attribution; it is reconstructable from the DB and would
    # otherwise bloat every summary step log.
    # `:assignments` is dropped because `VideoMatchStep.Output` carries it as a
    # list of LIVE `%Meeting{}` / `%VideoListing{}` structs (with
    # `%Ecto.Association.NotLoaded{}` fields) that the pipeline reads off the
    # returned Output to write meetings — un-encodable and not for the row. The
    # serializable `:decisions` audit stays in `output_data` and the artifact.
    # `:extracted_text` is dropped because `DocumentTextExtractor.Output` carries
    # the full extracted PDF/DOC text (often 100KB–1MB) — already persisted once
    # as the `text/plain` DynamoDB artifact via
    # `DocumentTextExtractor.artifact_content/1`; leaving it here would write the
    # same large body a second time into the `output_data` JSONB row. The
    # lightweight `:character_count` / `:extracted_links` stay in `output_data`.
    # `:shortlist` is dropped because `HeroCropReviewer.Input` carries the whole
    # ranked candidate pool (up to 24 decorated classifier maps) purely so the
    # `reject_image` swap and the gallery repair have something to draw from —
    # the same images are already persisted by the classifier/curator step logs
    # upstream, so keeping them here would write the pool a third time. The
    # global-by-field-name check is done: `grep -rn "field(:shortlist" apps/*/lib`
    # returns only that one declaration.
    struct
    |> Map.from_struct()
    |> Map.drop([
      :raw_html,
      :html,
      :content,
      :engine,
      :bill_catalog,
      :assignments,
      :extracted_text,
      :shortlist
    ])
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), maybe_serialize(v)} end)
  end

  # Calendar structs carry a `microsecond: {n, precision}` tuple that Jason
  # cannot encode, so render them as ISO-8601 strings rather than recursing.
  defp maybe_serialize(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp maybe_serialize(%NaiveDateTime{} = v), do: NaiveDateTime.to_iso8601(v)
  defp maybe_serialize(%Date{} = v), do: Date.to_iso8601(v)
  defp maybe_serialize(%Time{} = v), do: Time.to_iso8601(v)
  defp maybe_serialize(v) when is_struct(v), do: serialize_struct(v)

  defp maybe_serialize(v) when is_map(v),
    do: Map.new(v, fn {k, val} -> {k, maybe_serialize(val)} end)

  defp maybe_serialize(v) when is_list(v), do: Enum.map(v, &maybe_serialize/1)
  # Strip NUL bytes / invalid UTF-8 that PostgreSQL's jsonb columns reject.
  # OCR'd PDF text and LLM output occasionally carry them (e.g. a NUL echoed
  # into an agenda item's title/description); without scrubbing here a single
  # bad byte fails the step_log insert/update with
  # `ERROR 22P05 (untranslatable_character)` and the whole meeting is lost.
  defp maybe_serialize(v) when is_binary(v), do: Text.scrub(v)
  defp maybe_serialize(v), do: v

  defp normalize_error(%{__exception__: true} = e) do
    %{"type" => to_string(e.__struct__), "message" => Exception.message(e)}
  end

  defp normalize_error(error) when is_binary(error), do: %{"message" => error}
  defp normalize_error(error), do: %{"message" => inspect(error)}

  # The host's Ecto repo, resolved at RUNTIME. `allm_pipeline` deliberately
  # depends on no umbrella app (see `apps/allm_pipeline/mix.exs`), so this tree
  # cannot `alias Amesbury.Repo` — that is a compile error here, by design.
  @spec repo() :: module()
  defp repo, do: ALLM.Pipeline.Config.repo()
end
