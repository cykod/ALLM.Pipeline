defmodule ALLM.Pipeline.Schema.JsonSchemaTest do
  @moduledoc """
  The derived strict-mode JSON schema.

  Every fixture is package-owned: `apps/allm_pipeline` declares no umbrella
  dependency, so naming a host schema here would not compile
  (`apps/allm_pipeline/CLAUDE.md` §1). The one assertion this file *cannot*
  make for that reason — that a derived schema is a fixed point of
  `AmesburyScraper.Transformers.LLMEngine.normalize_schema/1` — lives in
  `apps/amesbury_scraper/test/amesbury_scraper/transformers/derived_schema_normalization_test.exs`.
  What stands in for it here is `assert_strict!/1`, which re-checks the same
  invariants structurally at every depth.
  """

  use ExUnit.Case, async: true

  # A vocabulary with ONE owner, reached by a call — the shape every real
  # vocabulary in this project has (`Schemas.Ordinance.fiscal_impacts/0`,
  # `Schemas.Project.scale_values/0`). A literal-only fixture would pass
  # against an implementation that cannot evaluate an expression.
  defmodule Vocab do
    @moduledoc false
    @fiscal_impacts ["revenue_generating", "cost_neutral", "expenditure"]

    @spec fiscal_impacts() :: [String.t()]
    def fiscal_impacts, do: @fiscal_impacts

    @spec summary_description() :: String.t()
    def summary_description, do: "Clear 1-2 paragraph summary, or null if unreadable"
  end

  defmodule Flat do
    @moduledoc false
    use ALLM.Pipeline.Schema, json_schema: true

    schema do
      field(:title, String.t(), required: true)
      # Bare — the narrow nilability rule fires, so this is the nullable one.
      field(:summary, String.t())
      field(:count, integer(), default: 0)
      field(:score, float(), required: true)
      field(:flag, boolean(), default: false)
      field(:filed_on, Date.t())
      field(:tags, [String.t()], default: [])
    end
  end

  defmodule Enums do
    @moduledoc false
    use ALLM.Pipeline.Schema, json_schema: true

    schema do
      field(:fiscal_impact, String.t(), values: Vocab.fiscal_impacts())
      field(:scale, String.t(), values: Vocab.fiscal_impacts(), required: true)
      field(:action_types, [String.t()], values: Vocab.fiscal_impacts(), default: [])
      field(:kind, atom(), values: [:alpha, :beta], required: true)
    end
  end

  defmodule Parent do
    @moduledoc false
    use ALLM.Pipeline.Schema, json_schema: true

    # Declared INSIDE the parent and referenced below by SHORT alias — the
    # arrangement every nested schema in this tree has, and the one a
    # `Module.concat(parts)` resolver silently fails on (it would yield
    # `Elixir.KeyProvision`, never recurse, and report a compile error for a
    # perfectly good nested schema). A fully-qualified fixture would pass
    # against that broken resolver.
    defmodule KeyProvision do
      @moduledoc false
      use ALLM.Pipeline.Schema, json_schema: true

      schema do
        field(:label, String.t(), required: true)
        field(:detail, String.t())
      end
    end

    schema do
      field(:title, String.t(), required: true)
      field(:key_provisions, [KeyProvision.t()], default: [])
      field(:headline, KeyProvision.t(), description: "The single most important provision")
    end
  end

  defmodule Wired do
    @moduledoc false
    use ALLM.Pipeline.Schema, json_schema: true

    schema do
      field(:bill_number, String.t(), required: true, wire: false)
      field(:tokens_used, integer(), wire: false)
      field(:ai_summary, String.t(), wire: "summary", description: Vocab.summary_description())
      field(:body, String.t(), json_schema: %{"type" => "string", "format" => "markdown"})
    end
  end

  # The escape hatch at its sharpest: an OBJECT-shaped literal, which is the
  # only shape that can falsify the "a derived schema is a fixed point of a
  # strict-mode normalizer" claim. `Wired.body`'s scalar literal cannot.
  defmodule Hatched do
    @moduledoc false
    use ALLM.Pipeline.Schema, json_schema: true

    schema do
      field(:title, String.t(), required: true)

      field(:blob, map(),
        json_schema: %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
      )
    end
  end

  describe "the derived schema's envelope" do
    test "is a string-keyed closed object" do
      schema = Flat.__allm_schema__(:json_schema)

      assert schema["type"] == "object"
      assert schema["additionalProperties"] == false
      assert is_map(schema["properties"])
      assert Enum.all?(Map.keys(schema), &is_binary/1)
      assert Enum.all?(Map.keys(schema["properties"]), &is_binary/1)
    end

    test "`required` is EVERY property, not the DSL-required ones" do
      # The discriminator against an implementation that maps the DSL's
      # `required:` through. Only `title` and `score` are `required: true`;
      # strict mode demands all seven, with optionality carried by the null
      # union alone.
      assert Flat.__allm_schema__(:required) == [:title, :score]

      assert Enum.sort(Flat.__allm_schema__(:json_schema)["required"]) ==
               ~w(count filed_on flag score summary tags title)
    end
  end

  describe "the type mapping" do
    test "nullability comes from the GENERATED type, not from `required:` or `:nilable`" do
      props = Flat.__allm_schema__(:json_schema)["properties"]

      # Three fields in one fixture; the spread is what an implementation
      # reading `:types` collapses (it would render all three non-nullable) and
      # what one reading `:nilable` also collapses (that key reports only
      # explicit `nilable: true` declarations, and there are none here).
      assert props["title"]["type"] == "string"
      assert props["summary"]["type"] == ["string", "null"]
      assert props["count"]["type"] == "integer"

      assert Flat.__allm_schema__(:nilable) == []
    end

    test "scalars map by the table" do
      props = Flat.__allm_schema__(:json_schema)["properties"]

      assert props["score"]["type"] == "number"
      assert props["flag"]["type"] == "boolean"
      assert props["filed_on"]["type"] == ["string", "null"]
      assert props["tags"] == %{"type" => "array", "items" => %{"type" => "string"}}
    end
  end

  describe "values:" do
    test "a string vocabulary becomes an enum, and a nullable one gains a null member" do
      props = Enums.__allm_schema__(:json_schema)["properties"]

      assert props["scale"] == %{"type" => "string", "enum" => Vocab.fiscal_impacts()}

      # `fiscal_impact` is bare, so the rule makes it nilable — and a
      # `"null"`-permitting type whose enum has no null member is rejected by
      # the strict validator. This mirrors the retired schemas' idiom
      # (`enum: @fiscal_impacts ++ [nil]`).
      assert props["fiscal_impact"] == %{
               "type" => ["string", "null"],
               "enum" => Vocab.fiscal_impacts() ++ [nil]
             }
    end

    test "on a list, the enum lands on `items` and never gains the null member" do
      props = Enums.__allm_schema__(:json_schema)["properties"]

      assert props["action_types"] == %{
               "type" => "array",
               "items" => %{"type" => "string", "enum" => Vocab.fiscal_impacts()}
             }
    end

    test "an atom vocabulary is emitted as strings" do
      props = Enums.__allm_schema__(:json_schema)["properties"]

      assert props["kind"] == %{"type" => "string", "enum" => ["alpha", "beta"]}
    end

    test "`__allm_schema__(:values)` reports declaration order and the vocabulary as declared" do
      # Declaration order, not `Map.keys/1` order (which would sort
      # `action_types` first). The values stay atoms where they were declared
      # as atoms, because the coercion path in `LLMStep` needs to tell an atom
      # vocabulary from a string one.
      assert Enums.__allm_schema__(:values) == [
               fiscal_impact: Vocab.fiscal_impacts(),
               scale: Vocab.fiscal_impacts(),
               action_types: Vocab.fiscal_impacts(),
               kind: [:alpha, :beta]
             ]
    end
  end

  describe "nested schemas" do
    test "a `[Nested.t()]` field recurses, with its own closed object and full `required`" do
      props = Parent.__allm_schema__(:json_schema)["properties"]

      assert %{"type" => "array", "items" => items} = props["key_provisions"]
      assert items["type"] == "object"
      assert items["additionalProperties"] == false
      assert Enum.sort(items["required"]) == ~w(detail label)
      assert items["properties"]["label"]["type"] == "string"
      assert items["properties"]["detail"]["type"] == ["string", "null"]
    end

    test "a bare nullable `Nested.t()` field becomes a nullable object" do
      props = Parent.__allm_schema__(:json_schema)["properties"]

      assert props["headline"]["type"] == ["object", "null"]
      assert props["headline"]["additionalProperties"] == false
      assert props["headline"]["description"] == "The single most important provision"
    end

    test "the whole tree is strict-mode compliant at every depth" do
      assert_strict!(Parent.__allm_schema__(:json_schema))
    end
  end

  describe "wire:" do
    test "`wire: false` is absent from BOTH `properties` and `required`" do
      # Both halves matter: dropping the field from `properties` while leaving
      # it in `required` produces a schema OpenAI rejects outright.
      schema = Wired.__allm_schema__(:json_schema)

      refute Map.has_key?(schema["properties"], "bill_number")
      refute Map.has_key?(schema["properties"], "tokens_used")
      refute "bill_number" in schema["required"]
      refute "tokens_used" in schema["required"]
    end

    test "a binary `wire:` names the property, and the field name does not appear" do
      schema = Wired.__allm_schema__(:json_schema)

      assert Map.has_key?(schema["properties"], "summary")
      refute Map.has_key?(schema["properties"], "ai_summary")
      assert "summary" in schema["required"]
    end

    test "`__allm_schema__(:wire)` reports the annotated fields in declaration order" do
      assert Wired.__allm_schema__(:wire) == [
               bill_number: false,
               tokens_used: false,
               ai_summary: "summary"
             ]
    end
  end

  describe "field inclusion is OPT-OUT, and redact: must decide" do
    # Closes the 3.1 security review's carry-forward (`.work/HANDOFF.md`,
    # opened for 3.2). Inclusion stays opt-out — a derivation defaulting to
    # "exclude" derives nothing — so the one flag that can silently disagree
    # with it is made to state its intent.

    test "`redact: true` with no `wire:` is a compile error naming the field" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_derived(
            quote do
              field(:title, String.t())
              field(:api_key, String.t(), redact: true)
            end
          )
        end).message

      assert message =~ ":api_key"
      assert message =~ "wire:"
      # The message must carry the reason, not just the rule: an author who
      # reads only "add wire:" will pick whichever is less typing.
      assert message =~ "OPT-OUT"
    end

    test "`redact: true, wire: false` compiles and keeps the field off the wire" do
      [{module, _bin} | _] =
        compile_derived(
          quote do
            field(:title, String.t())
            field(:api_key, String.t(), redact: true, wire: false)
          end
        )

      schema = module.__allm_schema__(:json_schema)

      refute Map.has_key?(schema["properties"], "api_key")
      refute "api_key" in schema["required"]
      assert module.__allm_schema__(:redacted) == [:api_key]
    end

    test "`redact: true, wire: true` compiles and DOES put the field on the wire" do
      # The positive answer has to exist, or the guard is a one-way door and an
      # author with a legitimately model-produced sensitive field has to spell
      # the field's own name as a rename to get past it.
      [{module, _bin} | _] =
        compile_derived(
          quote do
            field(:api_key, String.t(), redact: true, wire: true)
          end
        )

      schema = module.__allm_schema__(:json_schema)

      assert Map.has_key?(schema["properties"], "api_key")
      assert "api_key" in schema["required"]
    end

    test "an un-annotated field still reaches the wire — the default is unchanged" do
      # The guard is scoped to `redact:`. Widening it to "every field must
      # declare `wire:`" would make the derivation ceremony, and is not what
      # was decided.
      assert Map.has_key?(Flat.__allm_schema__(:json_schema)["properties"], "title")
    end

    test "a module WITHOUT the derivation is untouched by the rule" do
      # The guard lives in the derivation, so a `redact: true` field on an
      # ordinary schema — every existing one in this tree — still compiles.
      name =
        :"Elixir.ALLM.Pipeline.Schema.JsonSchemaTest.Undecided#{System.unique_integer([:positive])}"

      assert [{_module, _bin} | _] =
               Code.compile_quoted(
                 quote do
                   defmodule unquote(name) do
                     use ALLM.Pipeline.Schema

                     schema do
                       field(:api_key, String.t(), redact: true)
                     end
                   end
                 end
               )
    end
  end

  describe "description: and the json_schema: escape hatch" do
    test "a computed description reaches the property" do
      # The computed case is the real one (`ScaleBands.scale_description/0`);
      # a literal-only fixture passes against an implementation that cannot
      # evaluate an expression.
      props = Wired.__allm_schema__(:json_schema)["properties"]

      assert props["summary"]["description"] == Vocab.summary_description()
      assert props["summary"]["type"] == ["string", "null"]
    end

    test "a per-field `json_schema:` literal is used verbatim" do
      props = Wired.__allm_schema__(:json_schema)["properties"]

      assert props["body"] == %{"type" => "string", "format" => "markdown"}
    end

    test "an OBJECT-shaped literal is spliced untouched — the one hole in the fixed point" do
      # `Wired.body` is a SCALAR literal: it has no `properties`, so it has no
      # strict-mode invariant to break and cannot observe this. An object-shaped
      # literal can, and the module's moduledoc now says so under "The one
      # exception". Pinned in BOTH directions so the qualification cannot rot:
      # the derivation adds nothing to the literal here, and the host-side
      # `derived_schema_normalization_test.exs` asserts the normalizer is what
      # repairs it at call time.
      props = Hatched.__allm_schema__(:json_schema)["properties"]

      assert props["blob"] == %{
               "type" => "object",
               "properties" => %{"a" => %{"type" => "string"}}
             }

      refute Map.has_key?(props["blob"], "additionalProperties")
      refute Map.has_key?(props["blob"], "required")

      # ...while every MAPPED property beside it in the same module still is
      # strict-mode compliant. The hatch is a per-field exception, not a
      # module-wide one.
      assert_strict!(%{
        "properties" => Map.delete(props, "blob"),
        "additionalProperties" => false,
        "required" => Hatched.__allm_schema__(:json_schema)["required"] -- ["blob"]
      })
    end
  end

  describe "the derivation is opt-in" do
    test "a schema without `json_schema: true` does not answer the key" do
      defmodule NoDerivation do
        @moduledoc false
        use ALLM.Pipeline.Schema

        schema do
          # Unmappable, and legal — this is the majority shape in the tree, and
          # why deriving unconditionally is not an option.
          field(:payload, map())
        end
      end

      assert_raise FunctionClauseError, fn -> NoDerivation.__allm_schema__(:json_schema) end
      assert NoDerivation.__allm_schema__(:fields) == [:payload]
    end

    test "an unknown `use` option is rejected rather than silently ignored" do
      assert_raise ArgumentError, ~r/unknown option\(s\) \[:json_schmea\]/, fn ->
        Code.compile_quoted(
          quote do
            defmodule ALLM.Pipeline.Schema.JsonSchemaTest.Typo do
              use ALLM.Pipeline.Schema, json_schmea: true
            end
          end
        )
      end
    end
  end

  describe "compile-time rejections" do
    test "an unmappable type names the field and both remedies" do
      error =
        assert_raise ArgumentError, fn ->
          compile_derived(
            quote do
              field(:payload, map())
            end
          )
        end

      assert error.message =~ "field :payload"
      assert error.message =~ "map()"
      assert error.message =~ "nested `ALLM.Pipeline.Schema` module"
      assert error.message =~ "json_schema: %{...}"
    end

    test "an unmappable ELEMENT type is rejected too" do
      assert_raise ArgumentError, ~r/field :rows/, fn ->
        compile_derived(
          quote do
            field(:rows, [map()])
          end
        )
      end
    end

    test "a bare `atom()` with no vocabulary is rejected" do
      assert_raise ArgumentError, ~r/field :kind.*values:/s, fn ->
        compile_derived(
          quote do
            field(:kind, atom())
          end
        )
      end
    end

    test "two fields claiming one wire property are rejected" do
      assert_raise ArgumentError, ~r/"summary"/, fn ->
        compile_derived(
          quote do
            field(:summary, String.t())
            field(:ai_summary, String.t(), wire: "summary")
          end
        )
      end
    end

    test "`values:` on a field that emits no `enum` is rejected, at both raise sites" do
      # `validate_values!/3` in the macro checks the LIST's shape and cannot see
      # the field's type; this rule is the type half, and it lives only as a
      # `raise` in two places. Neither had a test, and neither was reachable by
      # the mutation pass (its mutants were drawn from the design's test list,
      # which omits the rule) — so an implementation dropping both guards would
      # pass the suite and emit an `enum` on an integer property, which the
      # model then 400s on at the first live call.
      #
      # Both sites, because they are separate clauses of `base!/5`: a mapped
      # SCALAR that is not `"string"`, and a nested OBJECT.
      scalar =
        assert_raise(ArgumentError, fn ->
          compile_derived(quote do: field(:count, integer(), values: ["a", "b"]))
        end).message

      assert scalar =~ "field :count"
      assert scalar =~ "integer"
      assert scalar =~ "only meaningful on a string or atom field"

      object =
        assert_raise(ArgumentError, fn ->
          compile_derived(
            quote do
              field(:nested, ALLM.Pipeline.Schema.JsonSchemaTest.Parent.KeyProvision.t(),
                values: ["a", "b"]
              )
            end
          )
        end).message

      assert object =~ "field :nested"
      assert object =~ "object"
      assert object =~ "only meaningful on a string or atom field"
    end

    test "a nested schema that did not opt in names itself and the remedy" do
      error =
        assert_raise ArgumentError, fn ->
          Code.compile_quoted(
            quote do
              defmodule ALLM.Pipeline.Schema.JsonSchemaTest.NestedOptOut do
                use ALLM.Pipeline.Schema, json_schema: true

                defmodule Leaf do
                  use ALLM.Pipeline.Schema

                  schema do
                    field(:label, String.t(), required: true)
                  end
                end

                schema do
                  field(:leaf, Leaf.t(), required: true)
                end
              end
            end
          )
        end

      assert error.message =~ "does not declare `json_schema: true`"
      assert error.message =~ "NestedOptOut.Leaf"
    end
  end

  # Recursively re-asserts the two strict-mode invariants the host normalizer
  # would otherwise silently repair: every object is closed, and its `required`
  # is exactly its property-key set. This is the package-local stand-in for the
  # idempotency pin, which cannot live in this tree.
  @spec assert_strict!(term()) :: :ok
  defp assert_strict!(%{"properties" => props} = node) do
    assert node["additionalProperties"] == false
    assert Enum.sort(node["required"]) == Enum.sort(Map.keys(props))
    Enum.each(Map.values(props), &assert_strict!/1)
    :ok
  end

  defp assert_strict!(%{"items" => items}), do: assert_strict!(items)
  defp assert_strict!(_leaf), do: :ok

  # A throwaway module with the derivation switched on, so a rejection is
  # proven where it happens — at the using module's compile time. Same shape as
  # `schema_test.exs`'s `compile_schema/1`.
  @spec compile_derived(Macro.t()) :: term()
  defp compile_derived(body) do
    module =
      :"Elixir.ALLM.Pipeline.Schema.JsonSchemaTest.Derived#{System.unique_integer([:positive])}"

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use ALLM.Pipeline.Schema, json_schema: true

          schema do
            unquote(body)
          end
        end
      end
    )
  end
end
