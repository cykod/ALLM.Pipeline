defmodule ALLM.Pipeline.Schema.JsonSchemaCrossFileTest do
  @moduledoc """
  A nested schema living in a SEPARATE FILE, compiled in the same batch as its
  parent.

  `json_schema_test.exs`'s `Parent`/`KeyProvision` fixture declares the nested
  module *inside* its parent, so the nested module is already defined by the
  time the parent's `@before_compile` hook runs. That arrangement cannot fail
  the way this one can, which is why this file exists rather than another
  fixture over there.

  What it pins: `JsonSchema.schema_module?/1` must use `Code.ensure_compiled/1`,
  which participates in `Kernel.ParallelCompiler`'s module handshake, and not
  `Code.ensure_loaded?/1`, which does not. Measured inside a live parallel
  compile, for a sibling module in the same batch:

      ensure_loaded?=false   ensure_compiled=true

  With `ensure_loaded?/1` the parent below fails to compile with
  "`field :headline` resolves to `Leaf.t()`, which has no strict-mode JSON
  rendering" — an error naming a nested module that is perfectly correct, and
  whose suggested remedies are all already applied. The tree's own convention is
  `<step>/{input,output}.ex`, so this layout is one refactor away at all times.

  `Kernel.ParallelCompiler.compile/1` is used directly because that is the
  compiler `mix compile` drives; `Code.require_file/1` and `mix run` both
  evaluate serially and would pass against either implementation.
  """

  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../../../fixtures/cross_file_schema", __DIR__)

  test "a nested schema in a sibling file resolves under the parallel compiler" do
    # Parent FIRST: the order that loses the race under `ensure_loaded?/1`.
    # (Measured: leaf-first fails identically — they compile concurrently — but
    # parent-first is the deterministic statement of intent.)
    files = [Path.join(@fixture_dir, "parent.ex"), Path.join(@fixture_dir, "leaf.ex")]

    assert {:ok, modules, _warnings} = Kernel.ParallelCompiler.compile(files)
    assert ALLMPipelineCrossFileFixture.Parent in modules
    assert ALLMPipelineCrossFileFixture.Leaf in modules

    schema = ALLMPipelineCrossFileFixture.Parent.__allm_schema__(:json_schema)
    props = schema["properties"]

    # Genuinely recursed, rather than compiling by accident into a scalar or an
    # empty object: the nested node carries its own closed-object envelope and
    # its own full `required`, at both bare-field and array-`items` depth.
    assert props["headline"]["type"] == ["object", "null"]
    assert props["headline"]["additionalProperties"] == false
    assert Enum.sort(props["headline"]["required"]) == ~w(detail label)

    assert %{"type" => "array", "items" => items} = props["provisions"]
    assert items["additionalProperties"] == false
    assert Enum.sort(items["required"]) == ~w(detail label)
    assert items["properties"]["detail"]["type"] == ["string", "null"]
  end
end
