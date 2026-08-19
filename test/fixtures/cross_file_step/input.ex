# See `output.ex` for why this fixture pair lives outside `elixirc_paths`. This
# module is the step's INPUT, in its own file for the same reason the Output is:
# `LLMStep.__before_compile__`'s `assert_input_struct!/2` faces the same
# `ensure_loaded?/1` vs `ensure_compiled/1` handshake, in the layout every
# ported transformer uses (`<step>.ex` beside `<step>/{input,output}.ex`).
defmodule ALLMPipelineCrossFileStepFixture.Input do
  @moduledoc false
  use ALLM.Pipeline.Schema

  schema do
    field(:subject, String.t(), required: true)
    field(:hint, String.t())
  end
end
