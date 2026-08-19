# Deliberately OUTSIDE `elixirc_paths` (`lib` + `test/support`): this file is
# compiled by `json_schema_cross_file_test.exs` through
# `Kernel.ParallelCompiler.compile/1`, in ONE batch with `parent.ex`, because
# that is the only arrangement in which `Code.ensure_loaded?/1` and
# `Code.ensure_compiled/1` differ. A fixture nested inside its parent — the
# shape `json_schema_test.exs` already covers — is structurally incapable of
# failing that way.
defmodule ALLMPipelineCrossFileFixture.Leaf do
  @moduledoc false
  use ALLM.Pipeline.Schema, json_schema: true

  schema do
    field(:label, String.t(), required: true)
    field(:detail, String.t())
  end
end
