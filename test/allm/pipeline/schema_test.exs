defmodule ALLM.Pipeline.SchemaTest do
  @moduledoc """
  The first test file `ALLM.Pipeline.Schema` has ever had.

  Every fixture below is package-owned: `apps/allm_pipeline` declares no
  umbrella dependency, so naming a host schema here would not compile — and
  that is the point, not an inconvenience (`apps/allm_pipeline/CLAUDE.md` §1).

  Two things this file deliberately does NOT assert, because they are the other
  half of a two-layer design that lives in `ALLM.Pipeline.StepLog`:

  * that `__allm_schema__(:declared_logged)` is the set of fields that reach
    `input_data` / `output_data` — it is not, and the unflagged-`:content`
    fixture below pins the divergence from this side;
  * that a `redact: true` field is scrubbed — the flag is inert until the
    serializer reads it.
  """

  use ExUnit.Case, async: true

  # One fixture exercising every option at once. Declaration order is
  # deliberately NOT alphabetical, so the `:fields` assertion can tell an
  # order-preserving implementation from a sorted one.
  defmodule Everything do
    @moduledoc false
    use ALLM.Pipeline.Schema

    schema do
      field(:zebra, String.t(), required: true)
      field(:alpha, integer(), default: 0)
      field(:body, String.t(), artifact: true)
      field(:bulk, [map()], log: false)
      # A fallback-list name carrying NO flag. It is `:declared_logged` here and
      # absent from the persisted row — see the moduledoc.
      field(:content, String.t())
      field(:html, String.t(), log: true)
      field(:api_key, String.t(), redact: true)
      field(:maybe, map(), nilable: true)
      # `false` is a real default, NOT "no default": `process_fields/1` and
      # `introspection_clauses/3` both reject only on nil. Pinned here because
      # 40 declarations in the tree carry `default: false`.
      field(:flagfalse, boolean(), default: false)
      field(:plain, term())
    end
  end

  defmodule TwoRequired do
    @moduledoc false
    use ALLM.Pipeline.Schema

    schema do
      field(:name, String.t(), required: true)
      field(:kind, atom(), required: true)
      field(:count, integer(), default: 0)
    end
  end

  defmodule NoRequired do
    @moduledoc false
    use ALLM.Pipeline.Schema

    schema do
      field(:count, integer(), default: 0)
    end
  end

  describe "__allm_schema__/1" do
    test "reports every key for a schema exercising every option" do
      assert Everything.__allm_schema__(:fields) ==
               [
                 :zebra,
                 :alpha,
                 :body,
                 :bulk,
                 :content,
                 :html,
                 :api_key,
                 :maybe,
                 :flagfalse,
                 :plain
               ]

      assert Everything.__allm_schema__(:required) == [:zebra]
      assert Everything.__allm_schema__(:defaults) == [alpha: 0, flagfalse: false]
      assert Everything.__allm_schema__(:dropped) == [:body, :bulk]
      assert Everything.__allm_schema__(:kept) == [:html]
      assert Everything.__allm_schema__(:artifact) == [:body]
      assert Everything.__allm_schema__(:redacted) == [:api_key]
      assert Everything.__allm_schema__(:nilable) == [:maybe]
    end

    test "`default: false` is a real default, not \"no default\"" do
      # Discriminator: both producers reject only on nil (`default != nil` in
      # `process_fields/1`, `is_nil/1` in `introspection_clauses/3`), and
      # `false != nil` is true. An implementation that treated falsiness as
      # "unset" would drop this entry AND leave the struct default `nil`.
      assert {:flagfalse, false} in Everything.__allm_schema__(:defaults)
      assert %Everything{zebra: "z"}.flagfalse == false
    end

    test ":dropped carries BOTH `log: false` and `artifact: true` fields" do
      # Guard: an implementation that folds `artifact:` into nothing keeps
      # `:bulk` here and loses `:body`, while every other assertion still passes.
      assert :body in Everything.__allm_schema__(:dropped)
      assert :bulk in Everything.__allm_schema__(:dropped)
    end

    test ":declared_logged equals :fields minus :dropped" do
      fields = Everything.__allm_schema__(:fields)
      dropped = Everything.__allm_schema__(:dropped)

      assert Everything.__allm_schema__(:declared_logged) == fields -- dropped
    end

    test "an unflagged field named :content is reported in :declared_logged" do
      # This pins the deliberate divergence between the introspection key and
      # the persisted set: `:content` is on the serializer's retained fallback
      # list and never reaches the row, but the schema knows nothing about that
      # list. A key named `:logged` would be wrong for exactly this case.
      assert :content in Everything.__allm_schema__(:declared_logged)
      refute :content in Everything.__allm_schema__(:dropped)
    end

    test ":types is the declared AST" do
      types = Everything.__allm_schema__(:types)

      assert Macro.to_string(Keyword.fetch!(types, :zebra)) == "String.t()"
      assert Macro.to_string(Keyword.fetch!(types, :bulk)) == "[map()]"
      assert Keyword.keys(types) == Everything.__allm_schema__(:fields)
    end

    test ":types and :generated_types are equal for every field" do
      # They diverge only when the nilability rule lands in the macro. Until
      # then this is what makes a `:generated_types` diff a meaningful signal.
      for schema <- [Everything, TwoRequired, NoRequired] do
        assert schema.__allm_schema__(:types) == schema.__allm_schema__(:generated_types)
      end
    end

    test "an unknown key raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn -> Everything.__allm_schema__(:logged) end
    end
  end

  describe "generated functions" do
    test "a schema exports cast/1, new/1 and __allm_schema__/1" do
      functions = Everything.__info__(:functions)

      assert {:cast, 1} in functions
      assert {:new, 1} in functions
      assert {:__allm_schema__, 1} in functions
    end

    test "new/0 exists only when the schema has no required field" do
      assert {:new, 0} in NoRequired.__info__(:functions)
      refute {:new, 0} in TwoRequired.__info__(:functions)
      assert NoRequired.new() == %NoRequired{count: 0}
    end
  end

  describe "new/1" do
    test "accepts a keyword list, an atom-keyed map and a string-keyed map alike" do
      expected = %TwoRequired{name: "Widget", kind: :thing, count: 3}

      assert TwoRequired.new(name: "Widget", kind: :thing, count: 3) == expected
      assert TwoRequired.new(%{name: "Widget", kind: :thing, count: 3}) == expected
      assert TwoRequired.new(%{"name" => "Widget", "kind" => :thing, "count" => 3}) == expected
    end

    test "raises on an unknown key, in every accepted shape" do
      assert_raise KeyError, fn -> TwoRequired.new(name: "W", kind: :t, bogus: 1) end
      assert_raise KeyError, fn -> TwoRequired.new(%{name: "W", kind: :t, bogus: 1}) end
      assert_raise KeyError, fn -> TwoRequired.new(%{"name" => "W", "bogus" => 1}) end
    end
  end

  describe "cast/1" do
    test "accepts a keyword list, an atom-keyed map and a string-keyed map" do
      expected = %TwoRequired{name: "Widget", kind: :thing, count: 3}

      assert {:ok, ^expected} = TwoRequired.cast(name: "Widget", kind: :thing, count: 3)
      assert {:ok, ^expected} = TwoRequired.cast(%{name: "Widget", kind: :thing, count: 3})

      assert {:ok, ^expected} =
               TwoRequired.cast(%{"name" => "Widget", "kind" => :thing, "count" => 3})
    end

    test "returns an existing struct of the same module unchanged" do
      input = %TwoRequired{name: "Widget", kind: :thing, count: 3}

      assert {:ok, ^input} = TwoRequired.cast(input)
    end

    test "reports a required field that is absent" do
      assert {:error, [{:kind, :missing}]} = TwoRequired.cast(name: "Widget")
    end

    test "reports a required field that is present as nil" do
      # Discriminator: a `Map.has_key?` implementation passes the absent case
      # and fails this one. Both shapes reach here from real callers.
      assert {:error, [{:kind, :missing}]} = TwoRequired.cast(name: "Widget", kind: nil)
      assert {:error, [{:kind, :missing}]} = TwoRequired.cast(%{"name" => "W", "kind" => nil})

      assert {:error, [{:kind, :missing}]} =
               TwoRequired.cast(%TwoRequired{name: "Widget", kind: nil})
    end

    test "reports an unknown key rather than ignoring it" do
      assert {:error, [{:bogus, :unknown_field}]} =
               TwoRequired.cast(name: "Widget", kind: :thing, bogus: 1)
    end

    test "reports an unknown STRING key as written" do
      assert {:error, [{"bogus", :unknown_field}]} =
               TwoRequired.cast(%{"name" => "Widget", "kind" => :thing, "bogus" => 1})
    end

    test "a string key must match a declared field EXACTLY" do
      # Discriminator: `resolve_string_key/2` is an equality test, and every
      # other string-key assertion in this file uses "bogus", which is neither a
      # prefix nor a superstring nor a case variant of any field — so replacing
      # `==` with `String.starts_with?/2` leaves all of them green. These three
      # shapes are the ones that tell the two apart.
      for key <- ["na", "names", "NAME"] do
        assert {:error, issues} = TwoRequired.cast(%{key => "x", "kind" => :k})
        assert {key, :unknown_field} in issues
        assert {:name, :missing} in issues
        assert_raise KeyError, fn -> TwoRequired.new(%{key => "x"}) end
      end
    end

    test "reports a struct of another module" do
      assert {:error, [{:__struct__, :wrong_struct}]} = TwoRequired.cast(%NoRequired{})
    end

    test "returns ALL issues, not just the first" do
      # Discriminator: a `with`-chained implementation returns a 1-element list.
      assert {:error, issues} = TwoRequired.cast(%{bogus: 1})

      assert length(issues) == 3
      assert {:bogus, :unknown_field} in issues
      assert {:name, :missing} in issues
      assert {:kind, :missing} in issues
    end

    test "reports a field supplied under BOTH its atom and its string key" do
      # Both keys resolve to `:name`. Before subphase 2.3 `resolve_keys/2` folded
      # them into one `Map.put/3`, so this returned `{:ok, …}` carrying whichever
      # value map iteration order visited last, with NO issue — the one input
      # shape D1's reason set could not describe, and a direct contradiction of
      # D2's "unknown keys are an error, never silently dropped".
      #
      # Discriminator: the assertion is on the ISSUE, never on the surviving
      # value. Which value wins is map iteration order, so a value assertion
      # would be flaky by construction — and the whole point of the reason atom
      # is that the survivor is unspecified.
      assert {:error, issues} = TwoRequired.cast(%{"name" => "A", :name => "B", :kind => :k})
      assert issues == [{:name, :duplicate_key}]

      # Symmetric: the collision is reported whichever key is seen first, so the
      # test cannot pass by accident on one iteration order.
      assert {:error, [{:kind, :duplicate_key}]} =
               TwoRequired.cast(%{:name => "N", :kind => :k, "kind" => :j})
    end

    test "a duplicate key is reported alongside every other issue" do
      # Guard: an implementation that short-circuits on the duplicate (or that
      # reports it by REPLACING the resolved map) loses the sibling issues.
      assert {:error, issues} = TwoRequired.cast(%{"name" => "A", :name => "B", "bogus" => 1})

      assert {:name, :duplicate_key} in issues
      assert {"bogus", :unknown_field} in issues
      assert {:kind, :missing} in issues
      assert length(issues) == 3
    end

    test "reports a field repeated in a KEYWORD LIST" do
      # The keyword list is the dominant production construction shape — every
      # `Input.new/1` / `Output.new/1` call site in `apps/amesbury_scraper/lib`
      # passes one, while a JSON-decoded map structurally cannot carry both an
      # atom and a string form of one key. So this, not the map case above, is
      # the shape a real caller collides on.
      #
      # 2.3 hardened only the map path: `__cast__/2`'s list arm called
      # `Map.new(input)` first, which collapsed the pair BEFORE `resolve_keys/2`
      # could see it, and returned `{:ok, %TwoRequired{name: "B"}}` with no
      # issue. Same assertion discipline as the map case — the ISSUE, never the
      # survivor.
      assert {:error, issues} = TwoRequired.cast(name: "A", name: "B", kind: :k)
      assert issues == [{:name, :duplicate_key}]

      # Siblings survive here too, and a non-adjacent repeat still collides.
      assert {:error, issues} = TwoRequired.cast(name: "A", bogus: 1, name: "B")
      assert {:name, :duplicate_key} in issues
      assert {:bogus, :unknown_field} in issues
      assert {:kind, :missing} in issues
      assert length(issues) == 3
    end

    test "a keyword list with no repeat still casts" do
      # Anti-vacuity for the test above: an implementation that reported
      # `:duplicate_key` for every keyword list would pass it. Also pins that
      # dropping `Map.new/1` did not change the accepted shape.
      assert {:ok, %TwoRequired{name: "N", kind: :k}} = TwoRequired.cast(name: "N", kind: :k)
    end

    test "new/1 RAISES on a keyword list repeat too" do
      # `new/1`'s keyword clause used to call `struct!/2` directly, which reduces
      # with `Map.put` — last writer wins, silently, never reaching
      # `__atomize_keys__/2`. Both `new/1` clauses now route through it.
      message =
        assert_raise(ArgumentError, fn ->
          TwoRequired.new(name: "A", name: "B", kind: :k)
        end).message

      assert message =~ ":name"
      assert message =~ ":duplicate_key"
      refute message =~ ~s("A")
      refute message =~ ~s("B")
    end

    test "new/1 still builds from a well-formed keyword list, and still raises on an unknown key" do
      # Anti-vacuity twin: routing the keyword clause through
      # `__atomize_keys__/2` must not change either of `new/1`'s two existing
      # behaviours on that shape.
      assert %TwoRequired{name: "N", kind: :k} = TwoRequired.new(name: "N", kind: :k)
      assert_raise KeyError, fn -> TwoRequired.new(name: "N", kind: :k, bogus: 1) end
    end

    test "new/1 RAISES on the same duplicate, naming the field" do
      # The `new/1` twin of the case above. `new/1` raises where `cast/1`
      # reports — it already does so for an unknown key — so the two functions
      # tell one story: a supplied value is never silently dropped.
      message =
        assert_raise(ArgumentError, fn ->
          TwoRequired.new(%{"name" => "A", :name => "B", :kind => :k})
        end).message

      assert message =~ ":name"
      assert message =~ ":duplicate_key"
      # Neither value may appear — which one would have survived is iteration
      # order, and rendering it would document an order nobody may rely on.
      refute message =~ ~s("A")
      refute message =~ ~s("B")
    end

    test "returns a tuple for a non-castable term instead of raising" do
      # `cast/1` runs inside `Executor.validate_input/2`, which sits BEFORE the
      # Executor's rescue — a raise here escapes a `Task.async_stream` fan-out
      # and kills the caller.
      assert {:error, [{:__input__, :not_castable}]} = TwoRequired.cast(42)
      assert {:error, [{:__input__, :not_castable}]} = TwoRequired.cast("nope")
      assert {:error, [{:__input__, :not_castable}]} = TwoRequired.cast(["not", "a", "keyword"])
    end
  end

  describe "a malformed field declaration fails at compile time" do
    test "an unknown field option names the option and the field" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_schema(quote do: field(:thing, map(), lgo: false))
        end).message

      assert message =~ ":lgo"
      assert message =~ "field :thing"
      assert message =~ "Known field options:"
    end

    test "a non-boolean value on a flag option names the option and the value" do
      # The key is spelled correctly, so the unknown-option check passes it. Only
      # the value check catches it — and without that check `redact: "true"`
      # compiles clean and means NOT redacted, on the one flag added for
      # secrets. `flagged/3` and `process_fields/1` both test for `true`
      # exactly, so a non-boolean is silently "unset".
      for {option, value} <- [
            {:redact, "true"},
            {:log, "false"},
            {:artifact, "true"},
            {:nilable, "true"},
            {:required, "yes"},
            {:required, 1},
            {:log, nil}
          ] do
        message =
          assert_raise(ArgumentError, fn ->
            compile_schema(quote do: field(:thing, map(), [{unquote(option), unquote(value)}]))
          end).message

        assert message =~ "field :thing"
        assert message =~ "#{option}: #{inspect(value)}"
      end
    end

    test "`false` is accepted on every boolean option" do
      # Guard: without this, "reject everything non-`true`" passes the test above.
      assert [{module, _}] =
               compile_schema(
                 quote do
                   field(:a, map(), required: false)
                   field(:b, map(), log: false)
                   field(:c, map(), artifact: false)
                   field(:d, map(), redact: false)
                   field(:e, map(), nilable: false)
                 end
               )

      assert module.__allm_schema__(:required) == []
      assert module.__allm_schema__(:dropped) == [:b]
      assert module.__allm_schema__(:artifact) == []
      assert module.__allm_schema__(:redacted) == []
      # Decision #2: `nilable: false` is deliberately ABSENT from `:nilable` —
      # an `[atom()]` cannot express the negative override.
      assert module.__allm_schema__(:nilable) == []
    end

    test "`artifact: true` and `log: true` together are rejected" do
      message =
        assert_raise(ArgumentError, fn ->
          compile_schema(quote do: field(:thing, map(), artifact: true, log: true))
        end).message

      assert message =~ "field :thing"
      assert message =~ "artifact: true"
    end

    test "the four new options are accepted" do
      # The negative tests above prove rejection; without this one they would
      # also pass against an implementation that rejects everything new.
      assert [{module, _}] =
               compile_schema(
                 quote do
                   field(:a, map(), log: false)
                   field(:b, map(), artifact: true)
                   field(:c, map(), redact: true)
                   field(:d, map(), nilable: true)
                 end
               )

      assert module.__allm_schema__(:dropped) == [:a, :b]
      assert module.__allm_schema__(:redacted) == [:c]
      assert module.__allm_schema__(:nilable) == [:d]
    end
  end

  # Compile a throwaway schema so a rejection is proven where it actually
  # happens — at the using module's compile time — rather than by calling the
  # validator directly. Same shape as `registry_test.exs`'s `compile_registry/1`.
  @spec compile_schema(Macro.t()) :: term()
  defp compile_schema(body) do
    module = :"Elixir.ALLM.Pipeline.SchemaTest.Generated#{System.unique_integer([:positive])}"

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use ALLM.Pipeline.Schema

          schema do
            unquote(body)
          end
        end
      end
    )
  end
end
