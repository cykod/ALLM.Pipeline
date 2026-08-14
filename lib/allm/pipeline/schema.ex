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

  ## Field Options

  | Option | Values | Effect |
  |---|---|---|
  | `:required` | `true` | adds the field to `@enforce_keys`; `cast/1` reports `:missing` |
  | `:default` | term | the struct default (a `nil` default is "no default") |
  | `:log` | `true` / `false` / unset | see "The three states of `log:`" below |
  | `:artifact` | `true` | implies `log: false`, and lists the field in `__allm_schema__(:artifact)` |
  | `:redact` | `true` | value replaced by `"[REDACTED]"` at serialization |
  | `:nilable` | `true` / `false` | overrides the generated-type nilability rule in either direction (**⚠ not yet implemented — see "Status" below**) |

  An unknown field option raises `ArgumentError` at the *using* module's compile
  time, naming the option and the field. So does a non-boolean **value** on any
  of the five boolean options (everything except `default:`): `redact: "true"`
  is a compile error rather than a silently-unredacted field.

  ### ⚠ Status: `nilable:` is declared, not yet enforced

  `nilable:` is accepted, validated and reported through `__allm_schema__/1`
  **today**, and read by **nothing**: the generated `@type t` is the declared AST
  verbatim (see `process_fields/1`), so neither direction of the override does
  anything. It lands in Phase 2 subphase 2.4, which owns deleting this section.

  `log:` / `artifact:` / `redact:` are live — read by
  `ALLM.Pipeline.StepLog.serialize_struct/2` since subphase 2.2.

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
  would destroy the value the field exists to carry. Four paths are therefore
  **not** covered, and none of them can be:

  1. **`artifact_content/1`** — an opaque binary the Step builds itself. The rule
     that replaces coverage is documentation: *a `redact: true` field must not be
     included in `artifact_content/1`.*
  2. **`ALLM.Pipeline.Executor`'s validation error messages**, which render the
     rejected term into `step_logs.error`.
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
    keys. Raises on an unknown key (`struct!/2` semantics)
  - `cast/1` — `{:ok, t()} | {:error, [issue()]}`; see below
  - `__allm_schema__/1` — introspection; see below

  ### `cast/1` does not interpret the declared type

  `cast/1` checks the *shape* of its input and nothing else:

  - the input is a map (atom or string keys), a keyword list, or an existing
    `%__MODULE__{}` — otherwise `{:error, [{:__input__, :not_castable}]}`
  - every key resolves to a declared field — otherwise `{key, :unknown_field}`
    (unknown keys are an **error**, never silently dropped)
  - every `required: true` field is present and non-nil — otherwise
    `{field, :missing}`
  - a struct of a different module → `{:error, [{:__struct__, :wrong_struct}]}`

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

  An unknown key raises `FunctionClauseError`, so a typo fails loudly.

  `:declared_logged` is deliberately **not** called `:logged`. It reports what the
  field flags say and ignores the retained fallback list, so for a struct with an
  unflagged `field :content, String.t()` it lists `:content` even though
  `:content` never reaches `output_data`. The persisted set is computable only
  with the fallback in hand, which is the serializer's job, not the schema's.

  `:types` vs `:generated_types` are equal today. They exist as separate keys
  because the nilability rule is applied by this macro and rewrites no source, so
  the *declared* AST is byte-identical before and after that change and only the
  *generated* AST moves.

  ## Not implemented here

  `values:` (an enum vocabulary) and `__allm_schema__(:json_schema)` are
  deliberately **not** part of this DSL yet. Both exist to feed the strict-mode
  JSON schema generator, whose only honest gate is a live LLM eval; they land
  together with that generator (extraction plan Phase 3). `__allm_schema__/1` is
  shaped so `:json_schema` arrives as a new key rather than as a rework.
  """

  @field_options [:required, :default, :log, :artifact, :redact, :nilable]

  # Every field option except `default:` (which takes an arbitrary term) is a
  # flag, and its value must be a literal boolean. This is validated rather than
  # coerced because the readers below test for `true` exactly: without it,
  # `redact: "true"` compiles clean and means NOT redacted — a silent
  # degradation on the one flag that exists for secrets. Validating the value
  # is also what makes the two reader styles in this module equivalent
  # (`flagged/3`'s `== value` and `process_fields/1`'s `== true`), so neither
  # has to be the odd one out.
  @boolean_field_options [:required, :log, :artifact, :redact, :nilable]

  @typedoc """
  One problem `cast/1` found.

  The first element names the offending field. It is an atom for every declared
  field and for the two whole-term slots (`:__struct__`, `:__input__`); an
  unknown key arrives as-written, so a string-keyed map's unknown key is
  reported as a `String.t()` (a key that matches no field cannot be safely
  converted to an atom).
  """
  @type issue :: {atom() | String.t(), :missing | :unknown_field | :wrong_struct | :not_castable}

  @doc false
  defmacro __using__(opts) do
    json = Keyword.get(opts, :json, false)

    quote do
      import ALLM.Pipeline.Schema, only: [schema: 1, field: 2, field: 3]
      Module.register_attribute(__MODULE__, :schema_fields, accumulate: true)
      Module.put_attribute(__MODULE__, :schema_json, unquote(json))

      @before_compile ALLM.Pipeline.Schema
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

        Raises on an unknown key (`struct!/2` semantics). Use `cast/1` when an
        unknown key should be reported rather than raised.
        """
        @spec new(keyword() | map()) :: t()
        def new(attrs) when is_list(attrs), do: struct!(__MODULE__, attrs)

        def new(attrs) when is_map(attrs) and not is_struct(attrs) do
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
        """
        @spec cast(map() | keyword() | t()) ::
                {:ok, t()} | {:error, [ALLM.Pipeline.Schema.issue()]}
        def cast(input), do: ALLM.Pipeline.Schema.__cast__(__MODULE__, input)
      end

    introspection = introspection_clauses(fields, type_fields, required_fields)

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

  @doc false
  def process_fields(fields) do
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

      # The declared type is spliced VERBATIM into `@type t` — this never adds
      # `| nil`, whatever `required`/`default` say. (An earlier comment here
      # claimed it did; it never has.) So `field(:thing, map())` declares a
      # NON-nilable field, and a runtime `is_nil(x.thing)` or `x.thing ||
      # default` on it reads to dialyzer as provably dead code. Write
      # `field(:thing, map() | nil)` yourself on any field that is genuinely nil
      # at runtime — see `HeroCropReviewer.Input.framing_bbox`.
      new_type = [{name, type} | type_def]

      {new_required, new_struct, new_type}
    end)
    |> then(fn {required, struct_def, type_def} ->
      {Enum.reverse(required), Enum.reverse(struct_def), Enum.reverse(type_def)}
    end)
  end

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

    :ok
  end

  @doc false
  @spec __atomize_keys__(module(), map()) :: map()
  def __atomize_keys__(module, attrs) do
    fields = module.__allm_schema__(:fields)

    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {resolve_string_key(key, fields) || key, value}
      {key, value} -> {key, value}
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

  def __cast__(module, input) when is_list(input) do
    if Keyword.keyword?(input) do
      cast_attrs(module, Map.new(input))
    else
      {:error, [{:__input__, :not_castable}]}
    end
  end

  def __cast__(_module, _input), do: {:error, [{:__input__, :not_castable}]}

  @spec cast_attrs(module(), map()) :: {:ok, struct()} | {:error, [issue()]}
  defp cast_attrs(module, attrs) do
    {resolved, unknown} = resolve_keys(module.__allm_schema__(:fields), attrs)

    case unknown ++ missing_required(module, resolved) do
      [] -> {:ok, struct!(module, resolved)}
      issues -> {:error, issues}
    end
  end

  @spec resolve_keys([atom()], map()) :: {map(), [issue()]}
  defp resolve_keys(fields, attrs) do
    Enum.reduce(attrs, {%{}, []}, fn {key, value}, {resolved, unknown} ->
      case resolve_key(key, fields) do
        nil -> {resolved, unknown ++ [{issue_key(key), :unknown_field}]}
        field -> {Map.put(resolved, field, value), unknown}
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

  @spec non_boolean_option_message(module(), atom(), atom(), term()) :: String.t()
  defp non_boolean_option_message(module, name, option, value) do
    "#{inspect(module)}: `field :#{name}` declares `#{option}: #{inspect(value)}`, but " <>
      "#{option} takes a literal `true` or `false`. A non-boolean value would be read as " <>
      "\"unset\" and the option would silently do nothing. " <>
      "Boolean field options: #{inspect(@boolean_field_options)}."
  end

  # Builds the `__allm_schema__/1` clauses. Every value is a compile-time
  # constant, so introspection costs one function call and no work at runtime.
  @spec introspection_clauses([{atom(), Macro.t(), keyword()}], keyword(), [atom()]) :: Macro.t()
  defp introspection_clauses(fields, generated_types, required) do
    names = Enum.map(fields, fn {name, _type, _opts} -> name end)
    declared_types = Enum.map(fields, fn {name, type, _opts} -> {name, type} end)

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
    end
  end

  @spec flagged([{atom(), Macro.t(), keyword()}], atom(), boolean()) :: [atom()]
  defp flagged(fields, option, value \\ true) do
    for {name, _type, opts} <- fields, Keyword.get(opts, option) == value, do: name
  end
end
