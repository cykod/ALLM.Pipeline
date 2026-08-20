defmodule ALLM.Pipeline do
  @moduledoc """
  `use ALLM.Pipeline` — the framework's notion of "a pipeline".

  Before Phase 4 an orchestrator was a plain module, and every one of them
  hand-wrote the same skeleton: `Executor.create_pipeline_run/3`, a sequence of
  `Executor.run_step/5` calls threading `input_step_id` by hand, a `try/rescue`
  that fails the run and reraises, a `Metrics.record/3`, and a terminal
  `PipelineRun.complete/2`. That skeleton was not written the same way twice,
  and its variations were the defects: entry points that terminate their run on
  no path, `run_step` calls passing `nil` for lineage, orchestrators with no
  `rescue` at all.

      defmodule MeetingAgendaPipeline do
        use ALLM.Pipeline,
          name: "meeting_agenda_scrape",
          metadata: :run_metadata,
          complete_metadata: :serialize_metrics,
          init: :init_metrics,
          concurrency: 1

        stage :committee_cache, fn _ctx, _prev -> {:ok, ensure_committee_cache()} end
        stage :list, MeetingListScraper, input: :build_list_input

        fan_out :meeting,
          over: :meetings_from,
          section: :section_title,
          gate: :meeting_decision,
          parent: :source_stage,
          delay: [ms: {:opt, :delay_ms, 2000}, when: :processed],
          body: :process_single_meeting

        metrics "meetings", from: :funnel
        summarize :finalize
      end

  ## The scope is the SKELETON, not the body

  The DSL owns run creation, the lineage parent, fan-out, sections, skips,
  politeness delays, metrics and the terminal write. It wraps a per-item body
  that stays an **ordinary Elixir function** — `meeting_agenda`'s ~600-line
  `process_single_meeting/2`, with its runtime Step-module selection by
  committee name, is untouched by the port. That is the design working, not a
  shortfall: an honest read of eight orchestrators against a *full* declarative
  construct set found 2 of 8 expressible.

  It is also a **layer over `ALLM.Pipeline.Executor`, not a replacement**.
  `ALLM.Pipeline.Dsl.Runtime` reaches a `pipeline_runs`, `step_logs` or
  `pipeline_metrics` row **only** through `Executor`, `PipelineRun` and `Metrics`
  functions a hand-written orchestrator already calls — `create_pipeline_run/3`,
  `run_step/5`, `log_section/3`, `fail_pipeline_run/2`, `PipelineRun.complete/2`,
  `PipelineRun.borrow/1`, `Metrics.record/3` — with the same arguments, and adds
  no `Repo` call of its own. (That module's moduledoc carries the command to
  re-derive the set; do not restate it from memory.) The DSL changes *who writes
  the call*, not *what the call is* — which is what makes "the ported pipeline's
  step-log tree is structurally identical" an achievable gate rather than an
  aspiration.

  ## The generated lifecycle

      1. Executor.create_pipeline_run(name, metadata_hook.(opts))
         └─ the OWNING handle never leaves the generated run/1
      2. run stages in declaration order      ─┐
           stage    → Executor.run_step        │
           fan_out  → per item: section? gate? │  try / rescue / catch
                      skip? body, then delay?  │
           stage/fn → escape hatch             │
      3. summarize_hook.(acc, ctx)             │
      4. Metrics.record(run, entity, funnel)   │
      5. terminal write: complete/2 or fail/2 ─┘

  ## `use` options

  | Option | Required | Value | Meaning |
  |---|---|---|---|
  | `name:` | yes | `String.t()` | `PipelineRun.name`, passed to `create_pipeline_run/3` |
  | `metadata:` | no | hook `(keyword()) :: map()` | run metadata; default `%{options: opts}` |
  | `complete_metadata:` | no | hook `(acc) :: map()` | what `PipelineRun.complete/2` writes; default: the accumulator |
  | `init:` | no | hook `(() :: term())` | the accumulator's initial value; default `%{}` |
  | `returns:` | no | `:summary` \\| `:run` | what `run/1` returns on success; default `:summary` |
  | `concurrency:` | no | `pos_integer()` \\| `{:opt, key, default}` | default **1**; a per-`fan_out` override wins |

  Three values are deliberately distinct, because real pipelines need them
  different: what `run/1` RETURNS (`summarize`, or the completed run under
  `returns: :run`), what `complete/2` WRITES (`complete_metadata:`), and what
  `metrics` RECORDS (`from:`). `summarize` runs before the terminal write and
  therefore structurally cannot produce the completed `%PipelineRun{}` — that is
  what `returns: :run` is for.

  ## Generated functions

      @spec run(keyword()) :: {:ok, term()} | {:error, term()}
      @spec __pipeline__(:name | :stages | :metrics | :concurrency | :hooks) :: term()

  `__pipeline__(:stages)` returns a list of `ALLM.Pipeline.Dsl.Stage`
  **structs**, not bare atoms — read the field you mean (`& &1.name`,
  `& &1.concurrency`).

  `run/1` takes `run_name:` in `opts` to override `name:` for a mode variant
  (`meeting_list_only` vs `meeting_agenda_scrape`); the run-name *set* is Phase
  6's.

  ## The item-result contract

  Every `fan_out` body and every escape-hatch `stage` returns one of:

      {:ok, term()}                                # lineage-transparent
      {:ok, term(), ALLM.Pipeline.StepLog.t()}     # nominate a new lineage parent
      {:skipped, reason :: term()}
      {:error, reason :: term()}

  …optionally wrapped as `{item_result, acc}` to write the accumulator. **That
  second element is the only channel that writes it.** This is not sugar:
  `meeting_agenda`'s per-item body updates a nine-key stats map through fifteen
  call sites nested four levels deep, and none of those keys is recoverable from
  any `item_result` shape. A body returning a bare `item_result` leaves the
  accumulator untouched.

  Where a *label* rides on the result, it rides **inside the payload** —
  `{:error, {identifier, reason}}`.

  ## Lineage

  Lineage **in** is free, lineage **out** is by hand (D2). A body receives the
  current parent as `ALLM.Pipeline.Context.input_step_id(ctx)` and threads it to
  its own `Executor.run_step/5` calls exactly as hand-written code does today —
  which is what preserves `meeting_agenda`'s **flat** two-level tree, where all
  seven leaf steps parent to the *list* step rather than chaining. A DSL that
  "helpfully" chained them would fail the identity gate.

  Three rules follow:

  * A **skip is lineage-transparent**: the next stage's `input_step_id` is the
    last *successfully executed* step's log id. A skip writes no step log in
    Phase 4 (D8) — `StepLog.log_skipped/2` exists with no framework caller, and
    promoting it is a behaviour change a structural-identity gate cannot absorb.
  * `section:` emits a **sibling leaf and is never the lineage parent**.
    `Executor.log_section/3` writes a real `step_logs` row, so the natural
    reading of "per item: section → gate → body" would make it the item's parent
    and change every edge under it. It does not.
  * `fan_out`'s `parent:` has two modes and both ports need a different one:
    `:source_stage` (default) parents every item's steps to the fan-out's source
    stage — `meeting_agenda`'s flat tree — while `:per_item` takes
    `input_step_id` from each item's **own** producing step log, which is
    `committee`'s chain. Getting this wrong is invisible to a spot check and
    fatal to the gate.

  ## Per-item failures are NOT caught by default

  `catch_item_failures: true` is opt-in per `fan_out`, and neither Phase 4 port
  declares it. What survives a Step's own safety is infrastructure raising —
  pool exhaustion, a lost connection — and one of those should abort the run
  rather than be tallied as N individually-failed items under a `:success` run.
  A framework that caught by default would silently invert that.

  The **one** exception is not a policy choice: a `fan_out` with
  `concurrency > 1` runs through `Task.async_stream`, which LINKS its children,
  so an uncaught raise or exit in one item kills the caller before the stream
  emits anything. Those are therefore **always** wrapped in `catch kind, reason`
  and degraded to `{:error, {:uncaught, kind, reason}}` — the rule
  `ALLM.Pipeline.FanOut`'s moduledoc states, applied once in the framework
  instead of at each call site. `rescue` alone is insufficient: an exit is not
  an exception.

  ## Ownership

  The generated `run/1` obtains its handle from
  `Executor.create_pipeline_run/3` and **the owning handle never leaves
  `Dsl.Runtime`** — not to a hook, and not through a return value. Every stage
  body, `gate:`, `section:`, `over:`, `input:`, `skip_when:` and `summarize`
  hook sees the borrowed projection (`PipelineRun.borrow/1`), so a body
  observing `ctx.pipeline_run` cannot complete its own parent run; and
  `returns: :run` hands back the completed run **borrowed**, because
  `Repo.update` carries virtual fields through and the struct
  `PipelineRun.complete/2` returns still holds the token. The DSL introduces
  **no third mint point** — `PipelineRun.create/3` and
  `PipelineRun.assume_ownership/1` remain the only two.
  """

  alias ALLM.Pipeline.Dsl

  @doc """
  Declare a pipeline. See the moduledoc for the option table.
  """
  defmacro __using__(opts) do
    declaration = Dsl.__validate__!(__CALLER__.module, opts)

    quote do
      import ALLM.Pipeline.Dsl,
        only: [stage: 2, stage: 3, fan_out: 2, fan_out: 3, metrics: 2, summarize: 1]

      Module.register_attribute(__MODULE__, :allm_pipeline_stages, accumulate: true)

      @allm_pipeline_declaration unquote(Macro.escape(declaration))
      @allm_pipeline_metrics nil
      @allm_pipeline_metrics_hooks []
      @allm_pipeline_summarize nil
      @allm_pipeline_summarize_hooks []

      @before_compile ALLM.Pipeline
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    declaration = Module.get_attribute(env.module, :allm_pipeline_declaration)
    specs = env.module |> Module.get_attribute(:allm_pipeline_stages) |> Enum.reverse()
    metrics = Module.get_attribute(env.module, :allm_pipeline_metrics)
    summarize = Module.get_attribute(env.module, :allm_pipeline_summarize)

    if specs == [] do
      raise ArgumentError,
            "#{inspect(env.module)}: a pipeline must declare at least one `stage` or `fan_out`."
    end

    assert_unique_names!(env.module, specs)

    Dsl.__assert_hooks_defined__!(
      env,
      declaration.atom_hooks ++
        Enum.flat_map(specs, & &1.atom_hooks) ++
        Module.get_attribute(env.module, :allm_pipeline_metrics_hooks) ++
        Module.get_attribute(env.module, :allm_pipeline_summarize_hooks)
    )

    stages_ast = Enum.map(specs, &Dsl.__stage_ast__/1)

    metrics_ast =
      if metrics, do: {:%{}, [], [entity_type: metrics.entity_type, from: metrics.from]}

    quote do
      @doc """
      Run this pipeline.

      Creates the `PipelineRun`, executes every declared stage in order,
      summarizes, records metrics, and writes the terminal status — on every
      exit path, including a raise, an exit and a throw.

      `opts` are the pipeline's own options; `run_name:` overrides the declared
      `name:` for a mode variant.
      """
      @spec run(keyword()) :: {:ok, term()} | {:error, term()}
      def run(opts \\ []), do: ALLM.Pipeline.Dsl.Runtime.run(__MODULE__, opts)

      @doc false
      @spec __pipeline__(:name | :stages | :metrics | :concurrency | :hooks) :: term()
      def __pipeline__(:name), do: unquote(declaration.name)
      def __pipeline__(:concurrency), do: unquote(declaration.concurrency)
      def __pipeline__(:stages), do: unquote(stages_ast)
      def __pipeline__(:metrics), do: unquote(metrics_ast)

      def __pipeline__(:hooks) do
        %{
          metadata: unquote(declaration.metadata),
          complete_metadata: unquote(declaration.complete_metadata),
          init: unquote(declaration.init),
          summarize: unquote(summarize),
          returns: unquote(declaration.returns)
        }
      end

      defoverridable run: 1
    end
  end

  @spec assert_unique_names!(module(), [Dsl.stage_spec()]) :: :ok
  defp assert_unique_names!(module, specs) do
    duplicates =
      specs |> Enum.frequencies_by(& &1.name) |> Enum.filter(&(elem(&1, 1) > 1)) |> Keyword.keys()

    if duplicates != [] do
      raise ArgumentError,
            "#{inspect(module)}: duplicate stage name(s) #{inspect(duplicates)}. " <>
              "Stage names index `__pipeline__(:stages)` and appear in log lines, so they " <>
              "must be unique within a pipeline."
    end

    :ok
  end
end
