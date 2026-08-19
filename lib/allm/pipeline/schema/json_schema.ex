defmodule ALLM.Pipeline.Schema.JsonSchema do
  @moduledoc """
  Derives an OpenAI **strict-mode** JSON schema from an `ALLM.Pipeline.Schema`
  declaration.

  This module exists so `ALLM.Pipeline.Schema` does not grow a second
  responsibility: the macro owns the struct, the type and the introspection
  clauses; this owns the wire contract.

  ## When it runs

  At the *using* module's compile time, from
  `ALLM.Pipeline.Schema.__before_compile__/1`, and only when that module
  declares `use ALLM.Pipeline.Schema, json_schema: true`. The derived map is
  a compile-time constant spliced into `__allm_schema__(:json_schema)` — there
  is no runtime work and no API call needed to inspect it, which is what lets
  the project rule "unit-test the NORMALIZED schema, never the raw map" apply
  to a *generated* schema at all.

  A field whose type cannot be mapped is a **compile error**, not a silent
  `{}` — the failure surfaces at build time rather than as a production 400.

  ## The type mapping

  | Declared type (from `:generated_types`) | JSON `type` |
  |---|---|
  | `String.t()` | `"string"` |
  | `String.t()` with `values:` | `"string"` + `enum` |
  | `[String.t()]` with `values:` | `"array"`; the `enum` lands on **`items`** |
  | `integer()`, `non_neg_integer()`, `pos_integer()`, `neg_integer()` | `"integer"` |
  | `float()` | `"number"` |
  | `boolean()` | `"boolean"` |
  | `atom()` with `values:` | `"string"` + `enum` (the parse path coerces back) |
  | `atom()` without `values:` | compile error — an open atom is not a closed schema |
  | `Date.t()` | `"string"` |
  | `[T]` | `"array"`, `items` derived from `T` |
  | a module exporting `__allm_schema__/1` | `"object"` — recurses |
  | `map()`, `term()`, bare `list()` | compile error |

  `values:` is accepted **only** on a `String.t()` or `atom()` field, or on the
  element type of a list of them — those are the two rows above that emit an
  `enum`. Declaring it on any other mapped type (`integer()`, `float()`,
  `boolean()`, `Date.t()`, a nested schema) is a compile error: JSON-schema
  `enum` on a non-string property would be silently meaningless to the parse
  path, which keys atom coercion off the declared type. `field/3`'s own
  `values:` validation checks the list's *shape* (non-empty, homogeneous, no
  `nil`) and cannot see the field's type; this is where the type half is
  enforced.

  ## Nullability

  A `| nil` tail on the **generated** type — the narrow nilability rule's
  output, not the declared AST — makes the emitted type a union (`"string"`
  becomes `["string", "null"]`). Every property still appears in `required`:
  strict mode expresses optionality by the null union alone, so the DSL's
  `required:` and the JSON schema's `required` are deliberately different sets.

  When a nullable field also carries `values:`, `nil` is appended to the
  emitted `enum` — a `"null"`-permitting type whose enum has no null member is
  rejected by the strict validator. `nil` is **derived, never declared**: a
  literal `nil` inside a hand-written `values:` list is a compile error, since
  `is_atom(nil)` is `true` and a bare list-of-atoms check would wave it
  through.

  ## Field inclusion is OPT-OUT, and `redact: true` must say which it means

  Every declared field reaches the derived schema — and therefore the model —
  unless it declares `wire: false`. That is the opposite of the hand-written
  schemas this replaces, which were implicit *allowlists*: a field was on the
  wire because somebody typed it there. The opt-out default is deliberate (a
  derivation whose default is "exclude" derives nothing, and every omission
  would be silent), but it moves the failure mode from "a field is missing" to
  "a field is present that nobody decided to send".

  One flag makes that disagreement likely enough to be worth catching:
  `redact: true` declares a value too sensitive to appear in a step log, and
  says nothing about whether it may be sent to a third-party model. The two are
  independent — a redacted field can legitimately be model-produced — so
  neither implication is safe to assume. **A `redact: true` field in a module
  that derives a JSON schema must therefore declare `wire:` explicitly**, one
  way or the other, or it is a compile error. `wire: false` keeps it off the
  wire; `wire: true` (or a rename) says the author looked and meant it.

  This costs a `json_schema: true` module one word per redacted field and buys
  the guarantee that no secret-bearing property reaches OpenAI by omission.
  Modules that do not derive a schema are untouched.

  ## Key casing

  The derived map is **string-keyed at every level**, matching the host
  normalizer's output. `required` is built as `Map.keys/1` of the property map
  for the same reason: it is exactly what a strict-mode normalizer would
  compute, so a derived schema is a fixed point of one — with exactly one
  exception, immediately below.

  ### The one exception: a `json_schema:` literal

  That fixed-point property holds for every **mapped** property. It does *not*
  extend to a per-field `json_schema:` literal, which is spliced in verbatim by
  design (an author reaching for the hatch has a shape the mapping cannot
  express, so second-guessing it would defeat it). A literal declaring its own
  `"properties"` without `"additionalProperties" => false` and a full
  `"required"` — or one using atom keys — makes the enclosing derived map a
  non-fixed-point of a strict-mode normalizer. **Inside a literal, strict-mode
  compliance is the author's responsibility**, and the compiler will not check
  it.

  The consequence is a divergence, not a production defect: the host's
  `LLMEngine.normalize_schema/1` runs unconditionally inside
  `generate_structured/4`, so the model still receives a repaired, compliant
  schema. What is lost is this module's headline guarantee — that a malformed
  wire contract is a *compile* error rather than something a downstream
  normalizer quietly fixes. Both halves are pinned: the package test asserts an
  object-shaped literal is emitted untouched, and the host-side
  `derived_schema_normalization_test.exs` asserts the normalizer is what repairs
  it.

  ## Nested schemas

  A field typed by a module that itself uses this DSL recurses into that
  module's own `:json_schema`. The nested module must therefore also declare
  `json_schema: true`; it is a named compile error when it does not.

  Resolution expands the alias against the *using* module's environment.
  `Module.concat/1` on the raw AST parts is **not** sufficient: the stored type
  AST is unexpanded, and nested schemas are declared inside their parent and
  referenced by short alias (`field(:key_provisions, [KeyProvision.t()])`), so
  naive resolution yields `Elixir.KeyProvision` — a module that does not exist,
  whose absence would turn a perfectly good nested schema into an unmappable
  type.

  `Code.ensure_compiled/1` — **not** `ensure_loaded?/1` — is called before
  `function_exported?/3`. The latter answers `false` for a merely-unloaded
  module, and `ensure_loaded?/1` additionally answers `false` for a module being
  compiled *concurrently in the same `mix compile` batch*, because it does not
  participate in `Kernel.ParallelCompiler`'s module handshake. That is exactly
  the cross-file case — `<step>/input.ex` beside `<step>/output.ex`, this tree's
  own convention — and it produced a bogus "no strict-mode JSON rendering" error
  pointing at a nested module that was perfectly correct.
  """

  @typedoc "One declared field: its name, its **generated** type AST, and its options."
  @type field_spec :: {atom(), Macro.t(), keyword()}

  # The modules whose `T.t()` maps to a JSON scalar rather than to a nested
  # object. ONE list, read by BOTH `resolve_module/2` (which must accept the
  # module even though it exports no `__allm_schema__/1`) and `kind/2` (which
  # maps it). Spelling it twice produced a dead clause: a type added to `kind/2`
  # alone is rejected by `resolve_module/2` first and surfaces as "unmappable
  # type", a message that points away from the cause. Every member maps to
  # `"string"` today; a member needing a different JSON type must split `kind/2`'s
  # single clause deliberately rather than by omission.
  #
  # ⚠️ THE OTHER HALF OF THIS CLASSIFIER IS `ALLM.Pipeline.LLMStep`'s
  # `coercion/1`. This list decides what the model is ASKED for; that one
  # decides how the answer is READ BACK into the struct. A module added here
  # with no matching clause there makes the schema advertise `"string"` while
  # the raw string is passed through into a field whose generated type says
  # otherwise — silent, and invisible to dialyzer. Guarded by "every known
  # scalar module … has a coercion clause" in `llm_step_test.exs`, which reads
  # this list through `__known_scalar_modules__/0`. Same shape as
  # `Amesbury.Media.UrlBuilder.@param_order` ⇔ `frontend/src/lib/media_url.ts`.
  @known_scalar_modules [String, Date]

  @doc false
  # Exposed for the parity guard named above; not part of the derivation's API.
  @spec __known_scalar_modules__() :: [module()]
  def __known_scalar_modules__, do: @known_scalar_modules

  @doc """
  Derives the strict-mode JSON schema for `module` from its field list.

  `fields` carries the **generated** type AST (`__allm_schema__(:generated_types)`),
  not the declared one — the `| nil` tail is the nullable-union decision.

  Raises `ArgumentError` naming the module and field when a type cannot be
  mapped, or when two fields resolve to the same wire property name.
  """
  @spec derive!(module(), [field_spec()], Macro.Env.t()) :: map()
  def derive!(module, fields, env) do
    no_undecided_redactions!(module, fields)

    properties =
      fields
      |> Enum.reject(fn {_name, _type, opts} -> Keyword.get(opts, :wire) == false end)
      |> Enum.map(fn {name, type, opts} ->
        {property_name(name, opts), property!(module, name, type, opts, env)}
      end)
      |> no_duplicate_properties!(module)

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => properties,
      # Not the declaration order and not the DSL's `required:` — strict mode
      # promotes *every* property, and building the list from the property map
      # is what makes the derived schema a fixed point of the host normalizer
      # (except inside a `json_schema:` literal — see the moduledoc).
      "required" => Map.keys(properties)
    }
  end

  # See "Field inclusion is OPT-OUT" in the moduledoc. The pairing of `redact:`
  # with an unstated `wire:` is the one place where the opt-out default and a
  # security-relevant flag can disagree with no signal at all, so the author is
  # made to state which they mean.
  @spec no_undecided_redactions!(module(), [field_spec()]) :: :ok
  defp no_undecided_redactions!(module, fields) do
    undecided =
      for {name, _type, opts} <- fields,
          Keyword.get(opts, :redact) == true,
          not Keyword.has_key?(opts, :wire),
          do: name

    case undecided do
      [] ->
        :ok

      names ->
        raise ArgumentError,
              "#{inspect(module)}: #{inspect(names)} declare `redact: true` without a `wire:` " <>
                "decision. Field inclusion in the derived schema is OPT-OUT, so a redacted " <>
                "field is sent to the model unless it says otherwise — and `redact:` governs " <>
                "step-log serialization, not the wire. Add `wire: false` to keep it off the " <>
                "wire, or `wire: true` (or a wire name) to say the model does produce it."
    end
  end

  @spec property_name(atom(), keyword()) :: String.t()
  defp property_name(name, opts) do
    case Keyword.get(opts, :wire) do
      wire when is_binary(wire) -> wire
      _ -> Atom.to_string(name)
    end
  end

  @spec no_duplicate_properties!([{String.t(), map()}], module()) :: map()
  defp no_duplicate_properties!(pairs, module) do
    names = Enum.map(pairs, &elem(&1, 0))

    case names -- Enum.uniq(names) do
      [] ->
        Map.new(pairs)

      dupes ->
        raise ArgumentError,
              "#{inspect(module)}: the wire property name(s) #{inspect(Enum.uniq(dupes))} are " <>
                "claimed by more than one field. A `wire:` rename that collides with another " <>
                "field's name would silently drop one of them from the schema."
    end
  end

  @spec property!(module(), atom(), Macro.t(), keyword(), Macro.Env.t()) :: map()
  defp property!(module, name, type, opts, env) do
    base =
      case Keyword.fetch(opts, :json_schema) do
        # Used verbatim: an author reaching for this has a shape the mapping
        # cannot express, so second-guessing it (including nullability) would
        # defeat the escape hatch.
        {:ok, literal} -> literal
        :error -> mapped!(module, name, type, opts, env)
      end

    case Keyword.fetch(opts, :description) do
      {:ok, description} -> Map.put(base, "description", description)
      :error -> base
    end
  end

  @spec mapped!(module(), atom(), Macro.t(), keyword(), Macro.Env.t()) :: map()
  defp mapped!(module, name, type, opts, env) do
    {base_type, nullable?} = strip_nil(type)

    module
    |> base!(name, base_type, Keyword.get(opts, :values), env)
    |> apply_nullability(nullable?)
  end

  # A union nests to the RIGHT, so the `| nil` the nilability rule appends is
  # the rightmost leaf. Anything else left in the union stays and will fail to
  # map, which is the honest answer: a two-member union has no strict-mode
  # rendering.
  @spec strip_nil(Macro.t()) :: {Macro.t(), boolean()}
  defp strip_nil({:|, meta, [left, right]}) do
    if is_nil(right) do
      {left, true}
    else
      case strip_nil(right) do
        {stripped, true} -> {{:|, meta, [left, stripped]}, true}
        {_stripped, false} -> {{:|, meta, [left, right]}, false}
      end
    end
  end

  defp strip_nil(type), do: {type, false}

  # `values:` is threaded INTO the array element rather than applied to the
  # array, matching the retired hand-written schemas (`action_types` is
  # `type: "array", items: %{type: "string", enum: [...]}`). It is also why the
  # derived `nil` member never lands on an array's items: the nullability
  # belongs to the array node, which carries no enum.
  @spec base!(module(), atom(), Macro.t(), [atom() | String.t()] | nil, Macro.Env.t()) :: map()
  defp base!(module, name, [inner], values, env) do
    %{"type" => "array", "items" => base!(module, name, inner, values, env)}
  end

  defp base!(module, name, type, values, env) do
    case kind(type, env) do
      {:scalar, "string"} ->
        with_enum(%{"type" => "string"}, values)

      {:scalar, scalar} ->
        if values, do: raise(ArgumentError, values_type_message(module, name, scalar))
        %{"type" => scalar}

      :open_atom ->
        if is_nil(values), do: raise(ArgumentError, open_atom_message(module, name))
        with_enum(%{"type" => "string"}, values)

      {:object, nested} ->
        if values, do: raise(ArgumentError, values_type_message(module, name, "object"))
        nested_schema!(module, name, nested)

      :unmappable ->
        raise ArgumentError, unmappable_message(module, name, type)
    end
  end

  @spec kind(Macro.t(), Macro.Env.t()) ::
          {:scalar, String.t()} | :open_atom | {:object, module()} | :unmappable
  defp kind({:integer, _meta, args}, _env) when args in [[], nil], do: {:scalar, "integer"}

  defp kind({:non_neg_integer, _meta, args}, _env) when args in [[], nil],
    do: {:scalar, "integer"}

  defp kind({:pos_integer, _meta, args}, _env) when args in [[], nil], do: {:scalar, "integer"}
  defp kind({:neg_integer, _meta, args}, _env) when args in [[], nil], do: {:scalar, "integer"}
  defp kind({:float, _meta, args}, _env) when args in [[], nil], do: {:scalar, "number"}
  defp kind({:boolean, _meta, args}, _env) when args in [[], nil], do: {:scalar, "boolean"}
  defp kind({:atom, _meta, args}, _env) when args in [[], nil], do: :open_atom

  defp kind({{:., _dot, [alias_ast, :t]}, _meta, []}, env) do
    case resolve_module(alias_ast, env) do
      {:ok, mod} when mod in @known_scalar_modules -> {:scalar, "string"}
      {:ok, mod} -> {:object, mod}
      :error -> :unmappable
    end
  end

  defp kind(_type, _env), do: :unmappable

  # `Macro.expand/2` first — it is the only step that turns the short alias a
  # nested schema is referenced by into the module it names. The
  # `Module.concat(env.module, ...)` candidate is the fallback for the case
  # where no alias was registered.
  @spec resolve_module(Macro.t(), Macro.Env.t()) :: {:ok, module()} | :error
  defp resolve_module({:__aliases__, _meta, parts} = alias_ast, env) when is_list(parts) do
    expanded = Macro.expand(alias_ast, %{env | function: nil})

    [expanded, Module.concat([env.module | parts])]
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
    |> Enum.find_value(:error, fn candidate ->
      if schema_module?(candidate) or candidate in @known_scalar_modules,
        do: {:ok, candidate}
    end)
  end

  defp resolve_module(mod, _env) when is_atom(mod), do: {:ok, mod}
  defp resolve_module(_other, _env), do: :error

  # `Code.ensure_compiled/1`, NOT `Code.ensure_loaded?/1`. The two differ only
  # inside `Kernel.ParallelCompiler` — which is the compiler `mix compile`
  # actually drives — and only for a module being compiled in the same batch:
  # `ensure_loaded?` answers `false` without consulting the compiler, while
  # `ensure_compiled` participates in the module handshake and blocks until the
  # sibling is available. Measured inside a live parallel compile:
  # `ensure_loaded?=false ensure_compiled=true` for a schema module in a
  # SEPARATE FILE in the same batch. With `ensure_loaded?` a cross-file nested
  # schema derived "has no strict-mode JSON rendering" — an error whose message
  # points at the nested module, which is not the problem. That layout is one
  # refactor away at all times: the tree's convention is
  # `<step>/{input,output}.ex`. Pinned by
  # `test/allm/pipeline/schema/json_schema_cross_file_test.exs`, whose fixtures
  # live in separate files precisely because a same-file fixture cannot fail.
  @doc false
  # Public within the package: `ALLM.Pipeline.LLMStep`'s `__before_compile__`
  # faces the same cross-file arrangement and must not carry a second copy of
  # the predicate whose WRONG variant is 3.1's runtime F1 and 3.2's mutant M3.
  @spec schema_module?(module()) :: boolean()
  def schema_module?(mod) do
    match?({:module, _}, Code.ensure_compiled(mod)) and
      function_exported?(mod, :__allm_schema__, 1)
  end

  @spec nested_schema!(module(), atom(), module()) :: map()
  defp nested_schema!(module, name, nested) do
    nested.__allm_schema__(:json_schema)
  rescue
    FunctionClauseError ->
      reraise ArgumentError,
              [message: nested_opt_in_message(module, name, nested)],
              __STACKTRACE__
  end

  @spec with_enum(map(), [atom() | String.t()] | nil) :: map()
  defp with_enum(schema, nil), do: schema

  defp with_enum(schema, values) do
    Map.put(schema, "enum", Enum.map(values, &to_string/1))
  end

  @spec apply_nullability(map(), boolean()) :: map()
  defp apply_nullability(schema, false), do: schema

  defp apply_nullability(schema, true) do
    schema
    |> Map.update("type", ["null"], fn type -> [type, "null"] end)
    |> then(fn nullable ->
      Map.replace_lazy(nullable, "enum", fn values -> values ++ [nil] end)
    end)
  end

  @spec unmappable_message(module(), atom(), Macro.t()) :: String.t()
  defp unmappable_message(module, name, type) do
    "#{inspect(module)}: `field :#{name}` resolves to `#{Macro.to_string(type)}`, which has no " <>
      "strict-mode JSON rendering — an open shape cannot be a closed schema. Either declare a " <>
      "nested `ALLM.Pipeline.Schema` module (with `json_schema: true`) and type the field by " <>
      "it, or supply a literal subschema with `json_schema: %{...}` on the field. If the field " <>
      "is populated by the harness rather than the model, mark it `wire: false`."
  end

  @spec open_atom_message(module(), atom()) :: String.t()
  defp open_atom_message(module, name) do
    "#{inspect(module)}: `field :#{name}` is typed `atom()` with no `values:`. An open atom " <>
      "cannot be a closed schema — declare the vocabulary with `values:`, or mark the field " <>
      "`wire: false` if the model does not produce it."
  end

  @spec values_type_message(module(), atom(), String.t()) :: String.t()
  defp values_type_message(module, name, scalar) do
    "#{inspect(module)}: `field :#{name}` declares `values:` on a field typed #{scalar}. An " <>
      "`enum` vocabulary is only meaningful on a string or atom field (or on the element type " <>
      "of a list of them)."
  end

  @spec nested_opt_in_message(module(), atom(), module()) :: String.t()
  defp nested_opt_in_message(module, name, nested) do
    "#{inspect(module)}: `field :#{name}` is typed by #{inspect(nested)}, which uses " <>
      "`ALLM.Pipeline.Schema` but does not declare `json_schema: true`. Add it to that " <>
      "module's `use` options so its own schema is derived."
  end
end
