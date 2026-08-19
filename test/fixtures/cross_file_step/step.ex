# See `output.ex`. The `alias` + short reference is how every step in this tree
# names its Output; `input:` names a SECOND sibling file, so both compile-time
# module probes (`assert_input_struct!/2` and `assert_derives_json_schema!/2`)
# are exercised across the file boundary rather than only one of them.
defmodule ALLMPipelineCrossFileStepFixture.Step do
  @moduledoc false

  alias ALLMPipelineCrossFileStepFixture.Input
  alias ALLMPipelineCrossFileStepFixture.Output

  use ALLM.Pipeline.LLMStep,
    type: :cross_file,
    input: Input,
    output: Output,
    engine: :nano,
    schema_name: "cross_file"

  @spec prompt(Input.t()) :: String.t()
  def prompt(%Input{} = input), do: "cross file: #{input.subject}"
end
