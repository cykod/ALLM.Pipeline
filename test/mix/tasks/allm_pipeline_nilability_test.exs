defmodule Mix.Tasks.AllmPipeline.NilabilityTest do
  @moduledoc """
  Tests the report instrument, not the rule — `schema_test.exs` owns the rule.

  This file exists because subphase 2.4's criteria 1 and 2 are *both* readings
  of this task ("non-zero before", "0 pending after"). A task that always
  answered 0 would satisfy criterion 2 and prove nothing, so the fixture below
  is a module that exports `__allm_schema__/1` by hand with a NON-nilable
  generated type for a bare field — the pre-2.4 state, which no DSL module can
  produce any more.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.AllmPipeline.Nilability

  # The pre-2.4 state, reconstructed. Not a `use ALLM.Pipeline.Schema` module on
  # purpose: since the rule lands in the macro, the DSL is now incapable of
  # generating this shape, and a fixture built through it could never be
  # pending.
  defmodule StillPending do
    @moduledoc false
    def __allm_schema__(:fields), do: [:bare, :req]
    def __allm_schema__(:types), do: [bare: quote(do: map()), req: quote(do: String.t())]
    def __allm_schema__(:generated_types), do: __allm_schema__(:types)
    def __allm_schema__(:required), do: [:req]
    def __allm_schema__(:defaults), do: []
    def __allm_schema__(:nilable), do: []
  end

  # The SHARED fixture: one field per branch both implementations can express.
  # It is read twice — once through the macro (`:types` vs `:generated_types`)
  # and once through the task (`field_reports/1` over `PreRule` below) — which
  # is what makes the "drift guard" describe a parity assertion rather than a
  # restatement. Mirrors `schema_test.exs`'s `Nilability` fixture; keep the two
  # in step when either grows a branch.
  #
  # `nilable: false` is deliberately absent and must stay absent: it is the
  # documented blind spot (`__allm_schema__(:nilable)`'s `[atom()]` contract
  # cannot express `false`), so the task genuinely cannot mirror the macro on it
  # and a fixture field would encode a disagreement as if it were drift.
  defmodule Applied do
    @moduledoc false
    use ALLM.Pipeline.Schema

    schema do
      field(:bare, map())
      field(:req, String.t(), required: true)
      field(:defaulted, integer(), default: 0)
      # `default: nil` is NOT a default for this rule — the task must agree with
      # the macro by delegating to `__allm_schema__(:defaults)`, which
      # `introspection_clauses/3` already builds by rejecting nil. That
      # delegation is the thing this field pins: a future change to `:defaults`'
      # nil handling would flip the task's category with nothing else failing.
      field(:nil_default, term(), default: nil)
      # `default: false` IS a default (`false != nil`).
      field(:false_default, boolean(), default: false)
      field(:hand_written, String.t() | nil)
      # The nested-union case — mutant M7's twin, against the TASK's copy of
      # `nilable_tail?/1` rather than the macro's.
      field(:union_tail, integer() | atom() | nil)
      field(:forced_on, String.t(), required: true, nilable: true)
    end
  end

  # `Applied` as it would have looked before the rule landed in the macro: the
  # same declarations, with `:generated_types` still the DECLARED AST. Delegates
  # for every other key so the two implementations are read off ONE fixture.
  #
  # This is what lets the task be run against the pre-rule shape of the shared
  # fixture without a second hand-written declaration list to drift.
  defmodule PreRule do
    @moduledoc false
    def __allm_schema__(:generated_types), do: Applied.__allm_schema__(:types)
    def __allm_schema__(key), do: Applied.__allm_schema__(key)
  end

  describe "nilable_tail?/1" do
    test "detects a literal nil tail at every union depth" do
      assert Nilability.nilable_tail?(quote(do: nil))
      assert Nilability.nilable_tail?(quote(do: map() | nil))
      assert Nilability.nilable_tail?(quote(do: integer() | atom() | nil))
      assert Nilability.nilable_tail?(quote(do: integer() | atom() | binary() | nil))
    end

    test "a non-nil tail is not a nilable tail, however deep the union" do
      refute Nilability.nilable_tail?(quote(do: map()))
      refute Nilability.nilable_tail?(quote(do: integer() | atom()))
      # Deliberate: the rule is about the TAIL. A leading `nil` reports false,
      # which is the documented behaviour rather than an oversight.
      refute Nilability.nilable_tail?(quote(do: nil | map()))
    end
  end

  describe "field_reports/1" do
    test "categorises every branch of the rule" do
      by_field = Map.new(Nilability.field_reports(Applied), &{&1.field, &1})

      assert by_field[:bare].category == :bare
      assert by_field[:req].category == :required
      assert by_field[:defaulted].category == :default
      # `default: nil` is not a default: the task must read it as `:bare`, the
      # same reading the macro takes via `is_nil/1`.
      assert by_field[:nil_default].category == :bare
      # `default: false` is: `false != nil`, so the rule must not fire.
      assert by_field[:false_default].category == :default
      assert by_field[:hand_written].category == :already_nilable
      # The task's own `nilable_tail?/1` walking a nested union, not just arity 2.
      assert by_field[:union_tail].category == :already_nilable
      # Precedence: `required:` wins over the explicit flag for the CATEGORY,
      # while the flag still forces the tail. Both facts are separately visible.
      assert by_field[:forced_on].category == :required
      assert by_field[:forced_on].explicit_nilable
    end

    test "reports nothing pending for a module the macro has already widened" do
      refute Enum.any?(Nilability.field_reports(Applied), & &1.pending)
    end

    test "DOES report pending for a module whose generated type was never widened" do
      # The discriminator for criteria 1 and 2. Without this, "0 pending" is
      # indistinguishable from a task that cannot detect pending at all.
      reports = Nilability.field_reports(StillPending)

      assert Enum.filter(reports, & &1.pending) |> Enum.map(& &1.field) == [:bare]
    end
  end

  describe "drift guard: the macro's rule and the task's copy" do
    # `ALLM.Pipeline.Schema` and this task implement the same rule twice, on
    # purpose (see the task's moduledoc § "Why this file re-implements the
    # rule" and the comment above `Schema.nilable_tail?/1`): if the task called
    # the macro's helper, `0 pending` would be the macro agreeing with itself.
    #
    # That independence is what this describe protects, so it must not be
    # closed by extracting a shared helper. Instead both implementations are
    # run over ONE shared fixture and compared. Neither calls the other:
    #
    #   macro side — did `process_fields/1` append `| nil`?  `:generated_types`
    #                vs `:types` on `Applied`.
    #   task  side — does the task's own `categorize/4` + `rule_says_nilable?/2`
    #                + `nilable_tail?/1` say the field is pending, given the
    #                pre-rule shape of the same declarations (`PreRule`)?
    #
    # Change the rule in one file and this reds until the other is changed to
    # match — which is the whole point of a mirror being declared and pinned.
    test "both implementations widen exactly the same fields" do
      declared = Applied.__allm_schema__(:types)
      generated = Applied.__allm_schema__(:generated_types)

      macro_widened =
        for {field, declared_type} <- declared,
            Macro.to_string(Keyword.fetch!(generated, field)) !=
              Macro.to_string(declared_type),
            do: field

      task_widened = for r <- Nilability.field_reports(PreRule), r.pending, do: r.field

      assert Enum.sort(macro_widened) == Enum.sort(task_widened)

      # Non-vacuity: an empty-vs-empty comparison would pass against a macro
      # that appends nothing AND a task that never reports pending. Pin the
      # membership, so the agreement is over a real, mixed set. Derived from
      # the fixture, one field at a time: `:bare` (rule fires), `:nil_default`
      # (`default: nil` is not a default), and `:forced_on` (`nilable: true`
      # forces the tail even onto a `required:` field, and `String.t()` has
      # none) widen; `:req`, `:defaulted`, `:false_default` are suppressed, and
      # `:hand_written` / `:union_tail` already end in `| nil`.
      assert Enum.sort(macro_widened) == [:bare, :forced_on, :nil_default]
    end

    test "both implementations agree field-for-field, not just in aggregate" do
      # The set assertion above can be satisfied by two implementations that
      # disagree on a field each in compensating directions. This walks every
      # declared field and compares the two verdicts one at a time.
      declared = Applied.__allm_schema__(:types)
      generated = Applied.__allm_schema__(:generated_types)
      task_by_field = Map.new(Nilability.field_reports(PreRule), &{&1.field, &1})

      for {field, declared_type} <- declared do
        macro_says =
          Macro.to_string(Keyword.fetch!(generated, field)) != Macro.to_string(declared_type)

        task_says = task_by_field[field].pending

        assert macro_says == task_says,
               "drift on #{inspect(field)}: macro widened=#{macro_says}, " <>
                 "task pending=#{task_says}"
      end
    end

    test "nilable_tail?/1 is byte-identical across the two copies" do
      # The clause bodies cannot be compared directly (the macro's is private),
      # so compare BEHAVIOUR over the union shapes the rule turns on. The macro
      # side is observed through what it did or did not append to `Applied`.
      generated = Applied.__allm_schema__(:generated_types)

      # A declared nilable tail was left alone by the macro...
      assert Macro.to_string(Keyword.fetch!(generated, :union_tail)) ==
               "integer() | atom() | nil"

      # ...and the task's copy independently reports the same tail.
      assert Nilability.nilable_tail?(
               Keyword.fetch!(Applied.__allm_schema__(:types), :union_tail)
             )

      # A bare field gained one, and the task's copy sees the appended tail.
      assert Macro.to_string(Keyword.fetch!(generated, :bare)) == "map() | nil"
      assert Nilability.nilable_tail?(Keyword.fetch!(generated, :bare))
      refute Nilability.nilable_tail?(Keyword.fetch!(Applied.__allm_schema__(:types), :bare))
    end
  end

  describe "schema_modules/0" do
    test "returns only modules exporting __allm_schema__/1" do
      modules = Nilability.schema_modules()

      refute modules == []
      assert Enum.all?(modules, &function_exported?(&1, :__allm_schema__, 1))
    end

    test "an Ecto schema is NOT enumerated, even though it exports __schema__/1" do
      # The same collision the serializer's predicate exists to avoid: keying on
      # `__schema__/1` would pull every Ecto schema in the project into the
      # report and read Ecto types out of `__schema__(:types)`.
      #
      # `Code.ensure_loaded?/1` is load-bearing, not ceremony:
      # `function_exported?/3` answers `false` for a module that merely has not
      # been loaded yet, so without it this assertion passes or fails on test
      # ORDER (measured: green under seeds 0/1/2, red under 3/42). It is the
      # same reason `schema_modules/0` ensures loading before its own predicate.
      assert Code.ensure_loaded?(ALLM.Pipeline.StepLog)
      assert function_exported?(ALLM.Pipeline.StepLog, :__schema__, 1)

      refute ALLM.Pipeline.StepLog in Nilability.schema_modules()
      refute ALLM.Pipeline.PipelineRun in Nilability.schema_modules()
    end

    test "the DSL macro module itself is not enumerated" do
      refute ALLM.Pipeline.Schema in Nilability.schema_modules()
    end
  end

  describe "run/1 argument validation" do
    # The refusals below are only meaningful next to a POSITIVE CONTROL: a
    # validator that rejected everything would satisfy both `assert_raise`s and
    # prove nothing. This test is that control, and it is the one that fails if
    # the accepting clause is ever narrowed.
    test "the documented invocations run and print a report" do
      for args <- [[], ["--report"]] do
        output = ExUnit.CaptureIO.capture_io(fn -> assert Nilability.run(args) == :ok end)
        assert output =~ "narrow nilability rule (report)"
        assert output =~ "PENDING"
      end
    end

    test "a mistyped switch is refused instead of silently reporting" do
      # The finding this closes: `--reprot` used to exit 0 with a full report,
      # because `{_opts, _rest, _invalid} = OptionParser.parse(...)` discarded
      # the element that carries the typo.
      assert_raise Mix.Error, ~r/unrecognised switch --reprot/, fn ->
        Nilability.run(["--reprot"])
      end
    end

    test "a stray positional argument is refused" do
      assert_raise Mix.Error, ~r/unexpected argument "schemas"/, fn ->
        Nilability.run(["schemas"])
      end
    end

    test "refusal happens before any report is printed" do
      # Discriminates "refused" from "reported AND raised" — the two are
      # identical at the exit code, and only the absence of output separates
      # them.
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert_raise Mix.Error, fn -> Nilability.run(["--reprot"]) end
        end)

      refute output =~ "narrow nilability rule (report)"
    end
  end
end
