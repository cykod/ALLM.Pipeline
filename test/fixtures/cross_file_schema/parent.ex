# See `leaf.ex`. The `alias` is what makes the short-alias resolution path the
# one under test, matching how every nested schema in this tree is referenced.
defmodule ALLMPipelineCrossFileFixture.Parent do
  @moduledoc false
  use ALLM.Pipeline.Schema, json_schema: true

  alias ALLMPipelineCrossFileFixture.Leaf

  schema do
    field(:title, String.t(), required: true)
    field(:headline, Leaf.t())
    field(:provisions, [Leaf.t()], default: [])
  end
end
