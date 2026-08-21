defmodule ALLM.Pipeline.TestSupport.TargetDeclaration do
  @moduledoc """
  **The acceptance spec for Phase 4.1, transcribed as a compiling module.**

  This is `steering/2026-08-20_ALLM_PIPELINE_PHASE_4.md` §"The target
  declaration" — what **4.1 specified** for `MeetingAgendaPipeline` — against
  stub Steps. It exists so the hardest pipeline in the tree drives the construct
  set **before** any of it is written, and so a construct silently dropped from
  the DSL fails a test in this package rather than surfacing during the port.

  ⚠️ **It is 4.1's SPEC, not a transcript of the shipped port.** 4.2 shipped a
  declaration that diverges — notably a fourth `stage :tally` after the fan-out —
  for reasons recorded as `…PHASE_4_RECORDS.md` → "4.2 — Deviations" D-8 and D-9.
  Do **not** read the declaration below as the canonical usage, and do **not**
  "fix" it to match the port. (Phase 4.5.3 removed the `gate:` option entirely,
  so the fixture no longer carries the `gate: :meeting_decision` it originally
  used to give that construct its only compile-time exercise.)

  It is a **fixture, not the port**. It runs nothing; `dsl_test.exs` only reads
  its `__pipeline__/1`. Two consequences to keep in mind when editing it:

  * The module name is a package name. `apps/allm_pipeline` deliberately
    declares no umbrella dependency, so `AmesburyScraper.Pipelines.*` and its
    real Steps cannot be named here — that is a compile error by design
    (`apps/allm_pipeline/CLAUDE.md` §1). The *shape* is what is being proven,
    not the names.
  * Every hook below is a `defp`. That is the point of the atom form: a hook
    atom expands to a local capture at `__before_compile__`, when the function
    is already defined, so it never has to be public (D6).

  Lives under `test/support/`, which `mix.exs` puts on `elixirc_paths(:test)` —
  so it compiles with the suite and a construct regression is a *compile*
  failure, the strongest gate available.
  """

  defmodule MeetingListScraper do
    @moduledoc "Stub Step standing in for the host's real meeting-list scraper."
    @behaviour ALLM.Pipeline.Step

    # `ALLM.Pipeline.Schema`, not a bare `embedded_schema`: this module IS
    # compiled into `_build` (it is on `elixirc_paths(:test)`), so it is visible
    # to the host's `step_schema_census_test.exs`, whose whole job is to notice
    # a Step whose schemas are not DSL modules and therefore skip
    # `Executor.validate_against/3`'s contract checks. A stub that trips that
    # census would be a fixture teaching the wrong shape.
    defmodule Input do
      @moduledoc false
      use ALLM.Pipeline.Schema

      schema do
        field(:source_url, String.t(), required: true)
        field(:months_back, integer(), default: 6)
      end
    end

    defmodule Output do
      @moduledoc false
      use ALLM.Pipeline.Schema

      schema do
        field(:meetings, [map()], default: [])
      end
    end

    @impl true
    def step_type, do: :target_declaration_meeting_list

    @impl true
    def input_schema, do: Input

    @impl true
    def output_schema, do: Output

    @impl true
    def execute(_context, %Input{}), do: {:ok, %Output{meetings: []}}
  end

  use ALLM.Pipeline,
    name: "meeting_agenda_scrape",
    # (opts) -> map, for create_pipeline_run/3
    metadata: :run_metadata,
    # (acc) -> map, for complete/2 — NOT the same value
    complete_metadata: :serialize_metrics,
    # () -> the accumulator
    init: :init_metrics,
    concurrency: 1

  stage(:committee_cache, fn _ctx, _prev -> {:ok, ensure_committee_cache()} end)
  stage(:list, MeetingListScraper, input: :build_list_input)

  # Since Phase 4.5 a `fan_out` is Step-target only (the `body:`-mode form was
  # removed in 4.5.2, and `gate:` in 4.5.3).
  fan_out(:meeting, MeetingListScraper,
    # (prev_output) -> [item]
    over: :meetings_from,
    # flat tree: every leaf parents to :list's step log
    parent: :source_stage,
    # (ctx, item) -> Step input struct
    input: :meeting_input
  )

  metrics("meetings", from: :funnel)

  # (acc, ctx) -> stats()
  summarize(:finalize)

  # ── The hooks. Every one is private, which is the whole point of the atom form.

  defp ensure_committee_cache, do: :ok

  defp run_metadata(opts), do: %{options: opts}

  defp serialize_metrics(metrics), do: metrics

  defp init_metrics, do: %{meetings_found: 0, meetings_processed: 0, errors: []}

  defp build_list_input(ctx, _prev) do
    MeetingListScraper.Input.new(
      source_url: ALLM.Pipeline.Context.get_opt(ctx, :source_url, "https://example.test"),
      months_back: ALLM.Pipeline.Context.get_opt(ctx, :months_back, 6)
    )
  end

  defp meetings_from(%MeetingListScraper.Output{meetings: meetings}), do: meetings

  defp meeting_input(_ctx, _meeting),
    do: MeetingListScraper.Input.new(source_url: "https://example.test")

  defp funnel(stats), do: %{found: stats.meetings_found, processed: stats.meetings_processed}

  defp finalize(acc, _ctx), do: acc
end
