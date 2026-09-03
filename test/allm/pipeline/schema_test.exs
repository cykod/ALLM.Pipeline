defmodule ALLM.Pipeline.SchemaTest do
  @moduledoc """
  The first test file `ALLM.Pipeline.Schema` has ever had.

  Every fixture below is package-owned: the package declares no host
  dependency, so naming a host schema here would not compile — and
  that is the point, not an inconvenience (this repo's `CLAUDE.md` §1).

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
      # `introspection_clauses/4` both reject only on nil. Pinned here because
      # 26 DSL declarations in the tree carry `default: false` (2026-08-14;
      # `python3 scripts/refsweep.py '^\s*field\(' apps --include '*.ex'
      # --format hits | grep -c 'default: false'`).
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

  # One field per branch of the narrow nilability rule (subphase 2.4). Every
  # assertion about it reads `:generated_types`, never `:types` — the rule is
  # applied by the macro and rewrites no source, so `:types` is byte-identical
  # whether or not the rule exists and asserting on it would be vacuous.
  defmodule Nilability do
    @moduledoc false
    use ALLM.Pipeline.Schema

    schema do
      field(:bare, map())
      field(:req, String.t(), required: true)
      field(:defaulted, integer(), default: 0)
      # `default: nil` is NOT a default for this rule. The discriminator
      # against a `Keyword.has_key?(opts, :default)` implementation, and three
      # real `field(:engine, term(), default: nil)` declarations depend on it.
      field(:nil_default, term(), default: nil)
      # `default: false` IS a default (`false != nil`) — 26 DSL declarations
      # carry it, and none of them may gain `| nil`.
      field(:false_default, boolean(), default: false)
      field(:hand_written, String.t() | nil)
      field(:union_tail, integer() | atom() | nil)
      field(:forced_off, map(), nilable: false)
      field(:forced_on, String.t(), required: true, nilable: true)
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
      # `process_fields/1`, `is_nil/1` in `introspection_clauses/4`), and
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

    test ":types is the declared AST even where :generated_types diverges" do
      # Rewritten in 2.4's diff (was ":types and :generated_types are equal for
      # every field", which asserted the pre-rule state). The two keys exist
      # precisely so that the rule — applied by the macro, rewriting no source —
      # is observable: `:types` must NOT move, `:generated_types` must.
      for schema <- [Everything, TwoRequired, NoRequired, Nilability] do
        declared = schema.__allm_schema__(:types)
        generated = schema.__allm_schema__(:generated_types)

        assert Keyword.keys(declared) == Keyword.keys(generated)

        for {field, declared_type} <- declared do
          generated_type = Keyword.fetch!(generated, field)

          assert Macro.to_string(generated_type) in [
                   Macro.to_string(declared_type),
                   Macro.to_string(declared_type) <> " | nil"
                 ]
        end
      end

      # ... and the divergence is real on at least one field, so the loop above
      # cannot pass vacuously against a macro that appends nothing.
      assert Macro.to_string(Keyword.fetch!(Nilability.__allm_schema__(:types), :bare)) ==
               "map()"

      assert Macro.to_string(Keyword.fetch!(Nilability.__allm_schema__(:generated_types), :bare)) ==
               "map() | nil"
    end

    test "an unknown key raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn -> Everything.__allm_schema__(:logged) end
    end
  end

  describe "the narrow nilability rule" do
    defp generated(field), do: Macro.to_string(Keyword.fetch!(gen_types(), field))
    defp gen_types, do: Nilability.__allm_schema__(:generated_types)

    test "a bare field gains `| nil`" do
      assert generated(:bare) == "map() | nil"
    end

    test "a `required: true` field does not" do
      assert generated(:req) == "String.t()"
    end

    test "a field with a non-nil `default:` does not" do
      assert generated(:defaulted) == "integer()"
    end

    test "`default: false` is a default, so the field does not gain `| nil`" do
      # `false != nil`, so this is a real default and the rule must not fire.
      # 26 DSL declarations in the tree carry `default: false` (2026-08-14;
      # `python3 scripts/refsweep.py '^\s*field\(' apps --include '*.ex'
      # --format hits | grep -c 'default: false'`); a producer that tested
      # falsiness instead of nil-ness would widen every one of them.
      assert generated(:false_default) == "boolean()"
    end

    test "`default: nil` is NOT a default, so the field DOES gain `| nil`" do
      # Discriminator against `Keyword.has_key?(opts, :default)`, which would
      # suppress the rule here. Three real `field(:engine, term(), default: nil)`
      # declarations depend on this reading.
      assert generated(:nil_default) == "term() | nil"
    end

    test "a hand-written `| nil` is left alone, not doubled" do
      assert generated(:hand_written) == "String.t() | nil"
      refute generated(:hand_written) =~ "nil | nil"
    end

    test "a nilable tail is detected through a nested union, not just at arity 2" do
      # A union nests right, so `integer() | atom() | nil` is
      # `{:|, _, [integer, {:|, _, [atom, nil]}]}`. An implementation that
      # inspected only the top node's right child would see `{:|, ...}`, decide
      # the type is not nilable-tailed, and append a second `nil`.
      assert generated(:union_tail) == "integer() | atom() | nil"
    end

    test "`nilable: false` forbids the rule on a bare field" do
      assert generated(:forced_off) == "map()"
    end

    test "`nilable: true` forces `| nil` onto a `required: true` field" do
      # The other override direction. One-direction coverage passes against an
      # implementation that only honours the common case.
      assert generated(:forced_on) == "String.t() | nil"
    end

    test ":nilable lists the explicitly-flagged fields only, never the rule-derived ones" do
      # `nilable: false` is deliberately ABSENT (the key's contract is
      # `[atom()]`, which cannot express it), and every bare field that gained
      # `| nil` by the RULE is absent too — otherwise the key would report a
      # derived fact as a declaration.
      assert Nilability.__allm_schema__(:nilable) == [:forced_on]
      refute :bare in Nilability.__allm_schema__(:nilable)
      refute :forced_off in Nilability.__allm_schema__(:nilable)
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
      # `Input.new/1` / `Output.new/1` call site in the host's `apps/amesbury_scraper/lib`
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

  describe "the LLM-facing field options" do
    test "they compile on an ordinary schema" do
      # The regression `@boolean_field_options` would cause. None of the four
      # is a flag, so adding any of them to that list makes every declaration
      # using it fail with "takes a literal `true` or `false`" — a failure this
      # file's other tests would not see, because they never declare one.
      assert [{module, _}] =
               compile_schema(
                 quote do
                   field(:scale, String.t(), values: ["small", "large"])
                   field(:summary, String.t(), description: "what it does")
                   field(:tokens_used, integer(), wire: false)
                   field(:body, String.t(), wire: "content")
                   field(:blob, map(), json_schema: %{"type" => "object"})
                 end
               )

      assert module.__allm_schema__(:values) == [scale: ["small", "large"]]
      assert module.__allm_schema__(:wire) == [tokens_used: false, body: "content"]
    end

    test "`values:` takes a compile-time EXPRESSION, not only a literal" do
      # The real vocabularies are accessor calls with a single owner
      # (`Schemas.Ordinance.fiscal_impacts/0`). `field/3` `unquote`s its
      # options, so the call is evaluated at the using module's compile time —
      # which is what keeps `values:` from prescribing a copy of a list that
      # already has an owner.
      assert [{module, _}] =
               compile_schema(
                 quote do
                   field(:scale, String.t(),
                     values: ALLM.Pipeline.SchemaTest.Vocabulary.scale_values()
                   )
                 end
               )

      assert module.__allm_schema__(:values) == [scale: ["small", "large", "very_large"]]
    end

    test "a malformed `values:` is rejected, and the message names module and field" do
      for values <- [
            # empty — passes a bare `is_list/1` check, which is the point
            [],
            # not a list at all
            :accept,
            "small",
            # `is_atom(nil)` is `true`, so a bare list-of-atoms check would
            # wave this through — and a `null` enum member is DERIVED from the
            # field's nilability, never declared
            [:small, nil],
            ["small", nil],
            # mixed: atom coercion keys off the declared type, so there is no
            # single reading of a half-atom vocabulary
            ["small", :large],
            # elements that are neither
            [1, 2]
          ] do
        message =
          assert_raise(ArgumentError, fn ->
            compile_schema(quote do: field(:scale, String.t(), values: unquote(values)))
          end).message

        assert message =~ "field :scale"
        assert message =~ "values: #{inspect(values)}"
        assert message =~ "ALLM.Pipeline.SchemaTest.Generated"
      end
    end

    test "each `values:` defect reports its OWN reason, not a neighbouring one" do
      # The loop above asserts only the module/field prefix, so it passes
      # against an implementation that collapses every defect into one message.
      # A vocabulary of integers is neither atoms nor binaries — reporting it as
      # a *homogeneity* failure ("all atoms, or all binaries") sends the author
      # looking for a mixed list they do not have.
      messages =
        for values <- [[], :accept, [:small, nil], [1, 2], ["small", :large]] do
          assert_raise(ArgumentError, fn ->
            compile_schema(quote do: field(:scale, String.t(), values: unquote(values)))
          end).message
        end

      [empty, not_a_list, has_nil, wrong_element_type, mixed] = messages

      assert empty =~ "non-empty list"
      assert not_a_list =~ "non-empty list"
      assert has_nil =~ "may not contain `nil`"
      assert wrong_element_type =~ "only atoms or binaries"
      refute wrong_element_type =~ "homogeneous"
      assert mixed =~ "homogeneous"
    end

    test "a single-element vocabulary is accepted" do
      # Degenerate but legal, and not this macro's business to forbid: the
      # guard above rejects EMPTY, not SHORT. Without this case, "reject any
      # list shorter than two" would pass the rejection test.
      assert [{module, _}] =
               compile_schema(quote do: field(:scale, String.t(), values: ["small"]))

      assert module.__allm_schema__(:values) == [scale: ["small"]]
    end

    test "a malformed `description:` or `wire:` is rejected" do
      for {option, value} <- [
            {:description, :not_a_binary},
            {:description, 1},
            {:wire, ""},
            {:wire, :summary},
            {:json_schema, "not a map"}
          ] do
        message =
          assert_raise(ArgumentError, fn ->
            compile_schema(
              quote do: field(:thing, String.t(), [{unquote(option), unquote(value)}])
            )
          end).message

        assert message =~ "field :thing"
      end
    end

    test "`wire: true` is ACCEPTED — it is the default stated explicitly" do
      # Corrected by 3.2. This case previously sat in the rejection list above,
      # on the reasoning that `true` is meaningless because the default already
      # is "same name, present". It is no longer meaningless: subphase 3.2 made
      # a `redact: true` field in a `json_schema: true` module declare `wire:`
      # one way or the other, and `wire: true` is that guard's positive answer.
      # Without it an author with a legitimately model-produced sensitive field
      # would have to spell the field's own name as a rename to get past it.
      assert [{module, _}] = compile_schema(quote do: field(:thing, String.t(), wire: true))

      assert module.__allm_schema__(:wire) == [thing: true]
    end
  end

  defmodule Vocabulary do
    @moduledoc false
    @spec scale_values() :: [String.t()]
    def scale_values, do: ["small", "large", "very_large"]
  end

  # Compile a throwaway schema so a rejection is proven where it actually
  # happens — at the using module's compile time — rather than by calling the
  # validator directly. Same shape as `registry_test.exs`'s `compile_registry/1`.
  @spec compile_schema(Macro.t()) :: term()
  describe "`input_schema`/`output_schema` declare the nested module" do
    defmodule Host do
      @moduledoc false
      # Only the arities this fixture calls: a hand-written `only:` import warns
      # per unused arity, which the `use`-injected one in `ALLM.Pipeline.Step`
      # does not (macro-generated imports are exempt).
      import ALLM.Pipeline.Schema, only: [input_schema: 2, output_schema: 1]

      input_schema json_schema: true do
        field(:url, String.t(), required: true)
      end

      output_schema do
        field(:records, [map()], required: true)
      end
    end

    test "the block becomes a nested `ALLM.Pipeline.Schema` module" do
      assert Host.Input.__allm_schema__(:fields) == [:url]
      assert Host.Input.__allm_schema__(:required) == [:url]
      assert Host.Output.__allm_schema__(:fields) == [:records]
    end

    test "options reach the generated module's `use`" do
      # The Input declares `json_schema: true` and the Output does not, so the
      # derivation's presence is the observable that the options were spliced
      # into the generated `use` rather than dropped.
      assert %{"properties" => %{"url" => _}} = Host.Input.__allm_schema__(:json_schema)
    end

    test "the generic `output_schema` does NOT imply `json_schema: true`" do
      # The derivation is opt-in per module because an unmappable type — the
      # `[map()]` above — makes it a compile error, and a non-LLM step's Output
      # legitimately carries such fields. `ALLM.Pipeline.LLMStep` imports its
      # own `output_schema/2` that defaults it on.
      assert_raise FunctionClauseError, fn -> Host.Output.__allm_schema__(:json_schema) end
    end

    test "options must be a literal keyword list, because they are read as AST" do
      message =
        assert_raise(ArgumentError, fn ->
          Code.eval_string("""
          defmodule ALLM.Pipeline.SchemaTest.Computed#{System.unique_integer([:positive])} do
            import ALLM.Pipeline.Schema, only: [input_schema: 2]

            @opts [json: true]

            input_schema @opts do
              field(:url, String.t())
            end
          end
          """)
        end).message

      assert message =~ "input_schema"
      assert message =~ "literal keyword list"
    end
  end

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
