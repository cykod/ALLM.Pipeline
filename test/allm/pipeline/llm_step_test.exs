defmodule ALLM.Pipeline.LLMStepTest do
  @moduledoc """
  `ALLM.Pipeline.LLMStep` — the generated `Step` callbacks, the engine call and
  the parse path.

  **Not `async: true`.** Every test here routes the engine call through
  `ALLM.Pipeline.LLM.impl/0`, which reads `:amesbury_scraper` application env —
  global to the VM, and carrying the test registry's declaration at boot
  (a host registry's, when run inside a host VM).
  Per this repo's `CLAUDE.md` §5 the value this tree depends on is
  established and restored here rather than observed.

  Every fixture is package-owned: the package declares no host
  dependency, so naming a host step or the host's `LLMEngine` would not compile.
  The host adapter's own conformance is pinned in the Amesbury repo:
  `apps/amesbury_scraper/test/amesbury_scraper/pipelines/llm_test.exs` there.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.LLM

  # ── The stub engine ─────────────────────────────────────────────────────────

  defmodule StubLLM do
    @moduledoc false
    @behaviour ALLM.Pipeline.LLM

    @impl true
    @spec resolve_engine(atom()) :: {:engine, atom()}
    def resolve_engine(name), do: {:engine, name}

    @impl true
    @spec generate_structured(term(), map(), String.t(), term()) :: LLM.result()
    def generate_structured(prompt, schema, schema_name, engine) do
      Process.put(:stub_calls, Process.get(:stub_calls, []) ++ [{prompt, schema_name, engine}])
      Process.put(:stub_last_schema, schema)

      case Process.get(:stub_responses) do
        [next | rest] ->
          Process.put(:stub_responses, rest)
          next

        _exhausted_or_unset ->
          Process.get(:stub_response, {:ok, %{parsed: %{}, tokens: 0}})
      end
    end
  end

  @spec respond(map(), non_neg_integer()) :: :ok
  defp respond(parsed, tokens \\ 7) do
    Process.put(:stub_response, {:ok, %{parsed: parsed, tokens: tokens}})
    :ok
  end

  @spec calls() :: [tuple()]
  defp calls, do: Process.get(:stub_calls, [])

  setup do
    previous = Application.get_env(:amesbury_scraper, LLM)
    Application.put_env(:amesbury_scraper, LLM, impl: StubLLM)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:amesbury_scraper, LLM)
        value -> Application.put_env(:amesbury_scraper, LLM, value)
      end
    end)

    :ok
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defmodule Widget do
    @moduledoc false

    defmodule Input do
      @moduledoc false
      use ALLM.Pipeline.Schema

      schema do
        field(:name, String.t(), required: true)
      end
    end

    defmodule Output do
      @moduledoc false
      use ALLM.Pipeline.Schema, json_schema: true

      schema do
        # Harness-populated: copied from the Input, never asked of the model.
        field(:name, String.t(), required: true, wire: false)
        # Harness-populated: read off the response envelope.
        field(:tokens_used, integer(), wire: false)
        # The wire property and the struct field deliberately disagree.
        field(:ai_summary, String.t(), wire: "summary")
        # `:other` IS a declared member — an unrecognized string falls back.
        field(:kind, atom(), values: [:alpha, :beta, :other], required: true)
        # `:other` is NOT — an unrecognized string is a coercion failure.
        field(:mood, atom(), values: [:calm, :stormy])
        field(:filed_on, Date.t())
        field(:tags, [String.t()], default: [])
        # The ONLY `[atom()]`-with-`values:` field in the tree. Until 3.3 ports a
        # transformer that declares one, it is the sole thing reaching
        # `map_ok/3`'s element-wise coercion branch — `{:list, :atom}` and
        # `{:list, :date}`, including the halt-on-first-error path, otherwise
        # ship with zero coverage.
        field(:action_types, [atom()], values: [:approve, :deny, :other], default: [])
        # The same shape WITHOUT `:other`, so the element-wise path is pinned in
        # both directions: degrade where declared, fail where not.
        field(:moods, [atom()], values: [:calm, :stormy], default: [])
        field(:flag, boolean(), default: false)
        field(:count, integer(), default: 0)
      end
    end
  end

  defmodule WidgetStep do
    @moduledoc false
    alias ALLM.Pipeline.LLMStepTest.Widget

    use ALLM.Pipeline.LLMStep,
      type: :transform_widget,
      input: Widget.Input,
      output: Widget.Output,
      engine: :nano,
      schema_name: "widget"

    @spec prompt(Widget.Input.t()) :: String.t()
    def prompt(%Widget.Input{} = input), do: "describe #{input.name}"

    # No `@impl` — `post_process/2` is not a `Step` callback, and `@impl true`
    # on it is a warning (hence, under `--warnings-as-errors`, a build failure).
    # Pinned here because 3.3 and 3.4 both override this function.
    @spec post_process(Widget.Output.t(), Widget.Input.t()) :: Widget.Output.t()
    def post_process(output, input), do: %{output | name: input.name}
  end

  # Same Output, `execute/2` overridden wholesale — the 3.3 shape. It calls the
  # generated `coerce/2`, which is the seam the macro exists to keep available.
  defmodule OverridingStep do
    @moduledoc false
    alias ALLM.Pipeline.LLMStepTest.Widget

    use ALLM.Pipeline.LLMStep,
      type: :transform_widget_twice,
      input: Widget.Input,
      output: Widget.Output,
      engine: :nano,
      schema_name: "widget"

    @spec prompt(Widget.Input.t()) :: String.t()
    def prompt(%Widget.Input{} = input), do: "describe #{input.name}"

    # Deliberately carries its own `@spec` and `@doc`: `ordinance_transformer.ex`
    # does, and 3.3 keeps them when it ports. If a generated spec/doc made a
    # second one a warning, `--warnings-as-errors` would fail here first.
    @doc "Calls the model, then again, keeping the second result's summary."
    @impl true
    @spec execute(map(), Widget.Input.t()) :: {:ok, Widget.Output.t()} | {:error, term()}
    def execute(_context, %Widget.Input{} = input) do
      with {:ok, parsed, tokens} <- call_llm(input),
           {:ok, first} <- coerce(parsed, tokens),
           {:ok, retry_parsed, retry_tokens} <- call_llm(input),
           {:ok, second} <- coerce(retry_parsed, retry_tokens) do
        {:ok, %{second | name: input.name, tokens_used: first.tokens_used + second.tokens_used}}
      end
    end
  end

  # A flat Output declaring NO `tokens_used` — `MeetingImportanceScorer.Output`'s
  # shape, which 3.4 ports. An implementation that reaches for `struct!/2` (or
  # puts the key unconditionally into a `new/1`) raises on this one.
  defmodule Scorer do
    @moduledoc false

    defmodule Input do
      @moduledoc false
      use ALLM.Pipeline.Schema

      schema do
        field(:meeting_id, String.t(), required: true)
      end
    end

    defmodule Output do
      @moduledoc false
      use ALLM.Pipeline.Schema, json_schema: true

      schema do
        field(:meeting_id, String.t(), required: true, wire: false)
        field(:importance_score, integer())
        field(:importance_reason, String.t())
      end
    end
  end

  # An `atom()` field with no vocabulary, which a `json_schema: true` module
  # cannot declare (`JsonSchema.no_open_atom!/5`). It exists only so
  # `__coerce__/3`'s vocabulary-less arm has a reachable subject: the arm is
  # unreachable through any derived Output by construction, and that is the
  # point — but "unreachable" must not mean "unspecified".
  defmodule Vocabularyless do
    @moduledoc false
    use ALLM.Pipeline.Schema

    schema do
      field(:kind, atom())
    end
  end

  defmodule ScorerStep do
    @moduledoc false
    alias ALLM.Pipeline.LLMStepTest.Scorer

    use ALLM.Pipeline.LLMStep,
      type: :score_widget,
      input: Scorer.Input,
      output: Scorer.Output,
      engine: :summarize,
      schema_name: "widget_importance"

    @spec prompt(Scorer.Input.t()) :: String.t()
    def prompt(%Scorer.Input{}), do: "score it"
  end

  # ── The generated Step surface ──────────────────────────────────────────────

  describe "the generated Step surface" do
    test "exports the callbacks AND carries the @behaviour attribute" do
      # Both halves, because `step_schema_census_test.exs` derives the Step
      # population two independent ways and asserts the sets are EQUAL. A macro
      # generating the callbacks without the attribute fails that test by name,
      # one subphase later and a whole app away.
      for {fun, arity} <- [step_type: 0, input_schema: 0, output_schema: 0, execute: 2] do
        assert function_exported?(WidgetStep, fun, arity),
               "the macro did not generate #{fun}/#{arity}"
      end

      declared =
        for {:behaviour, behaviours} <- WidgetStep.module_info(:attributes),
            behaviour <- behaviours,
            do: behaviour

      assert ALLM.Pipeline.Step in declared
      assert ALLM.Pipeline.Step.implements?(WidgetStep)
    end

    test "the callbacks answer the `use` declaration" do
      assert WidgetStep.step_type() == :transform_widget
      assert WidgetStep.input_schema() == Widget.Input
      assert WidgetStep.output_schema() == Widget.Output
    end

    test "json_schema/0 is the Output's DERIVED schema, not a hand-written one" do
      schema = WidgetStep.json_schema()

      assert schema == Widget.Output.__allm_schema__(:json_schema)

      # `wire: false` fields are absent from BOTH halves. An implementation that
      # drops them from `properties` but leaves them in `required` produces a
      # schema OpenAI rejects.
      refute Map.has_key?(schema["properties"], "name")
      refute Map.has_key?(schema["properties"], "tokens_used")
      refute "name" in schema["required"]
      refute "tokens_used" in schema["required"]

      # …and the rename is what reaches the wire.
      assert Map.has_key?(schema["properties"], "summary")
      refute Map.has_key?(schema["properties"], "ai_summary")
    end
  end

  # ── The call ────────────────────────────────────────────────────────────────

  describe "call_llm/1" do
    test "resolves the declared engine and sends the derived schema under its name" do
      respond(%{"kind" => "alpha"})

      assert {:ok, _parsed, _tokens} = WidgetStep.call_llm(Widget.Input.new(name: "gadget"))

      assert [{prompt, schema_name, engine}] = calls()
      assert prompt == "describe gadget"
      assert schema_name == "widget"
      assert engine == {:engine, :nano}
      assert Process.get(:stub_last_schema) == WidgetStep.json_schema()
    end

    test "an engine error is tagged and returned, not raised" do
      Process.put(:stub_response, {:error, {:llm_error, :rate_limited}})

      assert {:error, {:llm_error, :rate_limited}} =
               WidgetStep.call_llm(Widget.Input.new(name: "gadget"))
    end

    test "an untagged adapter error is normalized to the package's shape" do
      # The package's contract is the tagged form regardless of adapter; a host
      # that returns a bare reason must not leak an untagged tuple to callers.
      Process.put(:stub_response, {:error, :boom})

      assert {:error, {:llm_error, :boom}} =
               WidgetStep.call_llm(Widget.Input.new(name: "gadget"))
    end

    test "an unwired host raises, naming the registry key that fixes it" do
      Application.delete_env(:amesbury_scraper, LLM)

      message =
        assert_raise(RuntimeError, fn ->
          WidgetStep.call_llm(Widget.Input.new(name: "gadget"))
        end).message

      assert message =~ "llm:"
      assert message =~ "ALLM.Pipeline.LLM"
    end
  end

  # ── The parse path ──────────────────────────────────────────────────────────

  describe "coerce/2" do
    test "reads each field by its WIRE property name" do
      # Both directions. A schema-only implementation of `wire:` passes the
      # `json_schema/0` assertion above and silently nils the field here.
      {:ok, output} = WidgetStep.coerce(%{"summary" => "the gist", "kind" => "alpha"}, 3)

      assert output.ai_summary == "the gist"
    end

    test "a `wire: false` field is never read from the payload" do
      # The model claiming a harness-populated field must not overwrite it.
      {:ok, output} = WidgetStep.coerce(%{"name" => "from the model", "kind" => "alpha"}, 3)

      assert output.name == nil
    end

    test "tokens_used comes from the envelope, and its absence does not raise" do
      {:ok, widget} = WidgetStep.coerce(%{"kind" => "alpha"}, 42)
      assert widget.tokens_used == 42

      # The discriminator: an Output that declares no `tokens_used` at all.
      # `struct!/2` would raise here; `struct/2` plus a declaration check does not.
      {:ok, scored} = ScorerStep.coerce(%{"importance_score" => 80}, 42)
      assert scored.importance_score == 80
      refute Map.has_key?(Map.from_struct(scored), :tokens_used)
    end

    test "an enum string becomes the declared ATOM, not the string" do
      {:ok, output} = WidgetStep.coerce(%{"kind" => "beta", "mood" => "stormy"}, 0)

      assert output.kind == :beta
      assert output.mood == :stormy
      refute is_binary(output.kind)
    end

    test "an unrecognized enum string falls back to :other only when :other is declared" do
      # `kind` declares `:other`; `mood` does not. Two vocabularies in one
      # payload, so an unconditional `:other` fallback fails the second half and
      # a fallback-less implementation fails the first.
      {:ok, output} = WidgetStep.coerce(%{"kind" => "gamma"}, 0)
      assert output.kind == :other

      assert {:error, {:coerce, issues}} = WidgetStep.coerce(%{"mood" => "wistful"}, 0)
      assert issues == [{:mood, {:unknown_value, "wistful"}}]
    end

    test "a list field coerces element-wise and keeps strings as strings" do
      {:ok, output} =
        WidgetStep.coerce(
          %{"tags" => ["a", "b"], "action_types" => ["approve", "deny"], "kind" => "alpha"},
          0
        )

      # `[String.t()]` passes through; `[atom()]` with a vocabulary is coerced
      # per element, which is the branch nothing else in the tree reaches.
      assert output.tags == ["a", "b"]
      assert output.action_types == [:approve, :deny]
    end

    test "an unrecognized element follows the field's own :other rule, and a failure halts" do
      {:ok, output} = WidgetStep.coerce(%{"action_types" => ["approve", "zzz"], "kind" => "a"}, 0)
      assert output.action_types == [:approve, :other]

      # `moods` has no `:other`; the element-wise path must fail the field
      # rather than degrade, exactly as the scalar path does.
      assert {:error, {:coerce, issues}} =
               WidgetStep.coerce(%{"moods" => ["calm", "wistful"]}, 0)

      assert issues == [{:moods, {:unknown_value, "wistful"}}]
    end

    test "a null ELEMENT is dropped, never reclassified as :other" do
      # The list-path twin of the `is_atom(nil)` defect: `nil` satisfies
      # `coerce_scalar(:atom, raw, values)`'s head guard, misses the vocabulary
      # as `to_string(nil) == ""`, and reaches `unknown_value/2` — which reports
      # MISSING data as `:other` because `action_types` declares it. Both halves
      # matter: the null must vanish AND the real members must survive.
      {:ok, output} =
        WidgetStep.coerce(%{"action_types" => ["approve", nil, "deny"], "kind" => "alpha"}, 0)

      assert output.action_types == [:approve, :deny]
      refute :other in output.action_types

      # A field WITHOUT `:other` would have failed instead of degrading, which
      # would have hidden the defect on that half — so pin the drop there too.
      {:ok, moods} = WidgetStep.coerce(%{"moods" => [nil, "calm"]}, 0)
      assert moods.moods == [:calm]

      # And the same over `[String.t()]` — the element type every ported step
      # actually declares, and the one this rule did NOT hold for until
      # 2026-08-19. Before the `coercion/1` widening `tags` collapsed to a bare
      # `:passthrough`, `map_ok/3` was never reached for it, and the `nil`
      # survived into the struct. Both halves of the assertion matter: the null
      # must vanish AND the real members must survive in order.
      {:ok, tagged} = WidgetStep.coerce(%{"tags" => ["a", nil, "b"], "kind" => "alpha"}, 0)
      assert tagged.tags == ["a", "b"]
      refute nil in tagged.tags
    end

    test "an atom field with no vocabulary is a coercion failure, not a passthrough" do
      # Unreachable from a module that derives a schema —
      # `JsonSchema.no_open_atom!/5` refuses to compile one, and since 3.3 a
      # field-level `json_schema:` literal does not excuse it either. So the
      # fixture is a NON-deriving schema driven through `__coerce__/3`
      # directly, which is the only way in.
      #
      # It matters because the alternative is silent: passing the raw value
      # through writes the model's **string** into a field whose generated type
      # says `atom()`, and neither `struct/2` nor dialyzer can see that.
      assert {:error, {:coerce, issues}} =
               ALLM.Pipeline.LLMStep.__coerce__(Vocabularyless, %{"kind" => "alpha"}, 0)

      assert issues == [{:kind, {:no_vocabulary, "alpha"}}]
    end

    test "a scalar where the type says list is a coercion failure, not a passthrough" do
      # Strict mode declares `"type": "array"`, so this is a non-compliant
      # payload — and `coerce/2` is the boundary that says so. Passing it
      # through writes a bare string into a field typed `[atom()]`.
      assert {:error, {:coerce, issues}} =
               WidgetStep.coerce(%{"action_types" => "approve", "kind" => "alpha"}, 0)

      assert issues == [{:action_types, {:not_a_list, "approve"}}]

      # The same for `[String.t()]`, which is the type this rule did NOT hold
      # for until the 2026-08-19 `coercion/1` widening: `tags` collapsed to a
      # bare `:passthrough` and the scalar was STORED as a scalar, leaving a
      # field the generated type declares `[String.t()] | nil` holding `"x"`.
      # Asserting the whole issue list (not just membership) also pins that no
      # OTHER field failed, so the error cannot be coming from somewhere else.
      assert {:error, {:coerce, tag_issues}} =
               WidgetStep.coerce(%{"tags" => "solo", "kind" => "alpha"}, 0)

      assert tag_issues == [{:tags, {:not_a_list, "solo"}}]
    end

    test "a Date.t() field is parsed, and an unparseable one degrades to nil" do
      {:ok, parsed} = WidgetStep.coerce(%{"filed_on" => "2026-08-19", "kind" => "alpha"}, 0)
      assert parsed.filed_on == ~D[2026-08-19]

      # Every `parse_date/1` helper this replaces degraded rather than failing,
      # and the property is nullable in the derived schema either way.
      {:ok, junk} = WidgetStep.coerce(%{"filed_on" => "not a date", "kind" => "alpha"}, 0)
      assert junk.filed_on == nil
    end

    test "an absent or null value leaves the field at its declared default" do
      # This is what `response[\"x\"] || false` / `|| []` did at every retired
      # call site. An implementation that writes `nil` into the struct clobbers
      # the default instead.
      {:ok, output} = WidgetStep.coerce(%{"kind" => "alpha", "flag" => nil}, 0)

      assert output.tags == []
      assert output.flag == false
      assert output.count == 0
      assert output.ai_summary == nil
    end
  end

  # ── Composition ─────────────────────────────────────────────────────────────

  describe "execute/2" do
    test "composes call → coerce → post_process" do
      respond(%{"summary" => "the gist", "kind" => "beta"}, 11)

      assert {:ok, output} = WidgetStep.execute(%{}, Widget.Input.new(name: "gadget"))

      assert output.ai_summary == "the gist"
      assert output.kind == :beta
      assert output.tokens_used == 11
      # post_process/2 ran, and ran AFTER coercion — it fills the `wire: false`
      # field the payload is not allowed to supply.
      assert output.name == "gadget"
    end

    test "post_process/2 defaults to identity" do
      respond(%{"importance_score" => 55}, 4)

      assert {:ok, output} = ScorerStep.execute(%{}, Scorer.Input.new(meeting_id: "m-1"))
      assert output.importance_score == 55
      assert output.meeting_id == nil
    end

    test "an engine error short-circuits before coercion" do
      Process.put(:stub_response, {:error, {:llm_error, :timeout}})

      assert {:error, {:llm_error, :timeout}} =
               WidgetStep.execute(%{}, Widget.Input.new(name: "gadget"))

      assert length(calls()) == 1
    end

    test "a coercion failure surfaces as the step's error" do
      respond(%{"mood" => "wistful"}, 1)

      assert {:error, {:coerce, [{:mood, _}]}} =
               WidgetStep.execute(%{}, Widget.Input.new(name: "gadget"))
    end

    test "an override wins, and its coerce/2 produces the SAME struct as the generated path" do
      # The assertion that pins the seam. Without it, 3.3's wholesale
      # `execute/2` override silently loses the wire mapping, the enum coercion
      # and the token plumbing, and the phase's headline win evaporates on its
      # own worked example.
      payload = %{"summary" => "the gist", "kind" => "beta", "mood" => "calm", "tags" => ["x"]}
      input = Widget.Input.new(name: "gadget")

      respond(payload, 5)
      assert {:ok, generated} = WidgetStep.execute(%{}, input)

      Process.put(:stub_calls, [])
      respond(payload, 5)
      assert {:ok, overridden} = OverridingStep.execute(%{}, input)

      # The override really did take over: two calls, not one.
      assert length(calls()) == 2

      # Everything the macro contributes is identical; only what the override
      # itself changes (the summed token count) differs.
      assert %{overridden | tokens_used: nil} == %{generated | tokens_used: nil}
      assert generated.tokens_used == 5
      assert overridden.tokens_used == 10
    end
  end

  # ── Compile-time guards ─────────────────────────────────────────────────────

  describe "a malformed declaration fails at COMPILE time" do
    test "an Output without `json_schema: true` names the module and the missing option" do
      # 3.1's derivation is opt-in per module, so this is the failure mode a step
      # would otherwise hit on its first LIVE call — as a `FunctionClauseError`
      # naming `__allm_schema__/1`, which points at the DSL rather than at the
      # option that is missing.
      message =
        assert_raise(ArgumentError, fn ->
          compile_step(output: ALLM.Pipeline.LLMStepTest.Underived.Output)
        end).message

      assert message =~ "Underived.Output"
      assert message =~ "json_schema: true"
    end

    test "a missing prompt/1 is named, rather than surfacing as an undefined function" do
      message = assert_raise(ArgumentError, fn -> compile_step([], prompt: false) end).message

      assert message =~ "prompt/1"
    end

    test "each missing `use` option is named" do
      for key <- [:type, :input, :output, :engine, :schema_name] do
        message =
          assert_raise(ArgumentError, fn -> compile_step(Keyword.put([], key, :__drop__)) end).message

        assert message =~ "#{key}:"
      end
    end

    test "an unknown `use` option is rejected rather than silently ignored" do
      message = assert_raise(ArgumentError, fn -> compile_step(retries: 3) end).message

      assert message =~ ":retries"
    end

    test "a non-string schema_name is rejected — it is a wire value, not a label" do
      message = assert_raise(ArgumentError, fn -> compile_step(schema_name: :widget) end).message

      assert message =~ "schema_name:"
      assert message =~ "non-empty string"
    end

    test "an `input:` that is not a struct module is named" do
      # A module IS an atom, so the `use`-time shape check cannot tell these
      # apart — which is why it no longer claims to. The real check runs in
      # `__before_compile__`, where the compiler can be asked. Without it
      # `input: :not_a_module` compiled clean and surfaced as an
      # `UndefinedFunctionError` on the first run.
      message = assert_raise(ArgumentError, fn -> compile_step(input: :not_a_module) end).message

      assert message =~ ":not_a_module"
      assert message =~ "struct"

      # A real module that simply has no struct fails the same way.
      message = assert_raise(ArgumentError, fn -> compile_step(input: Enum) end).message
      assert message =~ "Enum"
    end

    test "an Output declaring tokens_used without `wire: false` is refused" do
      # Measured before this guard: the derived properties were
      # `["summary", "tokens_used"]` — the model was asked to invent a token
      # count, on every call, that `coerce/2` overwrites from the envelope and
      # discards. `__coerce__/3` knows the field by name in one direction; this
      # is the other.
      message =
        assert_raise(ArgumentError, fn ->
          compile_step(output: ALLM.Pipeline.LLMStepTest.OnWire.Output)
        end).message

      assert message =~ "tokens_used"
      assert message =~ "wire: false"

      # The guard is about the DECLARATION, not the name: an Output with no
      # `tokens_used` at all is untouched (`ScorerStep` compiled above), and one
      # that declares it correctly is too (`WidgetStep`).
      refute :tokens_used in Widget.Output.__allm_schema__(:json_schema)["required"]
    end
  end

  defmodule OnWire do
    @moduledoc false

    defmodule Output do
      @moduledoc false
      use ALLM.Pipeline.Schema, json_schema: true

      schema do
        field(:summary, String.t())
        # Deliberately NO `wire: false`.
        field(:tokens_used, integer())
      end
    end
  end

  # ── The two halves of one wire contract ─────────────────────────────────────

  describe "the schema derivation and the coercion classify the same types" do
    test "every known scalar module has a coercion clause, or the value is read back wrong" do
      # `JsonSchema.@known_scalar_modules` decides what the model is ASKED for;
      # `LLMStep.coercion/1` decides how the answer is READ BACK. They walk the
      # same generated-type AST in the same vocabulary and agree today only
      # because both lists are two entries long. Adding `DateTime` / `Decimal` /
      # `NaiveDateTime` to the derivation alone makes the schema advertise
      # `"string"` while the raw ISO string is passed through into a field the
      # `@type t` declares otherwise — no test fails, no type error is raised,
      # and dialyzer cannot see it because the struct is built with `struct/2`
      # from a runtime map.
      #
      # `String` is the one legitimate `:passthrough`: a `String.t()` value
      # needs no conversion, which is precisely why it cannot stand in for the
      # others in this assertion.
      for module <- ALLM.Pipeline.Schema.JsonSchema.__known_scalar_modules__(),
          module != String do
        # The ALIAS form, because that is the shape `__allm_schema__(:generated_types)`
        # carries and the shape `coercion/1` matches — a bare-atom
        # `{{:., _, [DateTime, :t]}, _, []}` would fail this test for `Date`
        # itself and prove nothing.
        parts = module |> Module.split() |> Enum.map(&String.to_atom/1)
        type = {{:., [], [{:__aliases__, [], parts}, :t]}, [], []}

        refute ALLM.Pipeline.LLMStep.__coercion__(type) == :passthrough,
               "#{inspect(module)} is derived as a JSON scalar by " <>
                 "ALLM.Pipeline.Schema.JsonSchema, but ALLM.Pipeline.LLMStep.coercion/1 has no " <>
                 "clause for it — the model would be asked for a string and the raw string " <>
                 "stored in a field typed #{inspect(module)}.t(). Add the clause beside the " <>
                 "`Date` one."
      end
    end

    test "String stays a passthrough, so the assertion above is not vacuous" do
      assert String in ALLM.Pipeline.Schema.JsonSchema.__known_scalar_modules__()
      assert ALLM.Pipeline.LLMStep.__coercion__(quote(do: String.t())) == :passthrough
      assert ALLM.Pipeline.LLMStep.__coercion__(quote(do: Date.t())) == :date
    end

    test "list-ness and element kind are separate axes: EVERY list type is {:list, _}" do
      # The classifier half of the two behavioural tests above. Until
      # 2026-08-19 a `[String.t()]` field collapsed to a bare `:passthrough`,
      # which made `read/3`'s non-list arm and `map_ok/3`'s null-element drop
      # unreachable for it — so the moduledoc's two list rules were true of
      # `[atom()]` / `[Date.t()]` and silently false of the one list type every
      # ported step declares. Pinned here as well as behaviourally because the
      # element kind is what varies and the list-ness is what must not.
      coercion = &ALLM.Pipeline.LLMStep.__coercion__/1

      assert coercion.(quote(do: [atom()])) == {:list, :atom}
      assert coercion.(quote(do: [Date.t()])) == {:list, :date}
      assert coercion.(quote(do: [String.t()])) == {:list, :passthrough}

      # A nested list resolves to `{:list, :passthrough}` too, and MUST: its
      # element kind is itself a list, and `coerce_scalar/3` has no `{:list, _}`
      # clause — a `{:list, {:list, _}}` would raise `FunctionClauseError`
      # inside `map_ok/3` rather than returning a coercion error.
      assert coercion.(quote(do: [[String.t()]])) == {:list, :passthrough}

      # Nested schema modules keep the model's raw map (the moduledoc's
      # "boundary"), but they are still LISTS — this is the shape the ordinance
      # port's `json_schema:`-hatched fields carry.
      assert coercion.(quote(do: [KeyProvision.t()])) == {:list, :passthrough}
    end
  end

  defmodule Underived do
    @moduledoc false

    defmodule Output do
      @moduledoc false
      # Deliberately NO `json_schema: true`.
      use ALLM.Pipeline.Schema

      schema do
        field(:summary, String.t())
      end
    end
  end

  # Compile a throwaway step so a rejection is proven where it actually happens —
  # at the using module's compile time — rather than by calling the validator.
  # Same shape as `schema_test.exs`'s `compile_schema/1`.
  @spec compile_step(keyword(), keyword()) :: term()
  defp compile_step(overrides, opts \\ []) do
    module = :"Elixir.ALLM.Pipeline.LLMStepTest.Generated#{System.unique_integer([:positive])}"

    declaration =
      [
        type: :generated,
        input: Widget.Input,
        output: Widget.Output,
        engine: :nano,
        schema_name: "generated"
      ]
      |> Keyword.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value == :__drop__ end)

    prompt =
      if Keyword.get(opts, :prompt, true) do
        quote do
          def prompt(_input), do: "generated"
        end
      else
        quote do
        end
      end

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use ALLM.Pipeline.LLMStep, unquote(Macro.escape(declaration))
          unquote(prompt)
        end
      end
    )
  end
end
