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

  **The same hazard has a SECOND site since 3.2.** `ALLM.Pipeline.LLMStep`'s
  `__before_compile__` probes its `output:` module for
  `__allm_schema__(:json_schema)` — because 3.1's derivation is opt-in, and a
  step whose Output forgot the option would otherwise compile clean and fail on
  its first live call. That probe faces exactly the arrangement above, and more
  often: `<step>.ex` beside `<step>/output.ex` is not a refactor away, it is the
  convention every ported transformer already follows. The second test below
  pins it, with its own fixture trio in `test/fixtures/cross_file_step/` —
  `input.ex` too, because `LLMStep`'s `assert_input_struct!/2` probes that
  module across the same boundary.
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

    # `apply/3` for the same reason as the second test below: the fixture does
    # not exist at THIS file's compile time, so a direct call is an "undefined
    # function" warning. It was latent until 3.2 — `mix precommit` does not pass
    # `--warnings-as-errors` to `mix test`, and a cached `_build` re-emits
    # nothing, so it only fires on a compile of this file.
    schema = apply(ALLMPipelineCrossFileFixture.Parent, :__allm_schema__, [:json_schema])
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

  @step_fixture_dir Path.expand("../../../fixtures/cross_file_step", __DIR__)

  test "an LLMStep resolves its Output when that Output is a sibling file in the same batch" do
    # Step FIRST — the order that loses the race under `ensure_loaded?/1`. With
    # that probe the step fails to compile with "does not answer
    # `__allm_schema__(:json_schema)`", pointing at an Output that declares
    # `json_schema: true` and is entirely correct.
    files = [
      Path.join(@step_fixture_dir, "step.ex"),
      Path.join(@step_fixture_dir, "input.ex"),
      Path.join(@step_fixture_dir, "output.ex")
    ]

    assert {:ok, modules, _warnings} = Kernel.ParallelCompiler.compile(files)
    assert ALLMPipelineCrossFileStepFixture.Step in modules
    assert ALLMPipelineCrossFileStepFixture.Input in modules

    # Genuinely resolved, not merely compiled: the derived schema reached the
    # generated `json_schema/0`, complete with the `wire:` annotations.
    # `apply/3`, because the fixture does not exist at THIS file's compile time
    # and the compiler traces both a literal call and a bound-variable one into
    # an "undefined function" warning — i.e. a `--warnings-as-errors` failure.
    schema = apply(ALLMPipelineCrossFileStepFixture.Step, :json_schema, [])

    assert Map.has_key?(schema["properties"], "summary")
    refute Map.has_key?(schema["properties"], "tokens_used")
    assert schema["properties"]["kind"] == %{"type" => "string", "enum" => ["alpha", "beta"]}
  end
end
