defmodule Mix.Tasks.AllmPipeline.Nilability do
  @shortdoc "Reports which schema fields the narrow nilability rule applies to"

  @moduledoc """
  Reports `ALLM.Pipeline.Schema`'s narrow nilability rule across every compiled
  schema module in the current project.

      mix allm_pipeline.nilability [--report]

  `--report` is the default and only mode: the task never edits a file, and
  every **valid** invocation exits 0. An unrecognised switch or a stray
  positional argument is refused with `Mix.raise/1`, so a typo such as
  `mix allm_pipeline.nilability --reprot` fails loudly rather than exiting 0 with
  a full report — a typo must not be indistinguishable from a request.

  ## The rule

  A field's generated `@type t` entry gains `| nil` **iff** it has neither
  `required: true` nor a non-nil `default:`, its declared type does not already
  end in `| nil`, and it carries no explicit `nilable:` option. `nilable: true`
  forces `| nil`; `nilable: false` forbids it.

  Note that `default: nil` is **not** a default for this rule, while
  `default: false` **is** one — the producers test `!= nil`, and `false != nil`.

  ## What "pending" means

  A field is **pending** when the rule says its generated type should be
  nilable-tailed and `__allm_schema__(:generated_types)` says it is not. Before
  the rule was applied in the macro, every rule-firing field was pending; after,
  none is. That is what lets one task serve as both the prediction and the
  verification of the change — and it is why the *declared* (`:types`) /
  *generated* (`:generated_types`) split exists. A diff of `:types` across that
  change is empty for every field, because the rule rewrites no source.

  ## Why this file re-implements the rule instead of calling the macro's copy

  `nilable_tail?/1` below is **byte-identical** to
  `ALLM.Pipeline.Schema`'s private copy, and `categorize/4` +
  `rule_says_nilable?/2` mirror its `generated_type/4` + `nilable?/3`. A third
  copy lives in `scripts/nilability_predict.py`, and a fourth — of
  `nilable_tail?/1` only — is `ALLM.Pipeline.Schema.JsonSchema.strip_nil/1`,
  which reads the same right spine to decide whether a derived JSON property
  gets its `["string", "null"]` union. This duplication is
  deliberate and must not be deduplicated: this task's job is to be able to
  **falsify** the macro, so if it delegated to the macro's helper, "0 pending"
  would be the macro asked whether it agrees with itself — criterion 2 would
  verify nothing and the invariant root `CLAUDE.md` tells operators to trust
  would be tautological.

  Per the house rule "A rule enforced in more than one shape needs
  a MEMBERSHIP guard", a deliberate mirror still has to be *declared* (this
  section, and the matching comment above `Schema.nilable_tail?/1`) and
  *pinned*. The pin is the "drift guard" describe in
  `test/mix/tasks/allm_pipeline_nilability_test.exs`, which runs both
  implementations over one shared fixture and asserts they agree field for
  field — catching drift without either implementation calling the other. The
  same describe carries the `strip_nil/1` parity test, over a fixture written in
  mappable types (`Applied`'s `map()` / `term()` / two-member union have no
  strict-mode JSON rendering, so the derivation cannot read that one).

  ## Why the predicate is `__allm_schema__/1`

  Not `__schema__/1`. Every `Ecto.Schema` module exports `__schema__/1` too, and
  `__schema__(:types)` returns Ecto types rather than declared ASTs — so that
  predicate would enumerate every Ecto schema in the project and read garbage
  out of it. The same collision is why `ALLM.Pipeline.StepLog`'s serializer keys
  on the distinct name.

  ## Known blind spot: `nilable: false`

  `__allm_schema__(:nilable)` lists fields declared `nilable: true` **only** —
  its contract is `[atom()]`, which cannot express `false` — so this task cannot
  see a `nilable: false` declaration and would report such a field as pending
  forever.

  There are **zero** `nilable:` declarations in the `lib/` trees this task can
  enumerate; the only `nilable:` fields in the package are `.exs` test fixtures,
  none reachable by `schema_modules/0` — it reads
  `Application.spec(app, :modules)`, which is built from `lib/` only. So the
  `0 pending` result is exact rather than lucky. Re-derive NUL-safely across
  `.ex` and `.exs`:

      grep -rIn 'field(.*nilable:' lib test --include '*.ex' --include '*.exs'

  If a `nilable: false` field is ever declared in `lib/`, the honest fix is to
  widen the introspection contract, not to special-case it here.
  """

  use Mix.Task

  @requirements ["app.config"]

  @typedoc """
  Why a field does or does not fire the rule. Mirrors
  `scripts/nilability_predict.py`'s categories, and with the same precedence, so
  the two instruments' totals are directly comparable.
  """
  @type category :: :required | :default | :already_nilable | :bare

  @typedoc "One field's verdict: its category, and whether the rule is unapplied."
  @type field_report :: %{
          field: atom(),
          category: category(),
          explicit_nilable: boolean(),
          pending: boolean()
        }

  @usage "Usage: mix allm_pipeline.nilability [--report]"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    args
    |> OptionParser.parse(strict: [report: :boolean])
    |> validate_args!()

    modules = schema_modules()
    reports = Enum.map(modules, fn module -> {module, field_reports(module)} end)

    print_report(reports)
  end

  # `--report` is the default and only mode, so the parsed `opts` are genuinely
  # unused — which is exactly how the old `{_opts, _rest, _invalid} =` shape came
  # to discard `invalid` and `rest` as well, leaving `--reprot` to exit 0 with a
  # full report. A parse whose every element is discarded is not validation; the
  # two refusing clauses below are. This is the package's first Mix task, so the
  # shape is the one Phase 3's will copy.
  #
  # `strict:` rather than `switches:` is half the fix, not a style choice:
  # non-strict `switches:` DROPS an undeclared flag instead of reporting it, so
  # reading `invalid` would have changed nothing on its own. Measured 2026-08-14:
  #
  #     OptionParser.parse(["--reprot"], switches: [report: :boolean])
  #     #=> {[], [], []}                     # the typo vanishes entirely
  #     OptionParser.parse(["--reprot"], strict: [report: :boolean])
  #     #=> {[], [], [{"--reprot", nil}]}    # the typo is reportable
  @spec validate_args!({keyword(), [String.t()], [{String.t(), String.t() | nil}]}) :: :ok
  defp validate_args!({_opts, [], []}), do: :ok

  defp validate_args!({_opts, _rest, [{switch, _value} | _]}),
    do: Mix.raise("unrecognised switch #{switch}. #{@usage}")

  defp validate_args!({_opts, [arg | _], []}),
    do: Mix.raise("unexpected argument #{inspect(arg)}. #{@usage}")

  @doc """
  Every loaded module exporting `__allm_schema__/1`, in sorted order.

  Enumerated through `Application.loaded_applications/0` and
  `Application.spec/2`, so this package names no host application.
  """
  @spec schema_modules() :: [module()]
  def schema_modules do
    for {app, _description, _vsn} <- Application.loaded_applications(),
        module <- Application.spec(app, :modules) || [],
        Code.ensure_loaded?(module),
        function_exported?(module, :__allm_schema__, 1) do
      module
    end
    |> Enum.sort()
  end

  @doc """
  One verdict per declared field of `module`, in declaration order.
  """
  @spec field_reports(module()) :: [field_report()]
  def field_reports(module) do
    declared = module.__allm_schema__(:types)
    generated = module.__allm_schema__(:generated_types)
    required = module.__allm_schema__(:required)
    defaults = module.__allm_schema__(:defaults)
    explicit = module.__allm_schema__(:nilable)

    for {field, declared_type} <- declared do
      category = categorize(field, declared_type, required, defaults)
      explicit_nilable = field in explicit

      %{
        field: field,
        category: category,
        explicit_nilable: explicit_nilable,
        pending:
          rule_says_nilable?(category, explicit_nilable) and
            not nilable_tail?(Keyword.fetch!(generated, field))
      }
    end
  end

  @doc """
  Whether a quoted type AST already ends in `| nil`.

  A union nests to the RIGHT — `a | b | nil` is
  `{:|, _, [a, {:|, _, [b, nil]}]}` — so this walks the right spine looking for
  a literal `nil`. A leading `nil | a` is deliberately **not** a nilable tail:
  the rule is about the tail, and treating it otherwise would make the detection
  depend on where in a union the author happened to write it.
  """
  @spec nilable_tail?(Macro.t()) :: boolean()
  def nilable_tail?({:|, _meta, [_left, right]}), do: nilable_tail?(right)
  def nilable_tail?(nil), do: true
  def nilable_tail?(_type), do: false

  # Precedence matters and is copied from `scripts/nilability_predict.py`:
  # required beats a non-nil default beats an already-nilable declaration. The
  # categories are therefore disjoint and sum to the declaration total, which is
  # what makes the two instruments comparable line for line.
  @spec categorize(atom(), Macro.t(), [atom()], keyword()) :: category()
  defp categorize(field, declared_type, required, defaults) do
    cond do
      field in required -> :required
      Keyword.has_key?(defaults, field) -> :default
      nilable_tail?(declared_type) -> :already_nilable
      true -> :bare
    end
  end

  # `nilable: true` forces the tail even on a `required:`/defaulted field, which
  # is why it is checked before the category.
  @spec rule_says_nilable?(category(), boolean()) :: boolean()
  defp rule_says_nilable?(_category, true), do: true
  defp rule_says_nilable?(category, false), do: category == :bare

  @spec print_report([{module(), [field_report()]}]) :: :ok
  defp print_report(reports) do
    all = Enum.flat_map(reports, fn {_module, fields} -> fields end)
    pending = Enum.filter(reports, fn {_m, fields} -> Enum.any?(fields, & &1.pending) end)
    pending_count = Enum.count(all, & &1.pending)

    shell = Mix.shell()
    shell.info("ALLM.Pipeline.Schema — narrow nilability rule (report)\n")
    shell.info("schema modules:     #{length(reports)}")
    shell.info("field declarations: #{length(all)}")

    for category <- [:required, :default, :already_nilable, :bare] do
      shell.info("  #{pad(Enum.count(all, &(&1.category == category)))}  #{label(category)}")
    end

    shell.info("  #{pad(Enum.count(all, & &1.explicit_nilable))}  explicit `nilable: true`\n")

    for {module, fields} <- pending do
      shell.info(inspect(module))

      for field <- fields, field.pending do
        shell.info("  :#{field.field}")
      end
    end

    shell.info(
      "\nPENDING (rule fires, generated type not nilable-tailed): " <>
        "#{pending_count} across #{length(pending)} modules"
    )

    :ok
  end

  @spec pad(non_neg_integer()) :: String.t()
  defp pad(count), do: String.pad_leading(Integer.to_string(count), 4)

  @spec label(category()) :: String.t()
  defp label(:required), do: "required"
  defp label(:default), do: "non-nil default"
  defp label(:already_nilable), do: "already `| nil`"
  defp label(:bare), do: "bare (rule fires)"
end
