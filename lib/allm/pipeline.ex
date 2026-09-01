defmodule ALLM.Pipeline do
  @moduledoc """
  `use ALLM.Pipeline` — the framework's notion of "a pipeline".

  The DSL owns the run skeleton — run creation, lineage-threaded step
  sequencing, the guard that fails-and-reraises, metrics, terminal complete — so
  a pipeline declares stages, not boilerplate. Hand-writing that skeleton
  (`Executor.create_pipeline_run/3`, a sequence of `Executor.run_step/5` calls
  threading `input_step_id` by hand, a `try/rescue` that fails the run and
  reraises, a `Metrics.record/3`, a terminal `PipelineRun.complete/2`) is what
  produces the classic defects, because the skeleton is never written the same
  way twice: entry points that terminate their run on no path, `run_step` calls
  passing `nil` for lineage, orchestrators with no `rescue` at all.

  A declaration whose per-item fan-out is a plain `stage` whose body calls
  `ALLM.Pipeline.FanOut.reduce/5` — declarative `fan_out` is for Step-module
  targets only, and folding an ordinary body over items is done in code:

      defmodule MyApp.ReportPipeline do
        use ALLM.Pipeline,
          name: "report_scrape",
          metadata: :run_metadata,
          complete_metadata: :serialize_metrics,
          init: :init_metrics,
          concurrency: 1,
          summary_type: :stats

        stage :warm_cache, fn _ctx, _prev -> {:ok, ensure_cache()} end
        stage :list, MyApp.ListScraper, input: :build_list_input

        # The per-record fan-out is a plain `stage` whose body calls
        # `FanOut.reduce/5`. The framework owns the link-safe catch, the `%Item{}`
        # wrapping and per-item lineage; the section log and the politeness delay
        # are ordinary code in the body below.
        stage :record, :fan_out_records

        # Run-level counters folded into the accumulator AFTER the fan-out, because
        # `complete_metadata:` is handed the ACCUMULATOR, not what `summarize`
        # returned. An escape-hatch stage writes no step log and does not move the
        # lineage parent, so a structural-identity gate does not see it.
        stage :tally, :tally_run

        metrics "records", from: :funnel
        summarize :finalize
      end

      # The `:record` stage body. `FanOut.reduce/5` folds `fold_one/3` over the
      # scraped records, threading the accumulator; the outer 2-tuple `{:ok, items}`
      # is lineage-transparent, so `:tally` still receives the `[Item.t()]` list.
      defp fan_out_records(ctx, prev) do
        {items, acc} =
          FanOut.reduce(ctx, prev.records, Context.accumulator(ctx), &fold_one/3,
            parent: :source_stage)

        {{:ok, items}, acc}
      end

  ## Counting a skip — the accumulator's only write channel

  The accumulator's **only** write channel is a body's `{item_result, acc}`
  return. So a skip the pipeline needs to COUNT — in its `metrics` funnel's
  `skipped:`, in `pipeline_runs.metadata`, in its own `summarize` return — must
  keep the decision **inside the body** and return `{{:skipped, payload},
  updated_acc}`. The body ALSO calls `Executor.log_skipped/4` before that
  return, so the skip is a visible `:skipped` step log with its reason — the
  count still rides the accumulator (the log adds observability, not the count).

  There is deliberately no declarative "skip this item" option: one would write
  **no step log** and could not touch the accumulator, so declaring it would zero
  any skip count silently and in every place at once. The skip log is written by
  an ordinary body call that keeps the `{{:skipped, payload}, acc}` return, not
  by a declarative option.

  ## The scope is the SKELETON, not the body

  The DSL owns run creation, the lineage parent, fan-out, skips, metrics and the
  terminal write. It wraps a per-item body that stays an **ordinary Elixir
  function** — a section log and a politeness delay are ordinary calls in that
  body, not declarative options. So a host's largest per-item body — its own call
  graph, with any runtime Step-module selection it does — is untouched by adopting
  the DSL. That is the design working, not a shortfall: the DSL expresses the run
  skeleton, and a body that resolves its own working set stays hand-written code
  the framework calls.

  It is also a **layer over `ALLM.Pipeline.Executor`, not a replacement**.
  `ALLM.Pipeline.Dsl.Runtime` reaches a `pipeline_runs`, `step_logs` or
  `pipeline_metrics` row **only** through `Executor`, `PipelineRun` and `Metrics`
  functions a hand-written orchestrator already calls — `create_pipeline_run/3`,
  `run_step/5`, `log_section/3`, `log_summary/4`, `borrowed_run/1`,
  `fail_pipeline_run/2`, `PipelineRun.complete/2`, `PipelineRun.borrow/1`,
  `Metrics.record/3` — with the same arguments, and adds no `Repo` call of its
  own. (The terminal write goes through `ALLM.Pipeline.Lifecycle`, which is the
  shared guard, not a second writer.) (That module's moduledoc carries the command to
  re-derive the set; do not restate it from memory.) The DSL changes *who writes
  the call*, not *what the call is* — which is what makes "the ported pipeline's
  step-log tree is structurally identical" an achievable gate rather than an
  aspiration.

  ## The generated lifecycle

      1. Executor.create_pipeline_run(name, metadata_hook.(opts))
         └─ the OWNING handle never leaves the generated run/1
      2. run stages in declaration order      ─┐
           stage    → Executor.run_step        │
           fan_out  → per item: run the Step   │  try / rescue / catch
           stage/fn → escape hatch (a body)    │
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
  | `summary_type:` | no | `atom()` | a zero-arity type THIS module defines; makes the generated `@spec run/1` return `{:ok, that()}` instead of `{:ok, term()}` |
  | `borrowed_run:` | no | `boolean()` | default `false`; see "Running under a borrowed run" |
  | `dry_run:` | no | hook `(ctx) :: map()` | the plan hook; see "`--dry-run`" |

  Three values are deliberately distinct, because real pipelines need them
  different: what `run/1` RETURNS (`summarize`, or the completed run under
  `returns: :run`), what `complete/2` WRITES (`complete_metadata:`), and what
  `metrics` RECORDS (`from:`). `summarize` runs before the terminal write and
  therefore structurally cannot produce the completed `%PipelineRun{}` — that is
  what `returns: :run` is for.

  Those three hooks stay distinct, but `metrics from:` has **one** input
  contract: it receives the **accumulator**, always — never the `summarize`
  return. So declaring (or not declaring) `summarize` never changes `from:`'s
  input shape. A pipeline that wants the summary in its funnel calls its own
  `summarize` hook from within `from:`.

  ## Generated functions

      @spec run(keyword()) :: {:ok, term()} | {:error, term()}
      @spec __pipeline__(:name | :stages | :metrics | :concurrency | :hooks | :resources) ::
              term()

  `run/1`'s return is `{:ok, term()}` **unless** the declaration names its
  summary type. Declare `summary_type: :stats` (a zero-arity type the module
  defines) and the generated spec becomes `{:ok, stats()}`, which is what keeps
  dialyzer type-checking the pipeline's consumers — a using module cannot write
  its own `@spec run/1`, because it would collide with the generated one. Under
  `returns: :run` the type is already known and the two options are mutually
  exclusive.

  `__pipeline__(:stages)` returns a list of `ALLM.Pipeline.Dsl.Stage`
  **structs**, not bare atoms — read the field you mean (`& &1.name`,
  `& &1.concurrency`).

  `run/1` takes `run_name:` in `opts` to override `name:` for a mode variant
  (a `list_only` run vs a full `report_scrape` run share one declaration).

  ## The item-result contract

  Every escape-hatch `stage` body returns one of (a `fan_out` targets a Step
  module and has no body — its item results come from the Step's `execute/2`):

      {:ok, term()}                                # lineage-transparent
      {:ok, term(), ALLM.Pipeline.StepLog.t()}     # nominate a new lineage parent
      {:skipped, reason :: term()}
      {:error, reason :: term()}

  …optionally wrapped as `{item_result, acc}` to write the accumulator. **That
  second element is the only channel that writes it.** This is not sugar: a
  per-item body that maintains a multi-key stats map, updated at call sites nested
  several levels deep, cannot recover those keys from any `item_result` shape. A
  body returning a bare `item_result` leaves the accumulator untouched.

  Where a *label* rides on the result, it rides **inside the payload** —
  `{:error, {identifier, reason}}`.

  ## Lineage

  Lineage **in** is free, lineage **out** is by hand. A body receives the
  current parent as `ALLM.Pipeline.Context.input_step_id(ctx)` and threads it to
  its own `Executor.run_step/5` calls exactly as hand-written code does — which
  preserves a **flat** two-level tree, where every leaf step parents to the
  producing stage rather than chaining. A DSL that "helpfully" chained them would
  fail a structural-identity gate against the hand-written equivalent.

  Three rules follow:

  * A **skip is lineage-transparent**: the next stage's `input_step_id` is the
    last *successfully executed* step's log id — a skip row never becomes the
    lineage PARENT of what follows. A skip DOES write a step log (a visible
    `:skipped` row via `Executor.log_skipped/4` → `StepLog.create_skipped/4`),
    parented like the processed step would have been, so it appears in
    `build_lineage_tree/1` at the position the work would occupy — but as a
    sibling leaf, not an ancestor (exactly like a `section`).
    A skip is also **subject-transparent**: `prev` stays whatever the stage
    BEFORE the skip produced, so the next stage silently receives it. Three
    paths do this — `skip_when:` fired, a body returning `{:skipped, _}`, and
    `on_error: :continue` swallowing an error — and each **names the struct
    `prev` is carrying in its skip log line**, so a downstream
    `FunctionClauseError` in an `input:` hook is one line below the name of the
    stage that was skipped. It is a **detector, not a gate**: it does not
    prevent the type mismatch — it only makes it diagnosable.
  * A **section log is a sibling leaf, never the lineage parent**. A body that
    groups its items calls `Executor.log_section(run, title,
    Context.input_step_id(ctx))` — passing the *source* parent, not the section's
    own id — so the real `step_logs` row it writes never becomes the parent of
    the steps under it. A section is an ordinary call in the body, not a
    declarative option.
  * `fan_out`'s `parent:` has two modes, and a pipeline picks the one its tree
    needs: `:source_stage` (default) parents every item's steps to the fan-out's
    source stage — a flat tree — while `:per_item` takes `input_step_id` from
    each item's **own** producing step log — a chained tree. Getting this wrong
    is invisible to a spot check and fatal to a structural-identity gate.

  ## Per-item failures on a sequential fan_out are NOT caught

  A **sequential** `fan_out`'s items run through `run_item/6` directly, with no
  wrapping `catch`. What survives a Step's own safety is infrastructure raising —
  pool exhaustion, a lost connection — and one of those should abort the run
  rather than be tallied as N individually-failed items under a `:success` run.
  There is deliberately no option to opt the sequential path into catching
  per-item failures.

  A `fan_out` with `concurrency > 1` is different, and not as a policy choice: it
  runs through `Task.async_stream`, which LINKS its children, so an uncaught
  raise or exit in one item kills the caller before the stream emits anything.
  Those are therefore **always** wrapped in `catch kind, reason` and degraded to
  `{:error, {:uncaught, kind, reason}}` — the rule `ALLM.Pipeline.FanOut`'s
  moduledoc states, applied once in the framework instead of at each call site.
  `rescue` alone is insufficient: an exit is not an exception.

  ## `resource` — a handle acquired once per run

      resource :browser, start: :open_browser, stop: :close_browser

  Acquired **once per run** before the first stage — not once per fan-out item —
  and released **before** the terminal write. Every step and body reads it
  as `ALLM.Pipeline.Context.resource(ctx, :browser)`: a struct field, never an
  `opts` key, because a resource is framework-managed state with a lifecycle and
  burying it in the caller's option list makes it indistinguishable from a CLI
  flag.

  Teardown runs on **every** exit path — success, a named failure, a raise, an
  exit and a throw — and every `stop` is wrapped in `catch kind, reason`
  covering all three kinds, because a Playwright or `GenServer` teardown
  surfaces as an exit rather than an exception. A teardown failure **never
  changes the terminal status**: the run's status is about the work, and a
  leaked handle is an operational fault recorded beside it under
  `metadata["resource_teardown_errors"]`. The ordering is the whole point —
  teardown after the write could not record a failure anywhere, because the row
  is already terminal. Full contract: `ALLM.Pipeline.Dsl.Resource`.

  > **What it's for.** `resource` exists for hosts whose steps hold an external
  > handle (a browser session, a DB connection) that must be released even when a
  > run raises. It closes a defect class by construction — a leaked handle on a
  > raise, which a bare `after` block cannot catch, because a Playwright or
  > `GenServer` teardown surfaces as an exit.

  ## Linking a child run

  A pipeline invoked as a child of another sets the queryable
  `pipeline_runs.parent_run_id` FK column by threading `parent_run_id:` in its
  `opts`: the generated self-owned `run/1` lifts it out of `opts` into
  `create_pipeline_run/3`'s attrs (`Dsl.Runtime.run_owned/3`), so it lands in
  the COLUMN rather than becoming a metadata key. No declarative construct is
  needed — a child is just another `run/1` call with `parent_run_id:` set.

  ## Running under a borrowed run

      use ALLM.Pipeline, name: "inner", borrowed_run: true

  An outer pipeline lends its run by putting it under the `:pipeline_run`
  opt. A pipeline declaring `borrowed_run: true` branches on
  `ALLM.Pipeline.Executor.borrowed_run/1`: given a lent run it executes its
  stages under that handle and creates and terminates **nothing** — the lending
  owner is the sole completer — and without one it is self-owned exactly as any
  other pipeline. The handle is non-owning, so a body's stray `complete/2` is a
  detectable `{:error, :not_run_owner}` rather than a mid-loop `:success` that
  clobbers the owner's aggregate metadata.

  Two consequences, both deliberate. A borrowed run records **no**
  `pipeline_metrics` row (the funnel would be attributed to the owner and
  double-count), and a resource teardown failure is **logged** rather than
  recorded, because there is no terminal write of this pipeline's own to hang it
  on. Under `returns: :run` the borrowed path hands back the borrowed run, which
  is still `:running` — the owner completes it later.

  The declaration is what gates the branch. `Executor.borrowed_run/1` is not
  consulted for a pipeline that does not declare `borrowed_run: true`, so a
  stray `:pipeline_run` opt cannot silently change any other pipeline's
  lifecycle.

  ## `--dry-run`

      use ALLM.Pipeline, name: "thumbnails", dry_run: :plan

  **The contract, stated once, here.** When a pipeline declares a `dry_run:`
  plan hook AND is run with a truthy `:dry_run` opt AND is **self-owned**, the
  framework creates the run, calls the hook, writes **one** `log_summary` row
  carrying the plan, completes the run, and returns the plan — all **before the
  first stage**, and therefore before the first external call.
  `Executor.run_step/5` is called zero times, and no `resource` is acquired, so
  a declared browser or authenticated session is never opened. (A `dry_run:`
  hook reading `Context.resource(ctx, :browser)` therefore gets `nil`: opening
  the handle *is* an external call, and the contract is "before the first
  one".)

  A pipeline that declares no `dry_run:` hook ignores the flag entirely: a
  pipeline with no declared plan has nothing to report, and skipping its work on
  a flag it never opted into would be a hidden behaviour change.

  ### `dry_run:` and `borrowed_run: true` are mutually exclusive

  Declaring **both** is a **compile error** (`ALLM.Pipeline.Dsl.__validate__!/2`),
  as `summary_type:` + `returns: :run` already is. There is no runtime branch for
  the pair, and the rejection is the whole implementation of the rule.

  The reason is a precedence that cannot be honoured: `run/1` resolves the lent
  run **before** the dry branch, so a declaration carrying both, invoked with a
  lent `:pipeline_run` and a truthy `:dry_run`, would run **every stage for real**
  with the flag silently dropped — no plan hook, no error, and an `{:ok, …}`
  return indistinguishable from a successful plan. That is the one shape in which
  "`--dry-run` did not stop the work" is reachable without a declaration bug, and
  `--dry-run` exists for cost avoidance. Inverting the precedence instead would
  need new runtime semantics for what a *dry borrowed* run writes, since it cannot
  complete a run it does not own — for a shape that has no consumer.

  The accepted cost: a pipeline cannot be dry-runnable when self-owned **and**
  lendable otherwise. A pipeline needing both splits into two declarations, or
  keeps a `skip_when: {:opt, :dry_run, false}` on its write stage (the second meaning
  below), which composes with `borrowed_run:` freely.

  **`--dry-run` means two different things, and the framework's `dry_run:`
  implements only the first.** The difference is what a pipeline author has to
  decide, and it is not visible from a flag name:

  | Meaning | Expressed as |
  |---|---|
  | **Skip everything.** Resolve the working set, log a section per item, complete. No step runs. | a `dry_run:` plan hook |
  | **Skip only the WRITE.** Earlier steps still run and still spend tokens (an LLM match, a fetch/transform); only the final write stage is skipped. | a `skip_when: {:opt, :dry_run, false}` body branch |

  A pipeline wanting the second meaning does **not** declare `dry_run:`; it
  keeps a `skip_when:` on its write stage, which is already expressible and
  leaves the earlier stages running.

  ## Ownership

  The generated `run/1` obtains its handle from
  `Executor.create_pipeline_run/3` and **the owning handle never leaves
  `Dsl.Runtime`** — not to a hook, and not through a return value. Every stage
  body, `over:`, `input:`, `skip_when:` and `summarize`
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
        only: [
          stage: 2,
          stage: 3,
          fan_out: 2,
          fan_out: 3,
          resource: 2,
          metrics: 2,
          summarize: 1
        ]

      Module.register_attribute(__MODULE__, :allm_pipeline_stages, accumulate: true)
      Module.register_attribute(__MODULE__, :allm_pipeline_resources, accumulate: true)

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
    resources = env.module |> Module.get_attribute(:allm_pipeline_resources) |> Enum.reverse()
    metrics = Module.get_attribute(env.module, :allm_pipeline_metrics)
    summarize = Module.get_attribute(env.module, :allm_pipeline_summarize)

    if specs == [] do
      raise ArgumentError,
            "#{inspect(env.module)}: a pipeline must declare at least one `stage` or `fan_out`."
    end

    assert_unique_names!(env.module, specs)
    assert_unique_resources!(env.module, resources)

    Dsl.__assert_hooks_defined__!(
      env,
      declaration.atom_hooks ++
        Enum.flat_map(specs, & &1.atom_hooks) ++
        Enum.flat_map(resources, & &1.atom_hooks) ++
        Module.get_attribute(env.module, :allm_pipeline_metrics_hooks) ++
        Module.get_attribute(env.module, :allm_pipeline_summarize_hooks)
    )

    stages_ast = Enum.map(specs, &Dsl.__stage_ast__/1)

    resources_ast =
      Enum.map(resources, fn resource ->
        quote do
          %ALLM.Pipeline.Dsl.Resource{
            name: unquote(resource.name),
            start: unquote(resource.start),
            stop: unquote(resource.stop)
          }
        end
      end)

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
      @spec run(keyword()) :: unquote(ALLM.Pipeline.__run_return__(declaration))
      def run(opts \\ []), do: ALLM.Pipeline.Dsl.Runtime.run(__MODULE__, opts)

      @doc false
      @spec __pipeline__(:name | :stages | :metrics | :concurrency | :hooks | :resources) ::
              term()
      def __pipeline__(:name), do: unquote(declaration.name)
      def __pipeline__(:concurrency), do: unquote(declaration.concurrency)
      def __pipeline__(:stages), do: unquote(stages_ast)
      def __pipeline__(:resources), do: unquote(resources_ast)
      def __pipeline__(:metrics), do: unquote(metrics_ast)

      def __pipeline__(:hooks) do
        %{
          metadata: unquote(declaration.metadata),
          complete_metadata: unquote(declaration.complete_metadata),
          init: unquote(declaration.init),
          summarize: unquote(summarize),
          returns: unquote(declaration.returns),
          borrowed_run: unquote(declaration.borrowed_run),
          dry_run: unquote(declaration.dry_run)
        }
      end

      defoverridable run: 1
    end
  end

  @doc false
  # The generated `run/1`'s return type. Without `summary_type:` it is
  # `{:ok, term()}`, which silently stops dialyzer type-checking every consumer
  # of a ported pipeline's stats map — measured on the first port, whose CLI
  # reads `stats.meetings_found` off what became `term()`. A using module cannot
  # add its own `@spec run/1` (it would collide with the generated one), so the
  # affordance has to live here.
  @spec __run_return__(Dsl.declaration()) :: Macro.t()
  def __run_return__(%{returns: :run}) do
    quote do: {:ok, ALLM.Pipeline.PipelineRun.t()} | {:error, term()}
  end

  def __run_return__(%{summary_type: nil}) do
    quote do: {:ok, term()} | {:error, term()}
  end

  def __run_return__(%{summary_type: type}) do
    quote do: {:ok, unquote({type, [], []})} | {:error, term()}
  end

  @spec assert_unique_resources!(module(), [Dsl.resource_spec()]) :: :ok
  defp assert_unique_resources!(module, resources) do
    duplicates =
      resources
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(&(elem(&1, 1) > 1))
      |> Keyword.keys()

    if duplicates != [] do
      raise ArgumentError,
            "#{inspect(module)}: duplicate resource name(s) #{inspect(duplicates)}. " <>
              "A resource name keys `ALLM.Pipeline.Context.resource/2`, so a duplicate " <>
              "would make one of the two handles unreachable and leak it."
    end

    :ok
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
