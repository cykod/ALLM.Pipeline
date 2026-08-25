defmodule ALLM.Pipeline.LLMStep do
  @moduledoc """
  A macro for the LLM-calling half of an `ALLM.Pipeline.Step`.

  An LLM step used to carry four parallel artifacts: an Input struct, an Output
  struct, a hand-written strict-mode JSON schema, and — where the Output had an
  enum — a per-module string→atom coercion map. Phase 2 made the Output
  declaration authoritative for the struct and its types; Phase 3.1 made it
  authoritative for the JSON schema. This macro makes it authoritative for the
  **parse path** too, so a ported step carries one declaration and a prompt.

      defmodule MyStep do
        use ALLM.Pipeline.LLMStep,
          type: :transform_ordinance,
          input: __MODULE__.Input,
          output: __MODULE__.Output,
          engine: :nano,
          schema_name: "ordinance"

        @impl true
        def prompt(%Input{} = input), do: "…"
      end

  ## What it generates

  | Function | Contract |
  |---|---|
  | `step_type/0`, `input_schema/0`, `output_schema/0` | the `ALLM.Pipeline.Step` callbacks, from the `use` options |
  | `json_schema/0` | the Output's derived strict-mode schema — `output.__allm_schema__(:json_schema)` |
  | `call_llm/1` | `prompt/1` → `ALLM.Pipeline.LLM.impl().generate_structured/4`; `{:ok, parsed, tokens}` or `{:error, {:llm_error, reason}}` |
  | `coerce/2` | parsed payload + token count → the Output struct |
  | `post_process/2` | identity; the ordinary hook, **overridable** |
  | `execute/2` | a thin composition of the three above, **overridable** |

  It also injects `@behaviour ALLM.Pipeline.Step`. That is not decoration:
  the host-side census (in the Amesbury umbrella repo,
  `apps/amesbury_scraper/test/amesbury_scraper/pipeline/step_schema_census_test.exs`)
  derives the Step population two independent ways — by the attribute and by the
  exported callbacks — and asserts the sets are equal, so generating the
  callbacks without the attribute fails that test by name.

  **Required of the using module:** `prompt/1`, taking the Input struct and
  returning the prompt string or a message list. Its absence is a compile error
  naming the module.

  **Checked at compile time**, all naming the offending module: `input:` names a
  compiled struct module; `output:` names a module that answers
  `__allm_schema__(:json_schema)` (i.e. declared `json_schema: true`); that
  Output declares `tokens_used`, if at all, as `wire: false`; and `prompt/1`
  exists. The `input:`/`output:` probes both go through `Code.ensure_compiled/1`
  so a sibling-file module compiled in the same batch resolves.

  ⚠️ **`post_process/2` is not a `Step` callback** — override it with a plain
  `def`, *without* `@impl`. `@impl true` on it emits "no behaviour specifies
  such callback", which `--warnings-as-errors` turns into a build failure. The
  overridable that *is* a callback, and therefore does take `@impl true`, is
  `execute/2`.

  ## Why the parse path is separate PUBLIC functions

  `execute/2` is overridable because real steps need control flow — the
  canonical case is `AmesburyScraper.Transformers.OrdinanceTransformer`, which
  makes a conditional *second* call when the model claims an appointment but
  omits its details. A wholesale override **replaces** the generated body, so if
  the coercion lived inside `execute/2` an overriding step would have to
  hand-write it again and the macro would buy that step nothing.

  So an overriding `execute/2` calls `coerce/2` itself, and gets the wire-name
  mapping, the enum coercion and the token plumbing for free. `llm_step_test.exs`
  pins that an override calling `coerce/2` produces a struct identical to the
  generated path's.

  ## What `coerce/2` does, field by field

  It walks the Output's declared fields (`__allm_schema__(:fields)`) and
  consults `:wire`, `:values` and `:generated_types`:

    * **`wire: false`** — never read from the payload. The field is populated by
      the harness, not the model (`bill_number` from the Input, `tokens_used`
      from the response envelope), so the derived schema omits it and so does
      this.
    * **`wire: "summary"`** — read from `parsed["summary"]` into the field named
      `ai_summary`. The wire contract and the struct's field names are allowed
      to differ, and on every real transformer they do.
    * **an absent or `null` payload value** — the field is left out of the
      struct entirely, so its declared `default:` applies. This is what the
      hand-rolled `response["x"] || false` / `|| []` idioms did at every retired
      call site. A `null` **element** inside an array is dropped from the list
      for the same reason, for **every** list type (see the table below).
    * **`atom()` with `values:`** — the string is matched against the declared
      vocabulary. Never `String.to_atom/1` or `String.to_existing_atom/1` on
      model output: the vocabulary is the allowlist. An unrecognized string
      becomes `:other` **iff** `:other` is a declared member, and is otherwise a
      coercion failure that fails the step.
    * **`String.t()` with `values:`** — emitted as a JSON `enum`, stored
      unchanged. `projects.scale` is a string column and coercing it to an atom
      would change what the loader writes.
    * **`Date.t()`** — parsed from ISO-8601. An unparseable value degrades to
      `nil` rather than failing the step, matching the `parse_date/1` helpers
      this replaces; the field is nullable in the derived schema either way.
    * **`tokens_used`** — populated from the response envelope **iff** the
      Output declares the field. `MeetingImportanceScorer.Output` does not, and
      that must not raise. An Output that declares it **must** declare it
      `wire: false`; the macro refuses to compile otherwise, because the
      derivation would otherwise ask the model to invent a count `coerce/2`
      immediately overwrites.
    * **a scalar where the type says list** — a coercion failure
      (`{:not_a_list, raw}`), again for **every** list type. Strict mode
      declares `"type": "array"`, so this is a non-compliant payload, and
      `coerce/2` is the boundary that says so.

  ### Which list types `coerce/2` inspects — all of them

  The two rules above are true of every declared list type. `coercion/1` builds
  a `{:list, kind}` for **any** element type; the element kind decides only what
  happens per element. `:atom` and `:date` elements are converted, everything
  else — `[String.t()]`, a nested schema module, a nested list — is the identity
  (`coerce_scalar(:passthrough, raw, _)`). The two list-level rules are applied
  by `read/3` and `map_ok/3` **before** the element kind is consulted, so they
  do not vary with it. Measured 2026-08-19, not inferred:

  | Declared type | `coercion/1` | `["a", nil, "b"]` | a bare `"a"` |
  |---|---|---|---|
  | `[atom()]` with `values:` | `{:list, :atom}` | `[:a, :b]` — `nil` dropped | fails: `{:not_a_list, "a"}` |
  | `[Date.t()]` | `{:list, :date}` | `[~D[2026-01-01]]` — `nil` dropped | fails: `{:not_a_list, "a"}` |
  | `[String.t()]` | `{:list, :passthrough}` | `["a", "b"]` — `nil` dropped | fails: `{:not_a_list, "a"}` |

  This uniformity is deliberate and was **widened on 2026-08-19** (a user
  decision, prompted by the 3.3 review's F3). `[String.t()]` used to collapse to
  a bare `:passthrough`, which made both rules unreachable for the one list type
  every ported step actually declares — the doc said "an array" and meant
  "`[atom()]` or `[Date.t()]`". The tradeoff accepted with it: a malformed
  payload on a `[String.t()]` field that used to be absorbed silently now fails
  the step with `{:error, {:coerce, [{field, {:not_a_list, raw}}]}}`.

  **Consequence when porting a step.** A hand-rolled `filter_strings/1`-shaped
  defense on a list field is no longer load-bearing against `null` elements or a
  bare scalar — `coerce/2` is the boundary for those, whatever the element type.
  It may still be doing other work (`OrdinanceTransformer`'s drops any
  non-string element a `json_schema:`-hatched field could still admit, and its
  `parse_provisions/1` / `parse_areas/1` rebuild nested structs), and
  `post_process/2` is **public**, so a caller can hand it a struct `coerce/2`
  never touched. Keep the clauses; do not delete one merely because the coercion
  path can no longer reach it.

  The struct is built with `struct/2`, not `struct!/2`: a `required: true` field
  that is also `wire: false` (`bill_number`) is legitimately unset at this point
  and is filled by `post_process/2` or by an overriding `execute/2`.

  ### The boundary: nested schema modules are NOT rebuilt

  A field typed by a nested `ALLM.Pipeline.Schema` module keeps the model's raw
  string-keyed map. `coerce/2` resolves no aliases — it runs at runtime, where
  the `Macro.Env` that
  `ALLM.Pipeline.Schema.JsonSchema` expands short aliases against no longer
  exists — so it cannot tell `KeyProvision` inside a parent from a top-level
  module of that name. Rebuilding the nested struct is therefore the step's
  work, in `post_process/2`, which is where every transformer this replaces
  already did it (`parse_provisions/1`, `parse_appointment_details/1`).

  **Declare the STRUCT type** — `[KeyProvision.t()]` — and pin the wire shape
  with the per-field `json_schema:` hatch, so the generated `@type t` describes
  what `post_process/2` returns rather than what the wire carries; the two
  overlap at `[]`, so declaring the wire type instead is invisible to dialyzer.
  (This paragraph read "declare such a field `[String.t()]`" until 2026-08-19;
  the ordinance port measured the hatch byte-identical on the wire and
  compile-enforced — dropping it is an `ArgumentError`, since the nested struct
  does not declare `json_schema: true`.) Such a field still classifies
  `{:list, :passthrough}`, so the LIST-level rules above apply to it and its
  ELEMENTS still arrive as the model's raw maps.

  ## The engine name is the host's vocabulary

  `engine: :nano` is resolved through `ALLM.Pipeline.LLM.impl().resolve_engine/1`
  at **call** time. The package neither knows nor validates the names — see
  `ALLM.Pipeline.LLM`.
  """

  require Logger

  @use_options [:type, :input, :output, :engine, :schema_name]

  @typedoc """
  A validated `use` declaration.

  `:input` and `:output` are module names resolved in the using module's
  context, so `__MODULE__.Output` arrives here already expanded.
  """
  @type declaration :: %{
          type: atom(),
          input: module(),
          output: module(),
          engine: atom(),
          schema_name: String.t()
        }

  @doc """
  Generate the `Step` callbacks, the engine call and the parse path.

  Options — all five are required: `:type` (the `step_type/0` atom), `:input`
  and `:output` (schema modules), `:engine` (a host engine name) and
  `:schema_name` (the strict-mode schema's name on the wire).
  """
  defmacro __using__(opts) do
    quote do
      @behaviour ALLM.Pipeline.Step
      @before_compile ALLM.Pipeline.LLMStep

      @allm_llm_step ALLM.Pipeline.LLMStep.__validate__!(__MODULE__, unquote(opts))
      @allm_llm_step_type Map.fetch!(@allm_llm_step, :type)
      @allm_llm_step_input Map.fetch!(@allm_llm_step, :input)
      @allm_llm_step_output Map.fetch!(@allm_llm_step, :output)

      @impl ALLM.Pipeline.Step
      @spec step_type() :: atom()
      def step_type, do: @allm_llm_step_type

      @impl ALLM.Pipeline.Step
      @spec input_schema() :: module()
      def input_schema, do: @allm_llm_step_input

      @impl ALLM.Pipeline.Step
      @spec output_schema() :: module()
      def output_schema, do: @allm_llm_step_output

      @doc """
      The Output's derived strict-mode JSON schema.

      Derived at the Output module's compile time from its field declarations
      (`ALLM.Pipeline.Schema.JsonSchema`); this is a lookup, not a computation.
      """
      @spec json_schema() :: map()
      def json_schema, do: @allm_llm_step_output.__allm_schema__(:json_schema)

      @doc """
      Build the prompt, dispatch it, and unwrap the host's envelope.

      Returns `{:ok, parsed, tokens}` with the payload's **string** keys intact,
      or `{:error, {:llm_error, reason}}` — the error is logged here, so a
      caller's error arm need only propagate it.
      """
      @spec call_llm(struct()) ::
              {:ok, map(), non_neg_integer()} | {:error, {:llm_error, term()}}
      def call_llm(input) do
        ALLM.Pipeline.LLMStep.__call_llm__(__MODULE__, @allm_llm_step, prompt(input))
      end

      @doc """
      Read a parsed payload into the Output struct.

      Public, and public on purpose: a step that overrides `execute/2` calls
      this itself. See `ALLM.Pipeline.LLMStep`'s "Why the parse path is separate
      public functions".
      """
      @spec coerce(map(), non_neg_integer()) ::
              {:ok, struct()} | {:error, {:coerce, [{atom(), term()}]}}
      def coerce(parsed, tokens) do
        ALLM.Pipeline.LLMStep.__coerce__(@allm_llm_step_output, parsed, tokens)
      end

      @doc """
      Rewrite the coerced Output before it is returned. Defaults to identity.

      The ordinary hook — clamping a score, deriving a band, rebuilding a
      nested struct, or copying a `wire: false` field across from the Input.
      """
      @spec post_process(struct(), struct()) :: struct()
      def post_process(output, _input), do: output

      @impl ALLM.Pipeline.Step
      @spec execute(ALLM.Pipeline.Context.t(), struct()) :: {:ok, struct()} | {:error, term()}
      def execute(_context, input) do
        with {:ok, parsed, tokens} <- call_llm(input),
             {:ok, output} <- coerce(parsed, tokens) do
          {:ok, post_process(output, input)}
        end
      end

      defoverridable execute: 2, post_process: 2
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    declaration = Module.get_attribute(env.module, :allm_llm_step)

    assert_input_struct!(env.module, declaration.input)
    assert_derives_json_schema!(env.module, declaration.output)
    assert_tokens_used_off_wire!(env.module, declaration.output)
    assert_defines_prompt!(env)

    quote do
    end
  end

  @doc false
  @spec __validate__!(module(), term()) :: declaration()
  def __validate__!(module, opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: `use ALLM.Pipeline.LLMStep` takes a keyword list, " <>
              "got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @use_options do
      [] -> :ok
      unknown -> raise ArgumentError, unknown_option_message(module, unknown)
    end

    %{
      type: fetch_atom!(opts, :type, module, "an atom"),
      input: fetch_atom!(opts, :input, module, "a schema module"),
      output: fetch_atom!(opts, :output, module, "a schema module"),
      engine: fetch_atom!(opts, :engine, module, "an atom"),
      schema_name: fetch_schema_name!(opts, module)
    }
  end

  @doc false
  @spec __call_llm__(module(), declaration(), ALLM.Pipeline.LLM.prompt()) ::
          {:ok, map(), non_neg_integer()} | {:error, {:llm_error, term()}}
  def __call_llm__(module, declaration, prompt) do
    impl = ALLM.Pipeline.LLM.impl()
    engine = impl.resolve_engine(declaration.engine)
    schema = declaration.output.__allm_schema__(:json_schema)

    case impl.generate_structured(prompt, schema, declaration.schema_name, engine) do
      {:ok, %{parsed: parsed, tokens: tokens}} ->
        {:ok, parsed, tokens}

      {:error, reason} ->
        # Logged here rather than at every call site: the ~20 error arms this
        # replaces all logged, and all phrased the same fact in domain terms.
        # The module name plus the schema name is that fact without the copy.
        #
        # ⚠️ What it deliberately DROPS is the entity identifier the retired
        # per-step arms carried ("LLM error for project at #{input.address}",
        # "...scoring meeting importance #{input.meeting_id}"). These steps run
        # under `Task.async_stream` fan-out, so one failure in a batch of fifty
        # is identified here only by step type. It is a triage cost, not a data
        # loss: recover the entity from the step's `step_logs.input_data`. Giving
        # the macro an overridable `log_context/1` is routed to Phase 4 rather
        # than re-introducing a per-step error arm (code review F10, 2026-08-19).
        Logger.error(
          "LLM error in #{inspect(module)} (schema #{declaration.schema_name}): " <>
            inspect(reason)
        )

        {:error, llm_error(reason)}
    end
  end

  # The host's engine already returns `{:error, {:llm_error, _}}`; a different
  # adapter need not, and the package's contract is the tagged form.
  @spec llm_error(term()) :: {:llm_error, term()}
  defp llm_error({:llm_error, _} = tagged), do: tagged
  defp llm_error(reason), do: {:llm_error, reason}

  @doc false
  @spec __coerce__(module(), map(), non_neg_integer()) ::
          {:ok, struct()} | {:error, {:coerce, [{atom(), term()}]}}
  def __coerce__(output, parsed, tokens) when is_map(parsed) do
    fields = output.__allm_schema__(:fields)
    wire = output.__allm_schema__(:wire)
    values = output.__allm_schema__(:values)
    types = output.__allm_schema__(:generated_types)

    {attrs, issues} =
      Enum.reduce(fields, {%{}, []}, fn name, {attrs, issues} ->
        case Keyword.get(wire, name) do
          # `wire: false` — populated by the harness, absent from the schema,
          # and therefore never read back from the payload.
          false ->
            {attrs, issues}

          wire_name ->
            key = if is_binary(wire_name), do: wire_name, else: Atom.to_string(name)

            case read(
                   Map.get(parsed, key),
                   Keyword.fetch!(types, name),
                   Keyword.get(values, name)
                 ) do
              :absent -> {attrs, issues}
              {:ok, value} -> {Map.put(attrs, name, value), issues}
              {:error, issue} -> {attrs, [{name, issue} | issues]}
            end
        end
      end)

    attrs = if :tokens_used in fields, do: Map.put(attrs, :tokens_used, tokens), else: attrs

    case issues do
      # `struct/2`, not `struct!/2`: a `required: true` field that is also
      # `wire: false` is legitimately unset here and is filled downstream.
      [] -> {:ok, struct(output, attrs)}
      issues -> {:error, {:coerce, Enum.reverse(issues)}}
    end
  end

  # An absent or null value is left OUT of the attrs, so the field's declared
  # `default:` applies — which is what `response["x"] || false` did by hand.
  @spec read(term(), Macro.t(), [atom() | String.t()] | nil) ::
          :absent | {:ok, term()} | {:error, term()}
  defp read(nil, _type, _values), do: :absent

  defp read(raw, type, values) do
    case coercion(type) do
      {:list, inner} when is_list(raw) ->
        map_ok(raw, inner, values)

      # A scalar where the field's generated type says list — for EVERY list
      # type, since 2026-08-19 (see the moduledoc's table). Strict mode declares
      # `"type": "array"`, so a compliant provider cannot send this — but
      # `coerce/2` IS the boundary against model output, and passing the value
      # through unchanged writes a bare string into a field typed `[atom()]` or
      # `[String.t()]` that nothing downstream re-checks.
      {:list, _inner} ->
        {:error, {:not_a_list, raw}}

      kind ->
        coerce_scalar(kind, raw, values)
    end
  end

  @spec map_ok([term()], :atom | :date | :passthrough, [atom() | String.t()] | nil) ::
          {:ok, [term()]} | {:error, term()}
  defp map_ok(raw, inner, values) do
    Enum.reduce_while(raw, {:ok, []}, fn
      # A `null` ELEMENT is DROPPED, mirroring `read/3`'s treatment of a
      # top-level null. It must be matched here, ahead of `coerce_scalar/3`,
      # for the same reason the `nil ->` arm of the vocabulary match below comes
      # first: `is_atom(nil)` is `true`, so a null element satisfies
      # `coerce_scalar(:atom, raw, values)`'s head guard, misses the vocabulary
      # as `to_string(nil) == ""`, and reaches `unknown_value/2` — which reports
      # MISSING data as `:other` wherever `:other` is declared. The `:date`
      # inner kind has the same shape one clause over (`{:ok, nil}`), writing a
      # `nil` member into a `[Date.t()]` list. Strict mode makes both unlikely
      # (an array's `items` carries no `null` member) but a field-level
      # `json_schema:` literal can produce exactly this payload. For a
      # `:passthrough` element kind the drop is not a correctness repair but the
      # rule itself — `coerce_scalar(:passthrough, nil, _)` would happily store
      # the `nil`, and the moduledoc promises it is dropped.
      nil, {:ok, acc} ->
        {:cont, {:ok, acc}}

      element, {:ok, acc} ->
        case coerce_scalar(inner, element, values) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          {:error, _} = error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  @spec coerce_scalar(:atom | :date | :passthrough, term(), [atom() | String.t()] | nil) ::
          {:ok, term()} | {:error, term()}
  # Unreachable from a module that derives a JSON schema —
  # `JsonSchema.no_open_atom!/5` refuses to compile an `atom()` field with no
  # `values:`, and (since 3.3) a field-level `json_schema:` literal does not
  # excuse it. Reachable only by calling `__coerce__/3` against a schema module
  # that never opted in. It is an ERROR, not the passthrough it used to be: with
  # no vocabulary there is nothing to match the model's string against, and
  # passing it through writes a raw binary into a field whose generated type
  # says `atom()` — a lie `struct/2` cannot catch and dialyzer cannot see.
  defp coerce_scalar(:atom, raw, nil), do: {:error, {:no_vocabulary, raw}}

  defp coerce_scalar(:atom, raw, values) when is_binary(raw) or is_atom(raw) do
    string = to_string(raw)

    case Enum.find(values, fn value -> to_string(value) == string end) do
      # `nil` FIRST, and it must stay first: `is_atom(nil)` is `true`, so a
      # `member when is_atom(member)` clause above it swallows the not-found
      # case and every unrecognized value silently becomes `nil` — neither the
      # `:other` fallback nor the coercion failure would ever fire.
      nil ->
        unknown_value(raw, values)

      # A declared vocabulary is a compile-time, author-controlled, bounded set
      # — not model output — so converting a member is safe where converting
      # `raw` would not be. `values:` on an `atom()` field is normally declared
      # as atoms; this covers a string vocabulary declared on one.
      member when is_atom(member) ->
        {:ok, member}

      member when is_binary(member) ->
        {:ok, String.to_atom(member)}
    end
  end

  defp coerce_scalar(:atom, raw, values), do: unknown_value(raw, values)

  defp coerce_scalar(:date, %Date{} = date, _values), do: {:ok, date}

  defp coerce_scalar(:date, raw, _values) when is_binary(raw) do
    # Degrades to nil rather than failing the step: every `parse_date/1` this
    # replaces did, and the property is nullable in the derived schema anyway.
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp coerce_scalar(:date, _raw, _values), do: {:ok, nil}

  defp coerce_scalar(:passthrough, raw, _values), do: {:ok, raw}

  @spec unknown_value(term(), [atom() | String.t()]) :: {:ok, :other} | {:error, term()}
  defp unknown_value(raw, values) do
    # `:other` is a fallback only where the vocabulary declares it. An
    # unconditional fallback would turn every model mistake into a silent
    # reclassification.
    if :other in values, do: {:ok, :other}, else: {:error, {:unknown_value, raw}}
  end

  @doc false
  # Exposed for ONE reason: the parity guard in `llm_step_test.exs`. See
  # `coercion/1` below for why that guard exists.
  @spec __coercion__(Macro.t()) ::
          :atom | :date | :passthrough | {:list, :atom | :date | :passthrough}
  def __coercion__(type), do: coercion(type)

  # The three ELEMENT coercions the parse path performs, keyed off the field's
  # GENERATED type. Everything else — including a nested schema module — passes
  # through unchanged; see the moduledoc's "The boundary". The list-ness of a
  # field is a SEPARATE axis: every `[_]` type is `{:list, _}`, and the element
  # kind inside it only selects the per-element conversion.
  #
  # Runs at runtime over the escaped type AST, so no `Macro.Env` is available
  # and no alias can be expanded: `Date` is matched by its own name, which is
  # the only alias this needs to recognize.
  #
  # ⚠️ THE OTHER HALF OF THIS CLASSIFIER IS
  # `ALLM.Pipeline.Schema.JsonSchema`'s `@known_scalar_modules` + `kind/2`.
  # The two walk the same generated-type AST in the same vocabulary and are the
  # two halves of one wire contract: `JsonSchema` decides what the model is
  # ASKED for, this decides how the answer is READ BACK. If they disagree no
  # test fails and no type error is raised — a wrongly classified value simply
  # lands in the struct in the wrong representation, and dialyzer cannot see it
  # because the struct is built with `struct/2` from a runtime map. Adding a
  # module to `@known_scalar_modules` (`DateTime`, `NaiveDateTime`, `Decimal`
  # are the obvious candidates) without adding a clause here makes the schema
  # advertise `"string"` while the value falls through to `:passthrough`.
  # Guarded by "every known scalar module … has a coercion clause" in
  # `llm_step_test.exs`, via `__coercion__/1` above.
  @spec coercion(Macro.t()) ::
          :atom | :date | :passthrough | {:list, :atom | :date | :passthrough}
  defp coercion({:|, _meta, [left, right]}) do
    if is_nil(right), do: coercion(left), else: :passthrough
  end

  # EVERY list type is `{:list, _}` — the element kind only decides what
  # `map_ok/3` does per element. A `[String.t()]` field used to collapse to a
  # bare `:passthrough`, which made `read/3`'s non-list arm and `map_ok/3`'s
  # null-element drop unreachable for it, so the two rules the moduledoc states
  # held for `[atom()]` / `[Date.t()]` and silently not for the type every
  # ported step actually declares. A nested list (`[[String.t()]]`) is
  # `{:list, :passthrough}` too: its elements are lists, and `:passthrough` is
  # the identity on them — `map_ok/3` never receives a `{:list, _}` inner kind,
  # for which `coerce_scalar/3` has no clause.
  defp coercion([inner]) do
    case coercion(inner) do
      kind when kind in [:atom, :date] -> {:list, kind}
      _otherwise -> {:list, :passthrough}
    end
  end

  defp coercion({:atom, _meta, args}) when args in [[], nil], do: :atom

  defp coercion({{:., _dot, [{:__aliases__, _alias_meta, [:Date]}, :t]}, _meta, []}), do: :date

  defp coercion(_type), do: :passthrough

  # The only real check `input:` gets, and the only place it can run: at `use`
  # time the option is a bare atom (see `fetch_atom!/4`), while here the
  # compiler can be asked whether it names a compiled struct module. Through
  # `Code.ensure_compiled/1` — the Input is conventionally `<step>/input.ex`, a
  # sibling compiled in the same batch, which is exactly the arrangement
  # `ensure_loaded?/1` gets wrong (see `JsonSchema.schema_module?/1`).
  #
  # A STRUCT, deliberately, not an `ALLM.Pipeline.Schema` module:
  # `input_schema/0` is allowed to name a plain `defstruct` — see
  # `ALLM.Pipeline.Executor.validate_against/3`'s non-DSL fallback and the
  # census test that pins its membership.
  @spec assert_input_struct!(module(), module()) :: :ok
  defp assert_input_struct!(module, input) do
    if match?({:module, _}, Code.ensure_compiled(input)) and
         function_exported?(input, :__struct__, 0) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(module)}: `input: #{inspect(input)}` does not name a compiled struct " <>
              "module. `prompt/1` receives the Input STRUCT, and `ALLM.Pipeline.Executor` " <>
              "casts the step's input against it, so an atom that merely looks like a module " <>
              "surfaces far from here — as an `UndefinedFunctionError` on the first run."
    end
  end

  # `__coerce__/3` special-cases `:tokens_used` BY NAME, overwriting whatever
  # the payload carried with the response envelope's count. The derivation
  # (`ALLM.Pipeline.Schema.JsonSchema`) knows nothing of that convention, so an
  # Output declaring the field without `wire: false` still ASKS the model for a
  # token count it cannot know: measured before this guard existed, the derived
  # properties were `["summary", "tokens_used"]`. It costs schema tokens on
  # every call and the answer is discarded.
  #
  # A compile error rather than an implied `wire: false`, matching
  # `JsonSchema.no_undecided_redactions!/2`: whether a property reaches the wire
  # is an author decision, and field inclusion is OPT-OUT by design. The two
  # halves of the convention are then symmetric — the coercion knows the name,
  # and so does the guard.
  @spec assert_tokens_used_off_wire!(module(), module()) :: :ok
  defp assert_tokens_used_off_wire!(module, output) do
    fields = output.__allm_schema__(:fields)
    wire = output.__allm_schema__(:wire)

    if :tokens_used in fields and Keyword.get(wire, :tokens_used) != false do
      raise ArgumentError,
            "#{inspect(module)}: `#{inspect(output)}` declares `tokens_used` without " <>
              "`wire: false`, so the derived schema asks the model for it. `coerce/2` " <>
              "populates that field from the response envelope and overwrites whatever the " <>
              "payload carried — the model is being asked to invent a token count it cannot " <>
              "know, on every call, for an answer that is discarded. Declare it " <>
              "`field(:tokens_used, integer(), wire: false)`."
    end

    :ok
  end

  # 3.1's derivation is OPT-IN per module (`use ALLM.Pipeline.Schema,
  # json_schema: true`), so a step whose Output forgot the opt-in would compile
  # clean and fail on its first live call with a `FunctionClauseError` naming
  # `__allm_schema__/1` — a message that points at the DSL rather than at the
  # missing option. That third conjunct is LLMStep's own concern; the first two
  # are `JsonSchema.schema_module?/1`, which is the package's ONE copy of the
  # `Code.ensure_compiled/1`-not-`ensure_loaded?/1` predicate and carries the
  # rationale for it. Do not re-inline it here — the wrong variant is 3.1's
  # runtime F1 and this batch's M3.
  @spec assert_derives_json_schema!(module(), module()) :: :ok
  defp assert_derives_json_schema!(module, output) do
    derives? =
      ALLM.Pipeline.Schema.JsonSchema.schema_module?(output) and
        match?({:ok, _}, fetch_json_schema(output))

    if derives? do
      :ok
    else
      raise ArgumentError,
            "#{inspect(module)}: `output: #{inspect(output)}` does not answer " <>
              "`__allm_schema__(:json_schema)`. An LLM step's wire contract is DERIVED from " <>
              "its Output declaration, and the derivation is opt-in — add `json_schema: true` " <>
              "to that module's `use ALLM.Pipeline.Schema` options. Without it the step would " <>
              "compile and fail on its first live call."
    end
  end

  @spec fetch_json_schema(module()) :: {:ok, map()} | :error
  defp fetch_json_schema(output) do
    {:ok, output.__allm_schema__(:json_schema)}
  rescue
    FunctionClauseError -> :error
  end

  @spec assert_defines_prompt!(Macro.Env.t()) :: :ok
  defp assert_defines_prompt!(env) do
    if Module.defines?(env.module, {:prompt, 1}) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(env.module)}: `use ALLM.Pipeline.LLMStep` requires `prompt/1`, which " <>
              "takes the Input struct and returns the prompt string (or a message list). It " <>
              "is the one thing the macro cannot generate."
    end
  end

  @spec unknown_option_message(module(), [atom()]) :: String.t()
  defp unknown_option_message(module, unknown) do
    "#{inspect(module)}: unknown `use ALLM.Pipeline.LLMStep` option(s) #{inspect(unknown)}. " <>
      "Known options: #{inspect(@use_options)}."
  end

  # ONE shape check for all four atom-valued options, with the expected kind
  # supplied for the message. `input:`/`output:` used to have a second copy of
  # this named `fetch_module!/3` whose body was byte-identical — a module IS an
  # atom, so the name promised a check it did not make and `input: :not_a_module`
  # passed. The only honest module check is that the module EXISTS, and it
  # cannot run here: at `use` time the Output is conventionally a sibling file
  # that has not been compiled yet. It runs in `__before_compile__` instead —
  # `assert_input_struct!/2` and `assert_derives_json_schema!/2`, both of which
  # go through `Code.ensure_compiled/1`'s handshake.
  @spec fetch_atom!(keyword(), atom(), module(), String.t()) :: atom()
  defp fetch_atom!(opts, key, module, expected) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) and not is_boolean(value) ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "#{inspect(module)}: `#{key}:` must be #{expected}, got: #{inspect(other)}"

      :error ->
        raise ArgumentError, missing_message(module, key)
    end
  end

  @spec fetch_schema_name!(keyword(), module()) :: String.t()
  defp fetch_schema_name!(opts, module) do
    case Keyword.fetch(opts, :schema_name) do
      {:ok, name} when is_binary(name) and name != "" ->
        name

      {:ok, other} ->
        raise ArgumentError,
              "#{inspect(module)}: `schema_name:` must be a non-empty string (it names the " <>
                "response format on the wire), got: #{inspect(other)}"

      :error ->
        raise ArgumentError, missing_message(module, :schema_name)
    end
  end

  @spec missing_message(module(), atom()) :: String.t()
  defp missing_message(module, key) do
    "#{inspect(module)}: `use ALLM.Pipeline.LLMStep` requires `#{key}:`. All of " <>
      "#{inspect(@use_options)} are mandatory — the macro derives the whole call from them, " <>
      "and a defaulted engine or schema name would be a wire-contract decision taken by " <>
      "omission."
  end
end
