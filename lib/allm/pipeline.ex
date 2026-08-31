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

  The example below is the declaration `meeting_agenda` **actually ships** as of
  Phase 4.5 — not a sketch. Its per-meeting fan-out is a plain `stage` whose body
  calls `ALLM.Pipeline.FanOut.reduce/5`: Phase 4.5 retired `body:`-mode `fan_out`
  (and its `section:`/`delay:` sub-surface) in favour of ordinary code, keeping
  declarative `fan_out` for Step-module targets only.

      defmodule MeetingAgendaPipeline do
        use ALLM.Pipeline,
          name: "meeting_agenda_scrape",
          metadata: :run_metadata,
          complete_metadata: :serialize_metrics,
          init: :init_metrics,
          concurrency: 1,
          summary_type: :stats

        stage :committee_cache, fn _ctx, _prev -> {:ok, ensure_committee_cache()} end
        stage :list, MeetingListScraper, input: :build_list_input

        # The per-meeting fan-out is a plain `stage` whose body calls
        # `FanOut.reduce/5`. The framework owns the link-safe catch, the `%Item{}`
        # wrapping and per-item lineage; the section log and the politeness delay
        # are ordinary code in the body below.
        stage :meeting, :fan_out_meetings

        # Run-level counters folded into the accumulator AFTER the fan-out, because
        # `complete_metadata:` is handed the ACCUMULATOR, not what `summarize`
        # returned. An escape-hatch stage writes no step log and does not move the
        # lineage parent, so a structural-identity gate does not see it.
        stage :tally, :tally_run

        metrics "meetings", from: :funnel
        summarize :finalize
      end

      # The `:meeting` stage body. `FanOut.reduce/5` folds `fold_one/3` over the
      # scraped meetings, threading the accumulator; the outer 2-tuple `{:ok, items}`
      # is lineage-transparent, so `:tally` still receives the `[Item.t()]` list.
      defp fan_out_meetings(ctx, prev) do
        {items, acc} =
          FanOut.reduce(ctx, prev.meetings, Context.accumulator(ctx), &fold_one/3,
            parent: :source_stage)

        {{:ok, items}, acc}
      end

  ## Counting a skip — the accumulator's only write channel

  The accumulator's **only** write channel is a body's `{item_result, acc}`
  return. So a skip the pipeline needs to COUNT — in its `metrics` funnel's
  `skipped:`, in `pipeline_runs.metadata`, in its own `summarize` return — must
  keep the decision **inside the body** and return `{{:skipped, payload},
  updated_acc}`. `meeting_agenda` does exactly that; the reasoning is
  `steering/2026-08-20_ALLM_PIPELINE_PHASE_4_RECORDS.md` → 4.2 Deviations D-8 and
  D-9. Since Phase 7.4 the body ALSO calls `Executor.log_skipped/4` before that
  return, so the skip is a visible `:skipped` step log with its reason — the
  count still rides the accumulator (the log adds observability, not the count).

  (Phase 4 had a declarative `gate:` fan_out option that looked like the way to
  express "skip this item". It wrote **no step log** and could not touch the
  accumulator, so declaring it zeroed any skip count silently and in every place
  at once. It was removed in Phase 4.5.3 for exactly that reason —
  `steering/ALLM_PIPELINE_DSL.md` §4.2 carries the lesson. Phase 7.4 did NOT
  resurrect it: the skip log is written by an ordinary body call that keeps the
  `{{:skipped, payload}, acc}` return, not by a declarative option.)

  ## The scope is the SKELETON, not the body

  The DSL owns run creation, the lineage parent, fan-out, skips, metrics and the
  terminal write. It wraps a per-item body that stays an **ordinary Elixir
  function** — and a section log and a politeness delay are now ordinary calls in
  that body, not `section:`/`delay:` options (removed in Phase 4.5.2). So
  `meeting_agenda`'s
  `process_single_meeting/2` and the call graph under it, the largest body in the
  tree, with its runtime Step-module selection by committee name, is untouched by
  the port. (This read "~600-line" until 2026-08-20; the real figure was ~750 and
  the number had already been copied once into the host's own moduledoc. A count
  of a HOST file cannot be re-derived from this package, so it is not written
  here.) That is the design working, not a
  shortfall: an honest read of eight orchestrators against a *full* declarative
  construct set found 2 of 8 expressible.

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
  (`meeting_list_only` vs `meeting_agenda_scrape`); the run-name *set* is Phase
  6's.

  ## The item-result contract

  Every escape-hatch `stage` body returns one of (a `fan_out` targets a Step
  module and has no body — its item results come from the Step's `execute/2`):

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
    last *successfully executed* step's log id — a skip row never becomes the
    lineage PARENT of what follows. Since Phase 7.4 a `*ProcessingDecision`
    skip DOES write a step log (a visible `:skipped` row via
    `Executor.log_skipped/4` → `StepLog.create_skipped/4`), parented like the
    processed step would have been, so it appears in `build_lineage_tree/1` at
    the position the work would occupy — but as a sibling leaf, not an ancestor
    (exactly like a `section`). Through Phase 6 the skip wrote nothing at all
    (D8); promoting it was a behaviour change a structural-identity gate could
    not absorb, which is why it waited for Phase 7 (the first phase whose gate
    is not structural identity).
    A skip is also **subject-transparent**: `prev` stays whatever the stage
    BEFORE the skip produced, so the next stage silently receives it. Three
    paths do this — `skip_when:` fired, a body returning `{:skipped, _}`, and
    `on_error: :continue` swallowing an error — and each **names the struct
    `prev` is carrying in its skip log line** (§9.1), so a downstream
    `FunctionClauseError` in an `input:` hook is one line below the name of the
    stage that was skipped. It is a **detector, not a gate**: it does not
    prevent the type mismatch (that would need a declared `skip_to:`
    pass-through, deferred to Phase 5) — it only makes it diagnosable.
  * A **section log is a sibling leaf, never the lineage parent**. A body that
    groups its items calls `Executor.log_section(run, title,
    Context.input_step_id(ctx))` — passing the *source* parent, not the section's
    own id — so the real `step_logs` row it writes never becomes the parent of
    the steps under it. (Phase 4 had a `section:` fan_out option that did this
    automatically; 4.5.2 removed it, so a section is now an ordinary call in the
    body — `meeting_agenda`'s `fold_one/3` is the worked example.)
  * `fan_out`'s `parent:` has two modes and both ports need a different one:
    `:source_stage` (default) parents every item's steps to the fan-out's source
    stage — `meeting_agenda`'s flat tree — while `:per_item` takes
    `input_step_id` from each item's **own** producing step log, which is
    `committee`'s chain. Getting this wrong is invisible to a spot check and
    fatal to the gate.

  ## Per-item failures on a sequential fan_out are NOT caught

  A **sequential** `fan_out`'s items run through `run_item/6` directly, with no
  wrapping `catch`. What survives a Step's own safety is infrastructure raising —
  pool exhaustion, a lost connection — and one of those should abort the run
  rather than be tallied as N individually-failed items under a `:success` run.
  (Phase 5 removed the `catch_item_failures:` option that could opt into catching
  on the sequential path; no pipeline consumed it.)

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
  and released **before** the terminal write (D3). Every step and body reads it
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

  > **Kept with its one consumer.** `resource` is wired into a consumer's
  > enrichment pipeline (Phase 5.2). It is the
  > sanctioned exception to the "earn its keep across more than one pipeline" bar
  > (`steering/ALLM_PIPELINE_DSL.md` §6.2) **because it closes a named §1 defect
  > class by construction** — a leaked handle on a raise, which a bare `after`
  > block cannot catch (a Playwright/`GenServer` teardown surfaces as an exit).

  ## Linking a child run

  A ported pipeline invoked as a child of another (`ProjectEnrichmentPipeline`
  is a child of `ProjectRefreshPipeline`) sets the queryable
  `pipeline_runs.parent_run_id` FK column by threading `parent_run_id:` in its
  `opts`: the generated self-owned `run/1` lifts it out of `opts` into
  `create_pipeline_run/3`'s attrs (`Dsl.Runtime.run_owned/3`), so it lands in
  the COLUMN rather than becoming a metadata key. No declarative construct is
  needed — a child is just another `run/1` call with `parent_run_id:` set.
  (Phase 5 removed the `child_pipeline` construct: it had no production consumer,
  and the one intended one, `project_refresh`, cannot adopt it — it injects the
  child module at runtime as a test seam and chains two children per item. See
  `steering/ALLM_PIPELINE_DSL.md` §6.2.)

  ## Running under a borrowed run

      use ALLM.Pipeline, name: "inner", borrowed_run: true

  An umbrella pipeline lends its run by putting it under the `:pipeline_run`
  opt. A pipeline declaring `borrowed_run: true` branches on
  `ALLM.Pipeline.Executor.borrowed_run/1`: given a lent run it executes its
  stages under that handle and creates and terminates **nothing** — the umbrella
  owner is the sole completer — and without one it is self-owned exactly as any
  other pipeline. The handle is non-owning, so a body's stray `complete/2` is a
  detectable `{:error, :not_run_owner}` rather than a mid-loop `:success` that
  clobbers the umbrella's aggregate metadata.

  Two consequences, both deliberate. A borrowed run records **no**
  `pipeline_metrics` row (the funnel would be attributed to the umbrella and
  double-count), and a resource teardown failure is **logged** rather than
  recorded, because there is no terminal write of this pipeline's own to hang it
  on. Under `returns: :run` the borrowed path hands back the borrowed run, which
  is still `:running` — the umbrella completes it later.

  The declaration is what gates the branch. `Executor.borrowed_run/1` is not
  consulted for a pipeline that does not declare `borrowed_run: true`, so a
  stray `:pipeline_run` opt cannot silently change any other pipeline's
  lifecycle.

  ## `--dry-run`

      use ALLM.Pipeline, name: "poi_thumbnails", dry_run: :plan

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

  **`--dry-run` means two different things in the four hand-written host
  implementations, and the framework implements only the first.** They are named
  here because the difference is what a porter has to decide, and it is not
  visible from either pipeline's flag name:

  Most of these hosts are now ported (Phase 5), so the "Host implementation"
  column is the *pre-port* shape and the "Ports as" column is what each shipped;
  only `ProjectRefreshPipeline` remains hand-written.

  | Pre-port host implementation | Meaning | Ported as |
  |---|---|---|
  | `PoiThumbnailPipeline` (was `run_dry/2`) | **Skip everything.** Resolve the working set, log a section per item, complete. No step runs. | `dry_run:` hook (Phase 5.8) |
  | `ProjectRefreshPipeline` | **Skip everything.** Compute the cohorts, log the summary, invoke no sub-pipeline. | not ported — stays hand-written |
  | `VideoPipeline` | **Skip only the WRITE.** The LLM match step still runs and still spends tokens; only `apply_assignments/1` is skipped. | a `skip_when: {:opt, :dry_run, false}` body branch (Phase 5.7) |
  | `RvcsPipeline` | **Skip only the WRITE.** Agenda and minutes are still fetched and transformed; only the loader is skipped. It also increments `meetings_processed` on the dry path, which the framework version does not. | a `skip_when: {:opt, :dry_run, false}` body branch (Phase 5.7) |

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
