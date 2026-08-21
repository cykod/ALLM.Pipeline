defmodule ALLM.Pipeline.Context do
  @moduledoc """
  Pipeline execution context passed to each step — and, since Phase 4, to every
  `ALLM.Pipeline` escape-hatch body and `fan_out` body as well.

  Contains the current pipeline run and step log, allowing steps to access
  pipeline-level information and log additional data.

  ## One context, not two (Phase 4 D5)

  An escape-hatch body is **not** a step: it has no step log, and its lineage
  parent is the last successfully executed step's log id rather than its own
  row. Rather than introduce a second context type — two names for one idea,
  and a forced widening of `ALLM.Pipeline.Step.context/0` anyway — this struct
  gained three fields and `step_log` became nilable:

  | Field | Accessor | Who writes it |
  |---|---|---|
  | `resources` | `resource/2` | `ALLM.Pipeline.Dsl.Runtime` (`resource` is Phase 4.3; the field and reader ship in 4.1 so `Runtime` has one shape to build) |
  | `carry` | `carried/2` | `Runtime`, from a stage's `carry: [...]` declaration |
  | `input_step_id` | `input_step_id/1` | `Runtime`, or derived from `step_log.input_step_id` |
  | `acc` | `accumulator/1` | `Runtime`, before each body invocation |

  `acc` is the **read** half of the accumulator channel. A body writes it by
  returning `{item_result, acc}` (`ALLM.Pipeline`'s item-result contract) —
  which is only expressible if the body can also SEE the current value, since
  `meeting_agenda`'s per-item body updates a nine-key stats map through fifteen
  nested call sites. It is a snapshot taken before the body runs, never a
  mutable handle: writing goes through the return value and nowhere else.

  `resources` and `carry` are struct FIELDS, not `opts` keys. That is the whole
  point of §3.10's `Context.resource(ctx, :browser)` over
  `Keyword.get(opts, :page)`: a resource is framework-managed state with a
  lifecycle, and burying it in the caller's option list makes it
  indistinguishable from a CLI flag. `new/3` therefore **pops** `:resources`,
  `:carry`, `:input_step_id` and `:acc` out of `opts` — they never reach
  `get_opt/3`.
  """

  alias ALLM.Pipeline.{PipelineRun, StepLog}

  @typedoc """
  Framework-managed handles acquired once per run (a browser, a connection
  pool), keyed by the name their `resource` declaration gave them.
  """
  @type resources :: %{optional(atom()) => term()}

  @typedoc """
  Values captured by a `carry: [...]` declaration, keyed by field name. Carried
  values live HERE rather than on a step log, which is what makes a `stage`'s
  survive any number of skipped stages between producer and consumer (Phase 4
  D4).

  The scope depends on the declaring stage's kind and the two are not the same:
  a **`stage`** captures from its own output and the values reach every later
  stage; a **`fan_out`** captures from each item into that item's own context
  only, and nothing is propagated past the stage. The authoritative statement is
  `ALLM.Pipeline.Dsl.Stage`'s "carry:'s scope differs by kind".
  """
  @type carry :: %{optional(atom()) => term()}

  @type t :: %__MODULE__{
          pipeline_run: PipelineRun.t() | nil,
          step_log: StepLog.t() | nil,
          input_step_id: Ecto.UUID.t() | nil,
          resources: resources(),
          carry: carry(),
          acc: term(),
          opts: keyword()
        }

  defstruct [
    :pipeline_run,
    :step_log,
    :input_step_id,
    :acc,
    resources: %{},
    carry: %{},
    opts: []
  ]

  @doc """
  Create a new context for a step execution.

  `step_log` may be `nil` — an escape-hatch body is not a step and has no row.

  Four keys are read out of `opts` onto struct fields and removed from the
  option list: `:resources`, `:carry`, `:acc` and `:input_step_id`. When
  `:input_step_id` is absent it falls back to the step log's own
  `input_step_id`, so the accessor answers the same question ("what is this
  unit's lineage parent?") for a step and for a body.
  """
  @spec new(PipelineRun.t(), StepLog.t() | nil, keyword()) :: t()
  def new(pipeline_run, step_log, opts \\ []) do
    {resources, opts} = Keyword.pop(opts, :resources, %{})
    {carry, opts} = Keyword.pop(opts, :carry, %{})
    {input_step_id, opts} = Keyword.pop(opts, :input_step_id)
    {acc, opts} = Keyword.pop(opts, :acc)

    %__MODULE__{
      pipeline_run: pipeline_run,
      step_log: step_log,
      input_step_id: input_step_id || step_log_parent(step_log),
      resources: resources,
      carry: carry,
      acc: acc,
      opts: opts
    }
  end

  @doc """
  A context for a Step invoked **outside** any pipeline run — a mix task, a
  backfill, an eval harness, an ad-hoc `iex` call.

  Carries no run and no step log, only `opts`. This is the named replacement for
  the `SomeStep.execute(%{}, input)` idiom, which stopped being in contract when
  Phase 4 widened `ALLM.Pipeline.Step.context/0` from a bare map to this struct
  (D5). The bare map still WORKS — a struct is a map and every such caller
  ignores the context — so migrating the remaining sites is bookkeeping, tracked
  in `.work/HANDOFF.md`, not a correctness fix.
  """
  @spec detached(keyword()) :: t()
  def detached(opts \\ []), do: %__MODULE__{opts: opts}

  @doc """
  Get the pipeline run ID from context.

  `nil` for a `detached/1` context, which has no run — mirroring
  `step_log_id/1`. A single-clause version raises `FunctionClauseError` on every
  detached caller, which is the wrong failure for an accessor whose whole
  purpose is to answer "am I inside a run?".
  """
  @spec pipeline_run_id(t()) :: Ecto.UUID.t() | nil
  def pipeline_run_id(%__MODULE__{pipeline_run: %{id: id}}), do: id
  def pipeline_run_id(%__MODULE__{pipeline_run: nil}), do: nil

  @doc """
  Get the current step log ID from context.

  `nil` for an escape-hatch body, which has no step log of its own.
  """
  @spec step_log_id(t()) :: Ecto.UUID.t() | nil
  def step_log_id(%__MODULE__{step_log: %{id: id}}), do: id
  def step_log_id(%__MODULE__{step_log: nil}), do: nil

  @doc """
  The lineage parent this unit was invoked under.

  For a step, the step log's own `input_step_id`. For an escape-hatch or
  `fan_out` body, the id of the last successfully executed step's log — which
  the body threads to its own `ALLM.Pipeline.Executor.run_step/5` calls exactly
  as hand-written orchestrator code does today. Lineage **in** is free; lineage
  **out** is by hand (Phase 4 D2).
  """
  @spec input_step_id(t()) :: Ecto.UUID.t() | nil
  def input_step_id(%__MODULE__{input_step_id: id}), do: id

  @doc """
  A framework-managed resource acquired for this run, or `nil`.

  Reads the `resources` struct field and **nothing else**. It deliberately does
  not fall back to `opts`: a lookup that degrades to the caller's option list
  answers plausibly for a resource that was never acquired, which is the failure
  this accessor exists to make visible.
  """
  @spec resource(t(), atom()) :: term() | nil
  def resource(%__MODULE__{resources: resources}, name), do: Map.get(resources, name)

  @doc """
  A value captured by a `carry: [...]` declaration, or `default`.

  From an **earlier `stage`** (its captures reach every later stage), or from
  **this item's own `fan_out`** (its captures are item-scoped and do not
  propagate). See `carry/0`'s typedoc.

  `default` here does not distinguish "declared and legitimately absent" from
  "declared a key the subject never had" — but the second is not silent:
  `Runtime.capture/3` warns at capture time. See
  `ALLM.Pipeline.Dsl.Stage`'s "A key the subject does not have".
  """
  @spec carried(t(), atom(), term()) :: term()
  def carried(%__MODULE__{carry: carry}, name, default \\ nil), do: Map.get(carry, name, default)

  @doc """
  The pipeline accumulator as it stood when this unit was invoked.

  A snapshot, not a handle: the **only** channel that writes the accumulator is
  a body returning `{item_result, acc}`. `nil` outside a DSL run and for a
  pipeline that declares no `init:` and never writes it.
  """
  @spec accumulator(t()) :: term()
  def accumulator(%__MODULE__{acc: acc}), do: acc

  @doc """
  Get an option from context.
  """
  @spec get_opt(t(), atom(), term()) :: term()
  def get_opt(%__MODULE__{opts: opts}, key, default \\ nil) do
    Keyword.get(opts, key, default)
  end

  @spec step_log_parent(StepLog.t() | nil) :: Ecto.UUID.t() | nil
  defp step_log_parent(%StepLog{input_step_id: id}), do: id
  defp step_log_parent(_step_log), do: nil
end
