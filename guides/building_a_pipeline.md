# Building a pipeline

This guide builds a pipeline end to end: a typed `ALLM.Pipeline.Step`, an
LLM-calling step, a `use ALLM.Pipeline` declaration that composes them, the run
that executes it, and the reads that walk its step logs, lineage and artifacts.
It is the **application** companion to
[the host-wiring guide](host_wiring.md), which is the **wiring** reference —
the repo, the seam adapters, and the table DDL a host supplies at boot. Wire
the framework in following that guide first; this one assumes a wired host and
concerns what you author on top of it.

Like the host-wiring guide, this one **points at** the normative moduledocs
rather than duplicating them — each section names the module whose `@moduledoc`
is the source of truth, and the links stay live in hexdocs. Throughout,
`MyApp` stands for your host application; the code is illustrative but
compilable in shape. The package's own `test/support/` modules are the working
reference for every construct shown here.

## 1. A typed step

A step is a module implementing the `ALLM.Pipeline.Step` behaviour: it declares
its `step_type/0`, an `input_schema/0` and `output_schema/0`, and an
`execute/2` that turns a typed Input struct into a typed Output. The Input and
Output are structs generated from a field declaration — the `input_schema do …
end` / `output_schema do … end` blocks below, or the same declaration written
out as a module of its own under `use ALLM.Pipeline.Schema` — with less
boilerplate than a hand-written `defstruct` plus `@type` plus `@enforce_keys`.
`ALLM.Pipeline.Schema`'s moduledoc is the
authority for the field options (`required:`, `default:`, `artifact:`,
`redact:`, `log:`, and the LLM-facing `values:` / `description:` / `wire:`).

```elixir
defmodule MyApp.ListStep do
  use ALLM.Pipeline.Step

  input_schema do
    field :source_url, String.t(), required: true
  end

  output_schema do
    field :records, [map()], required: true
    field :raw_html, String.t(), artifact: true
  end

  @impl true
  def step_type, do: :list

  @impl true
  def execute(_ctx, %Input{source_url: url}) do
    html = fetch(url)
    {:ok, %Output{records: parse(html), raw_html: html}}
  end
end
```

`use ALLM.Pipeline.Step` injects the behaviour and imports `input_schema/2` and
`output_schema/2`, which declare the nested `Input` / `Output` modules and
derive `input_schema/0` / `output_schema/0` from them. Write either module out
by hand instead — nested, or in its own file — when it is shared by two steps
or wants a moduledoc of its own, and write that accessor yourself;
`@behaviour ALLM.Pipeline.Step` on its own remains valid and generates nothing.

The `artifact: true` field is the convention for a heavy body (scraped HTML,
extracted text) that belongs in the artifact store rather than inline in the
`step_logs` row; `ALLM.Pipeline.StepLog`'s moduledoc documents how the flag,
together with `log: false`, keeps large values out of `input_data` /
`output_data`.

A step is executed with lineage through `ALLM.Pipeline.Executor.run_step/5`,
which builds the `ALLM.Pipeline.Context` the step receives, validates the
Input, records a `step_logs` row, and stores any declared artifact. When you
compose steps with the DSL (section 4) you never call `run_step/5` by hand —
the generated `run/1` threads it for you.

## 2. An LLM step

An LLM-calling step is authored with `use ALLM.Pipeline.LLMStep`, which
generates the whole call path from the Output declaration: the `step_type/0` /
`input_schema/0` / `output_schema/0` callbacks, the strict-mode JSON schema
(`json_schema/0`), the LLM call (`call_llm/1`), the parse into the Output
struct (`coerce/2`), and the composed `execute/2`. `ALLM.Pipeline.LLMStep`'s
moduledoc is the authority for what it generates and what it checks at compile
time. The Output is declared with `json_schema: true` — defaulted on by the
block below — which makes the wire schema a derived artifact of the declaration
rather than a second hand-written description.

```elixir
defmodule MyApp.SummarizeStep do
  use ALLM.Pipeline.LLMStep,
    type: :summarize,
    engine: :nano,
    schema_name: "record_summary"

  input_schema do
    field :record, map(), required: true
  end

  output_schema do
    field :summary, String.t(), required: true, description: "A one-line summary"
    field :importance, atom(), values: [:low, :medium, :high]
    field :tokens_used, integer(), wire: false
  end

  def prompt(%Input{record: record}), do: "Summarize this record: #{inspect(record)}"
end
```

The blocks are the same `input_schema/2` / `output_schema/2` as above, with one
difference: here `output_schema` defaults `json_schema: true` on, because an LLM
step's wire contract IS its Output declaration. `input:` / `output:` default to
the nested modules the blocks generate; pass them explicitly to point at schema
modules declared elsewhere. `prompt/1` takes no `@impl` — it is required by the
macro, not by the `ALLM.Pipeline.Step` behaviour, so `@impl true` on it warns.

The only thing the using module must supply is `prompt/1`. The `wire: false`
field (`tokens_used`) is populated by the harness from the response envelope,
not by the model; the `values:` field is coerced against its declared
vocabulary rather than through `String.to_atom/1`. The generated `execute/2` is
overridable when a step needs control flow (a conditional second call), and an
overriding `execute/2` still calls the generated `coerce/2` to get the parse
for free — see the `ALLM.Pipeline.LLMStep` moduledoc.

An LLM step needs the `llm:` seam wired; a host that runs no LLM steps may omit
it (see [the host-wiring guide](host_wiring.md) section 2).

## 3. Composing a pipeline

`use ALLM.Pipeline` turns a module into a pipeline: it owns the run skeleton —
run creation, lineage-threaded step sequencing, the guard that fails and
reraises, metrics, the terminal complete — so the module declares stages, not
boilerplate. `ALLM.Pipeline`'s moduledoc is the authority for the full DSL; the
declaration below exercises a `stage` targeting a Step, a declarative `fan_out`
over a Step, `metrics`, and `summarize`.

```elixir
defmodule MyApp.ReportPipeline do
  use ALLM.Pipeline,
    name: "report",
    init: :init_acc,
    summary_type: :stats

  # A `stage` naming a Step module runs it through the Executor, threading
  # lineage. `input:` names a hook that builds the Step's Input from `prev`.
  stage :list, MyApp.ListStep, input: :build_list_input

  # A declarative `fan_out` runs a Step module once per item. The framework
  # owns the per-item lineage, the link-safe catch, and the `%Item{}` wrapping.
  fan_out :summarize, MyApp.SummarizeStep, over: :records, input: :build_summary_input

  metrics "records", from: :funnel
  summarize :finalize

  @type stats :: %{summarized: non_neg_integer()}

  defp init_acc, do: %{summarized: 0}
  defp build_list_input(_ctx, _prev), do: %MyApp.ListStep.Input{source_url: "https://example.com"}
  defp build_summary_input(_ctx, record), do: %MyApp.SummarizeStep.Input{record: record}
  defp funnel(acc), do: %{summarized: acc.summarized}
  defp finalize(acc, _ctx), do: %{summarized: acc.summarized}
end
```

A few contracts worth knowing, each stated normatively in `ALLM.Pipeline`'s
moduledoc:

- **`fan_out` targets a Step module only.** Folding an ordinary body over items
  (with a running accumulator, a section log, a politeness delay) is done in a
  plain `stage` whose body calls `ALLM.Pipeline.FanOut.reduce/5` — the
  declarative form is the Step-module case.
- **The accumulator's only write channel is a body's `{item_result, acc}`
  return.** A count the pipeline needs to keep — a skip tally, a funnel input —
  rides that second element; `metrics from:` always receives the accumulator.
- **`summarize` runs before the terminal write**, so what `run/1` returns
  (`summarize`, or the completed run under `returns: :run`), what
  `ALLM.Pipeline.PipelineRun.complete/2` writes (`complete_metadata:`), and what
  `metrics` records (`from:`) are three distinct hooks.
- Inside a body, the current lineage parent, the accumulator, and any declared
  `resource` are read through `ALLM.Pipeline.Context` —
  `ALLM.Pipeline.Context.input_step_id/1`,
  `ALLM.Pipeline.Context.accumulator/1`, `ALLM.Pipeline.Context.resource/2`.

## 4. Running it

`use ALLM.Pipeline` generates `run/1`. Calling it creates the run, executes the
stages in declaration order under a guard, records metrics, and writes the
terminal `complete/2` or `fail/2`:

```elixir
{:ok, stats} = MyApp.ReportPipeline.run([])
```

`run/1` returns `{:ok, summary}` by default (the `summarize` return), or the
completed `%ALLM.Pipeline.PipelineRun{}` under `returns: :run`. It accepts
`run_name:` to override `name:` for a mode variant and `parent_run_id:` to link
a child run's FK column — both in `ALLM.Pipeline`'s moduledoc. On a raise the
guard fails the run and reraises, so a run always reaches a terminal status.

## 5. Reading a run back

`ALLM.Pipeline.Query` is the package-owned, read-only facade for a host's
provenance and lineage reads. Route reads through it rather than hand-writing
`"step_logs"` / `"pipeline_runs"` queries; its moduledoc is the authority for
why it exposes no write path.

```elixir
# The run and its step logs.
run = ALLM.Pipeline.Query.get_run(run_id)

# Aggregate counts for a run (total / successful / failed / skipped steps).
stats = ALLM.Pipeline.Query.run_stats(run_id)

# The lineage tree from a step upward to its root ancestor.
{:ok, lineage} = ALLM.Pipeline.Query.lineage_tree(step_log_id)

# Resolve a step log's identity to %{run_id, pipeline_name, step_type}.
identity = ALLM.Pipeline.Query.resolve_step_log(step_log_id)
```

The step logs form a **flat two-level lineage tree**: every fan-out item's
steps parent to the producing stage rather than chaining, and a skip is a
sibling leaf, never an ancestor. `ALLM.Pipeline.StepLog`'s moduledoc documents
the lineage model and `ALLM.Pipeline.StepLog.build_lineage_tree/1`, which
`ALLM.Pipeline.Query.lineage_tree/1` delegates to.

Artifact bodies — the heavy values a step declared with `artifact: true` — are
fetched by their URL through `ALLM.Pipeline.Query.fetch_artifact/1`, which
delegates to `ALLM.Pipeline.ArtifactStore.fetch/1`. The store owns compression,
checksum and size accounting; `ALLM.Pipeline.ArtifactStore`'s and
`ALLM.Pipeline.Artifacts`' moduledocs are the reference for the wrapper and the
tiered DynamoDB/S3 backends.

## Where to go next

- [Host-wiring guide](host_wiring.md) — the registry declaration, the seams,
  the production DDL, and the test-suite pattern that make the code above run.
- `ALLM.Pipeline` — the full DSL: skips, sections, resources, borrowed runs,
  `--dry-run`, and the lineage rules.
- `ALLM.Pipeline.Schema`, `ALLM.Pipeline.Step`, `ALLM.Pipeline.LLMStep` — the
  authoring contracts.
- `ALLM.Pipeline.Query` — the read facade for step logs, lineage and artifacts.
