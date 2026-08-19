defmodule ALLM.Pipeline.Schema do
  @moduledoc """
  A macro for defining Input/Output schemas with reduced boilerplate.

  ## Usage

  ```elixir
  defmodule MyApp.MyStep.Input do
    use ALLM.Pipeline.Schema

    schema do
      field :name, String.t(), required: true
      field :count, integer(), default: 0
      field :bulk, [map()], log: false
      field :api_key, String.t(), redact: true
    end
  end
  ```

  ## Options

  - `json: true` - Adds `@derive Jason.Encoder` to make the struct JSON-encodable
  - `json_schema: true` - Derives `__allm_schema__(:json_schema)` — see
    "The derived JSON schema is opt-in" below

  An unknown `use` option raises `ArgumentError`, so `json_schmea: true` fails
  loudly rather than silently leaving the schema underived.

  ## Field Options

  | Option | Values | Effect |
  |---|---|---|
  | `:required` | `true` | adds the field to `@enforce_keys`; `cast/1` reports `:missing` |
  | `:default` | term | the struct default (a `nil` default is "no default") |
  | `:log` | `true` / `false` / unset | see "The three states of `log:`" below |
  | `:artifact` | `true` | implies `log: false`, and lists the field in `__allm_schema__(:artifact)` |
  | `:redact` | `true` | value replaced by `"[REDACTED]"` at serialization |
  | `:nilable` | `true` / `false` | overrides the generated-type nilability rule in either direction — see "The narrow nilability rule" below |
  | `:values` | non-empty list of atoms, or of binaries | the enum vocabulary, accepted only on a `String.t()` / `atom()` field or a list of them — see "The LLM-facing options" below |
  | `:description` | binary | the model-facing property description |
  | `:wire` | `false`, or a binary | `false` excludes the field from the derived schema; a binary names a differing wire property |
  | `:json_schema` | map | that field's subschema, used verbatim — the escape hatch from the type mapping |

  An unknown field option raises `ArgumentError` at the *using* module's compile
  time, naming the option and the field. So does a non-boolean **value** on any
  of the five boolean options (everything except `default:` and the four
  LLM-facing options): `redact: "true"` is a compile error rather than a
  silently-unredacted field.

  ### The LLM-facing options

  `values:`, `description:`, `wire:` and `json_schema:` exist to make the
  OpenAI strict-mode JSON schema a *derived artifact* of the declaration rather
  than a second hand-maintained description of the same shape. They generate
  nothing on their own; `ALLM.Pipeline.Schema.JsonSchema` reads them.

  `values:` takes a compile-time **expression**, not only a literal list —
  `field/3` `unquote`s its options, so `values: Schemas.Ordinance.fiscal_impacts()`
  is evaluated at the using module's compile time and validated as the resolved
  list. That is deliberate: the real vocabularies in this project are accessor
  calls with a single owner, and requiring a literal would prescribe a copy of
  a list that already has one. The list must be non-empty and homogeneous —
  all atoms or all binaries — and may not contain `nil`, because a `null`
  member is **derived** from the field's nilability, never declared
  (`is_atom(nil)` is `true`, so a bare list-of-atoms check would wave it
  through).

  Strings are the common case: `projects.scale` is a string column, so its
  field is `String.t()` with a string `values:` and no atom coercion. Atom
  coercion is a property of the declared **type** (`atom()`), not of `values:`.

  `wire: false` marks a field the harness populates rather than the model — a
  `tokens_used` read off the response envelope, or a key copied from the Input.
  Demanding it in the schema's `required` would ask the model to invent it.

  ### The derived JSON schema is opt-in

  `__allm_schema__(:json_schema)` exists only on a module declaring
  `json_schema: true`; on any other schema the key raises `FunctionClauseError`
  like any unknown key. The opt-in is not ceremony: an unmappable type is a
  **compile error** (an open `map()` / `term()` / bare `list()` has no closed
  strict-mode rendering), and most schemas in this tree legitimately carry such
  fields because they never cross a wire. Deriving for every schema would turn
  each of those into a build failure.

  ### The narrow nilability rule

  A field's generated `@type t` entry gains `| nil` **iff** it has neither
  `required: true` nor a non-nil `default:`, its declared type does not already
  end in `| nil`, and it carries no explicit `nilable:` option. `nilable: true`
  forces the tail — even onto a `required:` field — and `nilable: false` forbids
  it. A field with a default always holds that default, and a required field is
  non-nil by construction, so the rule adds `| nil` exactly where a value can
  genuinely be absent at runtime.

  Two readings the rule depends on, both deliberate:

  - **`default: nil` is not a default** (the producers test `!= nil`), so
    `field(:engine, term(), default: nil)` gains `| nil`.
  - **`default: false` IS a default** (`false != nil`), so it does not.

  The rule is applied here in `process_fields/1` and rewrites **no** `field/3`
  source line. Consequences: a hand-written `| nil` is detected and left alone
  rather than doubled; `__allm_schema__(:types)` keeps reporting the declared
  AST, while `:generated_types` reports what was spliced; and every field
  declared after this inherits the rule without an edit.

  `mix allm_pipeline.nilability --report` prints the current state per module.

  ### The three states of `log:`

  `ALLM.Pipeline.StepLog` keeps heavy bodies out of `input_data` /
  `output_data` with **two** layers: the per-field flags below, *and* a retained
  package-level fallback list of generic field names (`:raw_html`, `:html`,
  `:content`, `:engine`) that applies to every struct it serializes — including
  DSL structs, and including plain `defstruct` / Ecto structs it recurses into,
  which have no flags at all.

  So `log:` is deliberately three-state rather than boolean:

  - `log: false` — never in the row.
  - `log: true` — in the row **even if the field's name is on the fallback list**.
    Without this state, "this field is named `:content` but must be logged" is
    unsayable, which would reproduce the global-by-name wart for those four names.
  - unset — the fallback decides.

  ### `artifact: true` generates nothing

  It declares intent and feeds `__allm_schema__(:artifact)`, and it implies
  `log: false`. It does **not** generate an `artifact_content/1`: every Step
  module implements that callback by hand, so a generated one would have no
  consumer. Combining it with `log: true` is a compile-time error — the two
  express opposite intents and the serializer's drop set would be contradictory.

  ### `redact: true` applies at serialization, not at construction

  The value is replaced by the literal string `"[REDACTED]"` when
  `ALLM.Pipeline.StepLog` serializes the struct — construction-time scrubbing
  would destroy the value the field exists to carry. Four paths were therefore
  **not** covered; subphase 2.3 closed the second in code and **three** remain
  uncovered, none of which the flag can reach:

  1. **`artifact_content/1`** — an opaque binary the Step builds itself. The rule
     that replaces coverage is documentation: *a `redact: true` field must not be
     included in `artifact_content/1`.*
  2. ~~**`ALLM.Pipeline.Executor`'s validation error messages**~~ — **closed in
     subphase 2.3.** They used to `inspect/1` the rejected term into
     `step_logs.error` and the logs; `Executor`'s `render_shape/1` now renders
     the term's type and key NAMES only, never its values. Listed rather than
     deleted because it is the one of the four that a code fix could reach, and
     the reason it could is that the Executor owns the whole message.
  3. **`ALLM.Pipeline.Executor.log_summary/4`**, which writes a caller-supplied
     map straight to `output_data` without passing through the serializer at all.
  4. **`Inspect` and exception messages.** DSL structs derive no `Inspect`
     exclusion, so a redacted value renders in full under `inspect/1` — and
     `new/1` routes through `struct!/2`, whose `KeyError` on an unknown key
     renders the *partially-built* struct, secret included. Use `cast/1` rather
     than `new/1` on any input that mixes a redacted field with untrusted keys.

  ## Generated Functions

  - `new/0` — a struct with defaults (only when there are no required fields)
  - `new/1` — a struct from a keyword list, or from a map with atom **or** string
    keys. Raises on an unknown key (`struct!/2` semantics) and on a field
    supplied twice (both key forms in a map, or repeated in a keyword list)
  - `cast/1` — `{:ok, t()} | {:error, [issue()]}`; see below
  - `__allm_schema__/1` — introspection; see below

  ### `cast/1` does not interpret the declared type

  `cast/1` checks the *shape* of its input and nothing else:

  - the input is a map (atom or string keys), a keyword list, or an existing
    `%__MODULE__{}` — otherwise `{:error, [{:__input__, :not_castable}]}`
  - every key resolves to a declared field — otherwise `{key, :unknown_field}`
    (unknown keys are an **error**, never silently dropped)
  - no field is supplied twice — under both its atom and its string key in a
    map, or repeated in a keyword list — otherwise `{field, :duplicate_key}`
  - every `required: true` field is present and non-nil — otherwise
    `{field, :missing}`
  - a struct of a different module → `{:error, [{:__struct__, :wrong_struct}]}`

  It takes a `term()`, not `map() | keyword() | t()`: it is called from
  `ALLM.Pipeline.Executor.validate_input/2` with whatever a caller handed
  `run_step/5`, which runs BEFORE the Executor's try/rescue — so it **never
  raises**, and the `:not_castable` arm is the reachable answer for anything
  else.

  It performs **no runtime checking of the declared type**. The declared types
  are arbitrary quoted AST (`[map()]`, `String.t()`, `term()`, module-qualified
  aliases); interpreting them at runtime means writing a type checker, dialyzer
  already covers them statically, and a misinterpretation would reject live
  production input at the top of `ALLM.Pipeline.Executor.run_step/5`.

  `cast/1` returns **all** issues, not the first one.

  ### `__allm_schema__/1`, and why it is not `__schema__/1`

  Every `Ecto.Schema` module also exports `__schema__/1`, and
  `ALLM.Pipeline.StepLog` recurses into live Ecto structs. A
  `function_exported?(mod, :__schema__, 1)` predicate would classify every Ecto
  struct as DSL-owned; `__schema__(:fields)` then *succeeds* with a colliding
  shape while `__schema__(:dropped)` raises `FunctionClauseError` — on the
  un-rescued step-log write path. The distinct name is what makes the predicate
  correct. Do not "simplify" it back.

  | Key | Returns | Notes |
  |---|---|---|
  | `:fields` | `[atom()]` | declaration order |
  | `:types` | `[{atom(), Macro.t()}]` | the **declared** type AST, exactly as written |
  | `:generated_types` | `[{atom(), Macro.t()}]` | the AST actually spliced into `@type t` |
  | `:required` | `[atom()]` | same set as `@enforce_keys` |
  | `:defaults` | `keyword()` | fields with a non-nil `default:` |
  | `:dropped` | `[atom()]` | `log: false` or `artifact: true` |
  | `:kept` | `[atom()]` | explicit `log: true` |
  | `:declared_logged` | `[atom()]` | derived: `:fields − :dropped`. **Not the persisted set** |
  | `:artifact` | `[atom()]` | `artifact: true` |
  | `:redacted` | `[atom()]` | `redact: true` |
  | `:nilable` | `[atom()]` | fields declared `nilable: true` — explicit declarations only |
  | `:values` | `[{atom(), [atom()] \\| [String.t()]}]` | declaration order; the vocabulary **as declared**, so the coercion path can tell an atom vocabulary from a string one |
  | `:wire` | `[{atom(), false \\| String.t()}]` | declaration order; annotated fields only |
  | `:json_schema` | `map()` | the derived strict-mode schema — **only** on a module declaring `json_schema: true` |

  An unknown key raises `FunctionClauseError`, so a typo fails loudly.

  `:declared_logged` is deliberately **not** called `:logged`. It reports what the
  field flags say and ignores the retained fallback list, so for a struct with an
  unflagged `field :content, String.t()` it lists `:content` even though
  `:content` never reaches `output_data`. The persisted set is computable only
  with the fallback in hand, which is the serializer's job, not the schema's.

  `:types` vs `:generated_types` diverge for exactly the fields the nilability
  rule fires on. They are separate keys because that rule is applied by this
  macro and rewrites no source: the *declared* AST is byte-identical before and
  after, so only the *generated* AST can show the change. Use `:types` to ask
  "what did the author write?" and `:generated_types` to ask "what does dialyzer
  see?".

  ## Not implemented here

  The coercion half of `values:` and `wire:` — reading a model's parsed
  payload back into this struct — belongs to `ALLM.Pipeline.LLMStep`
  (extraction plan Phase 3.2), which reads `__allm_schema__(:values)` and
  `__allm_schema__(:wire)`. This module records the declaration; it never
  parses a payload.
  """

  @use_options [:json, :json_schema]

  @field_options [
    :required,
    :default,
    :log,
    :artifact,
    :redact,
    :nilable,
    :values,
    :description,
    :wire,
    :json_schema
  ]

  # Every field option that is a FLAG must carry a literal boolean, and that is
  # validated rather than coerced because the readers below test for `true`
  # exactly: without it, `redact: "true"` compiles clean and means NOT redacted
  # — a silent degradation on the one flag that exists for secrets. Validating
  # the value is also what makes the two reader styles in this module
  # equivalent (`flagged/3`'s `== value` and `process_fields/1`'s `== true`),
  # so neither has to be the odd one out.
  #
  # `default:` (an arbitrary term) and the four LLM-facing options
  # (`values:`, `description:`, `wire:`, `json_schema:`) are NOT flags and must
  # stay out of this list — adding one here makes every declaration using it
  # fail to compile with "takes a literal `true` or `false`". They carry their
  # own shape validation in `__validate_field__!/3` instead.
  @boolean_field_options [:required, :log, :artifact, :redact, :nilable]

  @typedoc """
  One problem `cast/1` found.

  The first element names the offending field. It is an atom for every declared
  field and for the two whole-term slots (`:__struct__`, `:__input__`); an
  unknown key arrives as-written, so a string-keyed map's unknown key is
  reported as a `String.t()` (a key that matches no field cannot be safely
  converted to an atom).

  `:duplicate_key` is reported when one field is supplied **twice** — under
  both its atom and its string key in a map, or repeated in a keyword list
  (which permits repeats). The field name is reported, never either value —
  which of the two would have won is unspecified (map iteration order, or
  last-writer-wins for a keyword list) and deliberately so, because no caller
  should depend on it.
  """
  @type issue ::
          {atom() | String.t(),
           :missing | :unknown_field | :wrong_struct | :not_castable | :duplicate_key}

  @doc false
  defmacro __using__(opts) do
    __validate_use__!(__CALLER__.module, opts)

    json = Keyword.get(opts, :json, false)
    json_schema = Keyword.get(opts, :json_schema, false)

    quote do
      import ALLM.Pipeline.Schema, only: [schema: 1, field: 2, field: 3]
      Module.register_attribute(__MODULE__, :schema_fields, accumulate: true)
      Module.put_attribute(__MODULE__, :schema_json, unquote(json))
      Module.put_attribute(__MODULE__, :schema_json_schema, unquote(json_schema))

      @before_compile ALLM.Pipeline.Schema
    end
  end

  @doc false
  @spec __validate_use__!(module(), keyword()) :: :ok
  def __validate_use__!(module, opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: `use ALLM.Pipeline.Schema` takes a keyword list, " <>
              "got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @use_options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "#{inspect(module)}: unknown option(s) #{inspect(unknown)} on " <>
                "`use ALLM.Pipeline.Schema`. Known options: #{inspect(@use_options)}."
    end
  end

  @doc """
  Defines the schema fields for an Input/Output module.
  """
  defmacro schema(do: block) do
    quote do
      unquote(block)
    end
  end

  @doc """
  Defines a field in the schema.

  ## Examples

      field :name, String.t(), required: true
      field :count, integer(), default: 0
      field :data, map()
      field :bulk, [map()], log: false
  """
  defmacro field(name, type, opts \\ []) do
    quote do
      ALLM.Pipeline.Schema.__validate_field__!(__MODULE__, unquote(name), unquote(opts))

      Module.put_attribute(__MODULE__, :schema_fields, {
        unquote(name),
        unquote(Macro.escape(type)),
        unquote(opts)
      })
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :schema_fields) |> Enum.reverse()
    json = Module.get_attribute(env.module, :schema_json)

    {required_fields, struct_fields, type_fields} = process_fields(fields)

    has_required = length(required_fields) > 0

    json_derive =
      if json do
        quote do
          @derive Jason.Encoder
        end
      else
        quote do
        end
      end

    enforce_keys =
      if has_required do
        quote do
          @enforce_keys unquote(required_fields)
        end
      else
        quote do
        end
      end

    type_def =
      quote do
        @type t :: %__MODULE__{unquote_splicing(type_fields)}
      end

    new_0 =
      if has_required do
        quote do
        end
      else
        quote do
          @doc "Creates a new struct with default values."
          @spec new() :: t()
          def new, do: %__MODULE__{}
        end
      end

    new_1 =
      quote do
        @doc """
        Creates a new struct from a keyword list, or from a map with atom or
        string keys.

        Raises on an unknown key (`struct!/2` semantics), and on one field
        supplied twice — under both its atom and its string key in a map, or
        repeated in a keyword list. Use `cast/1` when either should be reported
        rather than raised.
        """
        @spec new(keyword() | map()) :: t()
        def new(attrs) when is_list(attrs) or (is_map(attrs) and not is_struct(attrs)) do
          struct!(__MODULE__, ALLM.Pipeline.Schema.__atomize_keys__(__MODULE__, attrs))
        end
      end

    cast_1 =
      quote do
        @doc """
        Validates the shape of `input` and returns this schema's struct.

        Accepts a keyword list, a map with atom or string keys, or an existing
        `%__MODULE__{}`. Returns every issue it finds, not just the first. The
        declared type of a field is **not** checked at runtime — see the module
        doc.

        The argument is `term()` rather than `map() | keyword() | t()` on
        purpose: `ALLM.Pipeline.Executor.validate_input/2` calls this with
        whatever a caller handed `run_step/5`, and the whole reason
        `{:__input__, :not_castable}` exists is that such a term may be
        anything at all. A narrower spec would declare that arm unreachable
        while the function's own contract promises it.
        """
        @spec cast(term()) :: {:ok, t()} | {:error, [ALLM.Pipeline.Schema.issue()]}
        def cast(input), do: ALLM.Pipeline.Schema.__cast__(__MODULE__, input)
      end

    introspection = introspection_clauses(fields, type_fields, required_fields, env)

    quote do
      unquote(json_derive)
      unquote(enforce_keys)
      defstruct unquote(struct_fields)
      unquote(type_def)
      unquote(new_0)
      unquote(new_1)
      unquote(cast_1)
      unquote(introspection)
    end
  end

  # Private, and `@spec`'d, since 2.4's follow-up: it is called from exactly one
  # place — `__before_compile__/1`, in this module's own compile-time body — and
  # never from generated code, so unlike `__cast__/2` it needs no public
  # visibility. `introspection_clauses/4`, invoked two lines away, is `defp` for
  # the same reason. Re-derive with
  # `python3 scripts/refsweep.py 'process_fields\(' apps --include '*.ex' --include '*.exs' --format hits`
  # → **3** hits, all in this file, of which exactly ONE is a call: `:280`, plus
  # the `@spec` immediately below and the `defp` head (2026-08-14). Counted after
  # the `@spec` landed — it supplies its own match, so a `2` written before the
  # edit would read as a regression forever.
  @spec process_fields([{atom(), Macro.t(), keyword()}]) ::
          {[atom()], [atom() | {atom(), term()}], [{atom(), Macro.t()}]}
  defp process_fields(fields) do
    Enum.reduce(fields, {[], [], []}, fn {name, type, opts}, {required, struct_def, type_def} ->
      # `== true`, not a truthiness test, so this reads `required:` the same way
      # `flagged/3` reads the other four flags. `__validate_field__!/3` has
      # already rejected every non-boolean value, so the two forms agree on
      # every value that reaches here — this keeps them agreeing if that
      # validation is ever relaxed.
      is_required = Keyword.get(opts, :required) == true
      default = Keyword.get(opts, :default)

      new_required =
        if is_required do
          [name | required]
        else
          required
        end

      new_struct =
        if default != nil do
          [{name, default} | struct_def]
        else
          [name | struct_def]
        end

      # The narrow nilability rule (subphase 2.4). The declared type is NOT
      # spliced verbatim any more: a field that has neither `required: true` nor
      # a non-nil `default:` can hold `nil` at runtime — nothing stops
      # `struct!/2` leaving it there — so `@type t` says so. Applying it here
      # rather than by rewriting 98 `field(...)` lines is what keeps it from
      # drifting, and what makes every field declared after this inherit it.
      #
      # `:types` still reports the declared AST; only `:generated_types` (this
      # list) moves. Hand-written `| nil` is left alone rather than doubled.
      new_type = [{name, generated_type(type, opts, is_required, default)} | type_def]

      {new_required, new_struct, new_type}
    end)
    |> then(fn {required, struct_def, type_def} ->
      {Enum.reverse(required), Enum.reverse(struct_def), Enum.reverse(type_def)}
    end)
  end

  # The rule, in one place. `nilable:` is resolved BEFORE the category so that
  # `nilable: true` forces the tail even onto a `required:` or defaulted field,
  # and `nilable: false` forbids it on a bare one — Decision #1's "overrides in
  # either direction".
  #
  # `default: nil` is not a default here (`is_nil/1`), matching the struct
  # default above; `default: false` IS one, because `false != nil` — 26 DSL
  # declarations in the tree depend on that reading (2026-08-14; re-derive with
  # `python3 scripts/refsweep.py '^\s*field\(' apps --include '*.ex' --format
  # hits | grep -c 'default: false'`). The figure read 40 until the 2.4 fix
  # pass: that came from a substring count over three populations (26 DSL
  # declarations + 10 Ecto `:boolean` columns, which this rule never sees + 7
  # prose mentions).
  @spec generated_type(Macro.t(), keyword(), boolean(), term()) :: Macro.t()
  defp generated_type(type, opts, is_required, default) do
    if nilable?(opts, is_required, default) and not nilable_tail?(type) do
      {:|, [], [type, nil]}
    else
      type
    end
  end

  @spec nilable?(keyword(), boolean(), term()) :: boolean()
  defp nilable?(opts, is_required, default) do
    case Keyword.get(opts, :nilable) do
      true -> true
      false -> false
      nil -> not is_required and is_nil(default)
    end
  end

  # A union nests to the RIGHT — `a | b | nil` is `{:|, _, [a, {:|, _, [b,
  # nil]}]}` — so walk the right spine for a literal `nil`. A leading
  # `nil | a` is deliberately NOT a nilable tail: appending to it is harmless,
  # and making detection depend on where in a union the author wrote `nil`
  # would be a second rule to remember.
  #
  # ⚠️ DELIBERATE MIRROR — this function is byte-identical to
  # `Mix.Tasks.AllmPipeline.Nilability.nilable_tail?/1`, and `generated_type/4`
  # + `nilable?/3` above are mirrored there as `categorize/4` +
  # `rule_says_nilable?/2`. A third copy lives in
  # `scripts/nilability_predict.py`. A FOURTH walk of the same right spine is
  # `ALLM.Pipeline.Schema.JsonSchema.strip_nil/1`, which decides whether the
  # derived JSON property gets the `["string", "null"]` union — it must agree
  # with this function or a field the runtime can leave `nil` gets a schema
  # forbidding `null`, i.e. a live 400 on the model's response rather than a
  # compile error. The invariant is `elem(strip_nil(t), 1) == nilable_tail?(t)`
  # for every `t`, and it is guarded by the same drift-guard describe named
  # below. **Do not extract a shared helper.** The
  # task exists to falsify this implementation: if it called into here, its
  # `0 pending` result would be the macro agreeing with itself and would verify
  # nothing. Same house shape as `Amesbury.Media.UrlBuilder.@param_order` ⇔
  # `frontend/src/lib/media_url.ts`.
  #
  # The drift guard that keeps the copies honest WITHOUT collapsing that
  # independence is `test/mix/tasks/allm_pipeline_nilability_test.exs`'s
  # "drift guard: the macro's rule and the task's copy" describe — it runs both
  # implementations over one shared fixture (`Applied`) and asserts they agree
  # field for field, neither calling the other. Change the rule here and that
  # test reds until the task's copy — and `JsonSchema.strip_nil/1`, pinned by the
  # same describe — is changed to match.
  @spec nilable_tail?(Macro.t()) :: boolean()
  defp nilable_tail?({:|, _meta, [_left, right]}), do: nilable_tail?(right)
  defp nilable_tail?(nil), do: true
  defp nilable_tail?(_type), do: false

  @doc false
  @spec __validate_field__!(module(), atom(), keyword()) :: :ok
  def __validate_field__!(module, name, opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: options for `field :#{name}` must be a keyword list, " <>
              "got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @field_options do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_option_message(module, name, unknown)
    end

    Enum.each(opts, fn {option, value} ->
      if option in @boolean_field_options and not is_boolean(value) do
        raise ArgumentError, non_boolean_option_message(module, name, option, value)
      end
    end)

    if Keyword.get(opts, :artifact) == true and Keyword.get(opts, :log) == true do
      raise ArgumentError,
            "#{inspect(module)}: `field :#{name}` declares both `artifact: true` and " <>
              "`log: true`. `artifact: true` implies `log: false` — the two express " <>
              "opposite intents and the serializer's drop set would be contradictory."
    end

    validate_values!(module, name, opts)
    validate_description!(module, name, opts)
    validate_wire!(module, name, opts)
    validate_json_schema!(module, name, opts)

    :ok
  end

  # `values:` arrives already EVALUATED — `field/3` `unquote`s its options, so
  # `values: Schemas.Ordinance.fiscal_impacts()` reaches here as the resolved
  # list. That is what lets a vocabulary keep its single owner instead of being
  # copied into the declaration, and it is why this validates a list rather
  # than an AST.
  @spec validate_values!(module(), atom(), keyword()) :: :ok
  defp validate_values!(module, name, opts) do
    case Keyword.fetch(opts, :values) do
      :error ->
        :ok

      {:ok, values} ->
        unless is_list(values) and values != [] do
          raise ArgumentError, values_message(module, name, values, "must be a non-empty list")
        end

        if Enum.any?(values, &is_nil/1) do
          raise ArgumentError,
                values_message(
                  module,
                  name,
                  values,
                  "may not contain `nil`. A `null` enum member is DERIVED from the field's " <>
                    "nilability, never declared — and `is_atom(nil)` is `true`, so a bare " <>
                    "list-of-atoms check would wave it through"
                )
        end

        unless Enum.all?(values, &(is_atom(&1) or is_binary(&1))) do
          raise ArgumentError,
                values_message(
                  module,
                  name,
                  values,
                  "may contain only atoms or binaries. A vocabulary is emitted as a JSON " <>
                    "`enum` of strings, and there is no reading of an integer or a tuple " <>
                    "member that survives that round trip"
                )
        end

        unless Enum.all?(values, &is_atom/1) or Enum.all?(values, &is_binary/1) do
          raise ArgumentError,
                values_message(
                  module,
                  name,
                  values,
                  "must be homogeneous — all atoms, or all binaries. Atom coercion keys off " <>
                    "the declared TYPE, so a mixed vocabulary has no single reading"
                )
        end

        :ok
    end
  end

  @spec validate_description!(module(), atom(), keyword()) :: :ok
  defp validate_description!(module, name, opts) do
    case Keyword.fetch(opts, :description) do
      :error ->
        :ok

      {:ok, description} when is_binary(description) ->
        :ok

      {:ok, other} ->
        raise ArgumentError,
              "#{inspect(module)}: `field :#{name}` declares `description: #{inspect(other)}`, " <>
                "but description takes a binary (a literal, or any compile-time expression " <>
                "returning one)."
    end
  end

  @spec validate_wire!(module(), atom(), keyword()) :: :ok
  defp validate_wire!(module, name, opts) do
    case Keyword.fetch(opts, :wire) do
      :error -> :ok
      {:ok, false} -> :ok
      {:ok, wire} when is_binary(wire) and wire != "" -> :ok
      {:ok, other} -> raise ArgumentError, wire_message(module, name, other)
    end
  end

  @spec validate_json_schema!(module(), atom(), keyword()) :: :ok
  defp validate_json_schema!(module, name, opts) do
    case Keyword.fetch(opts, :json_schema) do
      :error ->
        :ok

      {:ok, literal} when is_map(literal) ->
        :ok

      {:ok, other} ->
        raise ArgumentError,
              "#{inspect(module)}: `field :#{name}` declares `json_schema: #{inspect(other)}`, " <>
                "but it takes a map used verbatim as that field's subschema."
    end
  end

  @doc false
  @spec __atomize_keys__(module(), map() | keyword()) :: map()
  def __atomize_keys__(module, attrs) do
    fields = module.__allm_schema__(:fields)

    # NOT `Map.new/2`, and `new/1`'s keyword clause routes through here for the
    # same reason rather than calling `struct!/2` directly: both collapse a
    # field supplied twice — under its atom and its string key in a map, or
    # repeated in a keyword list — into a single entry, silently keeping
    # whichever value was visited last. `new/1` raises on an unknown key, so
    # raising here too is the consistent reading — dropping a supplied value is
    # the class of bug this DSL exists to remove, and which value survived is
    # not something a caller may depend on.
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      resolved = if is_binary(key), do: resolve_string_key(key, fields) || key, else: key

      if Map.has_key?(acc, resolved) do
        raise ArgumentError, duplicate_key_message(module, resolved)
      end

      Map.put(acc, resolved, value)
    end)
  end

  @doc false
  @spec __cast__(module(), term()) :: {:ok, struct()} | {:error, [issue()]}
  def __cast__(module, %mod{} = input) when mod == module do
    case missing_required(module, Map.from_struct(input)) do
      [] -> {:ok, input}
      issues -> {:error, issues}
    end
  end

  def __cast__(_module, input) when is_struct(input) do
    {:error, [{:__struct__, :wrong_struct}]}
  end

  def __cast__(module, input) when is_map(input), do: cast_attrs(module, input)

  # NOT `cast_attrs(module, Map.new(input))`: `Map.new/1` collapses
  # `[name: "A", name: "B"]` into one entry BEFORE `resolve_keys/2` can see the
  # pairs, so the duplicate would go unreported on the shape every production
  # `Input.new/1` call site actually uses. `resolve_keys/2` reduces over
  # `{key, value}` pairs and works on a keyword list unchanged.
  def __cast__(module, input) when is_list(input) do
    if Keyword.keyword?(input) do
      cast_attrs(module, input)
    else
      {:error, [{:__input__, :not_castable}]}
    end
  end

  def __cast__(_module, _input), do: {:error, [{:__input__, :not_castable}]}

  @spec cast_attrs(module(), map() | keyword()) :: {:ok, struct()} | {:error, [issue()]}
  defp cast_attrs(module, attrs) do
    {resolved, unknown} = resolve_keys(module.__allm_schema__(:fields), attrs)

    case unknown ++ missing_required(module, resolved) do
      [] -> {:ok, struct!(module, resolved)}
      issues -> {:error, issues}
    end
  end

  # Two keys can resolve to ONE field in either input shape: `%{"name" => "A",
  # name: "B"}`, because a string key is matched against the declared field
  # names, and `[name: "A", name: "B"]`, because a keyword list simply permits
  # repeats. Folding both into one `Map.put/3` (what this did before subphase
  # 2.3) silently kept whichever value was visited last and reported nothing,
  # which is the one input shape D1's reason set could not describe and a direct
  # contradiction of D2's "unknown keys are an error, never silently dropped".
  # The field NAME is reported and neither value is, because which one would
  # have won is unspecified and no caller may depend on it.
  @spec resolve_keys([atom()], map() | keyword()) :: {map(), [issue()]}
  defp resolve_keys(fields, attrs) do
    Enum.reduce(attrs, {%{}, []}, fn {key, value}, {resolved, issues} ->
      case resolve_key(key, fields) do
        nil ->
          {resolved, issues ++ [{issue_key(key), :unknown_field}]}

        field ->
          if Map.has_key?(resolved, field) do
            {resolved, issues ++ [{field, :duplicate_key}]}
          else
            {Map.put(resolved, field, value), issues}
          end
      end
    end)
  end

  @spec resolve_key(term(), [atom()]) :: atom() | nil
  defp resolve_key(key, fields) when is_atom(key), do: if(key in fields, do: key, else: nil)
  defp resolve_key(key, fields) when is_binary(key), do: resolve_string_key(key, fields)
  defp resolve_key(_key, _fields), do: nil

  @spec resolve_string_key(String.t(), [atom()]) :: atom() | nil
  defp resolve_string_key(key, fields), do: Enum.find(fields, &(Atom.to_string(&1) == key))

  # An unknown key is reported as written where that is expressible. A key that
  # matches no declared field cannot be safely converted to an atom, so a
  # string stays a string and anything more exotic is rendered.
  @spec issue_key(term()) :: atom() | String.t()
  defp issue_key(key) when is_atom(key) or is_binary(key), do: key
  defp issue_key(key), do: inspect(key)

  @spec missing_required(module(), map()) :: [issue()]
  defp missing_required(module, attrs) do
    for field <- module.__allm_schema__(:required),
        is_nil(Map.get(attrs, field)),
        do: {field, :missing}
  end

  @spec unknown_option_message(module(), atom(), [atom()]) :: String.t()
  defp unknown_option_message(module, name, unknown) do
    "#{inspect(module)}: unknown option(s) #{inspect(unknown)} on `field :#{name}`. " <>
      "Known field options: #{inspect(@field_options)}."
  end

  @spec duplicate_key_message(module(), atom() | String.t()) :: String.t()
  defp duplicate_key_message(module, field) do
    "#{inspect(module)}: the field #{inspect(field)} was supplied twice — under both its " <>
      "atom key and its string key, or repeated in a keyword list. Which value would " <>
      "survive is unspecified, so one of them would be dropped silently. Supply it once, " <>
      "or use `cast/1`, which reports this as `{#{inspect(field)}, :duplicate_key}` " <>
      "instead of raising."
  end

  @spec values_message(module(), atom(), term(), String.t()) :: String.t()
  defp values_message(module, name, values, reason) do
    "#{inspect(module)}: `field :#{name}` declares `values: #{inspect(values)}`, which " <>
      reason <> "."
  end

  @spec wire_message(module(), atom(), term()) :: String.t()
  defp wire_message(module, name, value) do
    "#{inspect(module)}: `field :#{name}` declares `wire: #{inspect(value)}`. `wire:` takes " <>
      "`false` (the model does not produce this field — exclude it from the schema) or a " <>
      "non-empty binary naming a differing wire property. Omit the option for the default, " <>
      "which is the field's own name."
  end

  @spec non_boolean_option_message(module(), atom(), atom(), term()) :: String.t()
  defp non_boolean_option_message(module, name, option, value) do
    "#{inspect(module)}: `field :#{name}` declares `#{option}: #{inspect(value)}`, but " <>
      "#{option} takes a literal `true` or `false`. A non-boolean value would be read as " <>
      "\"unset\" and the option would silently do nothing. " <>
      "Boolean field options: #{inspect(@boolean_field_options)}."
  end

  # Builds the `__allm_schema__/1` clauses. Every value is a compile-time
  # constant, so introspection costs one function call and no work at runtime.
  @spec introspection_clauses(
          [{atom(), Macro.t(), keyword()}],
          keyword(),
          [atom()],
          Macro.Env.t()
        ) ::
          Macro.t()
  defp introspection_clauses(fields, generated_types, required, env) do
    names = Enum.map(fields, fn {name, _type, _opts} -> name end)
    declared_types = Enum.map(fields, fn {name, type, _opts} -> {name, type} end)

    values = optioned(fields, :values)
    wire = optioned(fields, :wire)
    json_schema_clause = json_schema_clause(fields, generated_types, env)

    defaults =
      fields
      |> Enum.map(fn {name, _type, opts} -> {name, Keyword.get(opts, :default)} end)
      |> Enum.reject(fn {_name, default} -> is_nil(default) end)

    artifact = flagged(fields, :artifact)
    log_false = flagged(fields, :log, false)
    dropped = Enum.filter(names, &(&1 in artifact or &1 in log_false))
    kept = flagged(fields, :log)

    quote do
      @doc false
      @spec __allm_schema__(atom()) :: term()
      def __allm_schema__(:fields), do: unquote(names)
      def __allm_schema__(:types), do: unquote(Macro.escape(declared_types))
      def __allm_schema__(:generated_types), do: unquote(Macro.escape(generated_types))
      def __allm_schema__(:required), do: unquote(required)
      def __allm_schema__(:defaults), do: unquote(Macro.escape(defaults))
      def __allm_schema__(:dropped), do: unquote(dropped)
      def __allm_schema__(:kept), do: unquote(kept)
      def __allm_schema__(:declared_logged), do: unquote(names -- dropped)
      def __allm_schema__(:artifact), do: unquote(artifact)
      def __allm_schema__(:redacted), do: unquote(flagged(fields, :redact))
      def __allm_schema__(:nilable), do: unquote(flagged(fields, :nilable))
      def __allm_schema__(:values), do: unquote(Macro.escape(values))
      def __allm_schema__(:wire), do: unquote(Macro.escape(wire))
      unquote(json_schema_clause)
    end
  end

  @spec flagged([{atom(), Macro.t(), keyword()}], atom(), boolean()) :: [atom()]
  defp flagged(fields, option, value \\ true) do
    for {name, _type, opts} <- fields, Keyword.get(opts, option) == value, do: name
  end

  # Declaration-ordered `{field, value}` pairs for the fields carrying `option`.
  # A keyword list rather than a map, because declaration order is the contract
  # (`Map.keys/1` would sort) and because the coercion path in
  # `ALLM.Pipeline.LLMStep` walks it.
  @spec optioned([{atom(), Macro.t(), keyword()}], atom()) :: keyword()
  defp optioned(fields, option) do
    for {name, _type, opts} <- fields, Keyword.has_key?(opts, option) do
      {name, Keyword.fetch!(opts, option)}
    end
  end

  # The derivation is opt-in (`use ALLM.Pipeline.Schema, json_schema: true`).
  # Without the opt-in this emits nothing at all, so `:json_schema` raises
  # `FunctionClauseError` exactly like any other unknown key — the alternative,
  # deriving unconditionally, would make every schema in the tree carrying a
  # `map()` / `term()` / bare `list()` field fail to compile.
  #
  # The derivation reads the GENERATED types, never the declared ones: the
  # `| nil` tail the narrow nilability rule appends is precisely the
  # strict-mode nullable-union decision, and `__allm_schema__(:nilable)`
  # reports only explicit `nilable: true` declarations, so neither of the other
  # two keys can answer this question.
  @spec json_schema_clause([{atom(), Macro.t(), keyword()}], keyword(), Macro.Env.t()) ::
          Macro.t()
  defp json_schema_clause(fields, generated_types, env) do
    if Module.get_attribute(env.module, :schema_json_schema) do
      specs =
        Enum.map(fields, fn {name, _declared, opts} ->
          {name, Keyword.fetch!(generated_types, name), opts}
        end)

      derived = ALLM.Pipeline.Schema.JsonSchema.derive!(env.module, specs, env)

      quote do
        def __allm_schema__(:json_schema), do: unquote(Macro.escape(derived))
      end
    else
      quote do
      end
    end
  end
end
