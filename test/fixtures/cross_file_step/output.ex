# Deliberately OUTSIDE `elixirc_paths` (`lib` + `test/support`): compiled by
# `json_schema_cross_file_test.exs` through `Kernel.ParallelCompiler.compile/1`,
# in ONE batch with `step.ex` and `input.ex`. That is the layout every real LLM
# step in this tree has — `<step>.ex` beside `<step>/{input,output}.ex` — and
# the only arrangement in which `Code.ensure_loaded?/1` and
# `Code.ensure_compiled/1` differ.
defmodule ALLMPipelineCrossFileStepFixture.Output do
  @moduledoc false
  use ALLM.Pipeline.Schema, json_schema: true

  schema do
    field(:tokens_used, integer(), wire: false)
    field(:ai_summary, String.t(), wire: "summary")
    field(:kind, atom(), values: [:alpha, :beta], required: true)
  end
end
