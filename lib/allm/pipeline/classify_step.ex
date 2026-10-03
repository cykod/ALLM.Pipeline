defmodule ALLM.Pipeline.ClassifyStep do
  @moduledoc """
  A macro for a step that classifies its input with ALLM's typed
  classification (`ALLM.classify/3`) and returns a typed Output struct.

  Where `ALLM.Pipeline.LLMStep` asks a model for a structured payload, a
  classify step asks typed questions — pick one option, place the input on a
  scale, give the probability of "yes" — and gets one
  `ALLM.ClassificationAnswer` per question back. The Output declaration says
  which answer lands in which field and in what representation.

      defmodule MyApp.TriageStep do
        use ALLM.Pipeline.ClassifyStep, type: :triage, engine: :classifier

        alias ALLM.ClassificationQuestion

        input_schema do
          field :text, String.t(), required: true
        end

        output_schema do
          field :department, atom(), values: [:billing, :technical, :other]
          field :frustration, float()
          field :refund, float()
          field :tokens_used, integer()
        end

        def state(%Input{text: text}), do: text

        def questions(_input) do
          %{
            department: ClassificationQuestion.choice("Which department?", ["billing", "technical"]),
            frustration: ClassificationQuestion.score("How frustrated?", ["calm", "annoyed", "furious"]),
            refund: ClassificationQuestion.yes_no("Is a refund requested?")
          }
        end
      end

  ## Options

  `type:` (the `step_type/0` atom) and `engine:` (a host engine name) are
  required. `input:` / `output:` name the schema modules and default to the
  using module's nested `Input` / `Output`, which `input_schema/2` and
  `output_schema/2` (imported from `ALLM.Pipeline.Schema`) declare inline. The
  Output needs no `json_schema: true` — classification has no response
  format. An unknown option is a compile error.

  ## The engine and the seam

  The call goes through the host's `ALLM.Pipeline.LLM` adapter, like an
  LLM step's: `engine:` resolves through `resolve_engine/2` (or `/1`) at call
  time — the host maps the name to an `ALLM.Engine` carrying a
  `:classification_adapter` — and the request is dispatched through the
  adapter's optional `classify/4`, handed the step's context. An adapter
  without `classify/4` raises, naming the callback.

  ## What it generates

  | Function | Contract |
  |---|---|
  | `step_type/0`, `input_schema/0`, `output_schema/0` | the `ALLM.Pipeline.Step` callbacks, from the `use` options |
  | `call_classifier/2` | `(context, input)`: `state/1` and `questions/1` → the adapter's `classify/4`; `{:ok, answers, tokens}`, `{:error, {:invalid_questions, _}}` or `{:error, {:llm_error, reason}}` |
  | `coerce/2` | answers + token count → the Output struct |
  | `post_process/2` | identity; the ordinary hook, **overridable** |
  | `execute/2` | a thin composition of the three above, **overridable** |

  It also injects `@behaviour ALLM.Pipeline.Step`, so a census that finds
  steps by the attribute finds this one. `call_classifier/2` and `coerce/2` are
  public so an overriding `execute/2` can call them itself.

  **Required of the using module:** `state/1` (Input struct → the text, map or
  list to classify) and `questions/1` (Input struct → a map of question id —
  atom or string — to `ALLM.ClassificationQuestion`).

  **Checked at compile time**, all naming the offending module: `input:` names
  a compiled struct module; `output:` names an `ALLM.Pipeline.Schema` module;
  no Output field declares `wire:` (a question id IS the field name — a
  second, wire name would make it ambiguous); every `atom()` Output field
  declares `values:` (there is no other allowlist for the chosen option); and
  `state/1` and `questions/1` exist.

  ## Question ids

  Ids are normalized to strings and must name Output fields. Before anything
  is dispatched, `call_classifier/2` refuses — with no provider call and no
  log — the first of these that applies:

  | Problem | Result |
  |---|---|
  | `questions/1` returned an empty map | `{:error, {:invalid_questions, empty: []}}` |
  | an id is not an Output field name, or is `"answers"` / `"tokens_used"` | `{:error, {:invalid_questions, unknown: ids}}` |
  | two keys collapse to one id (`:team` and `"team"`) | `{:error, {:invalid_questions, duplicate: ids}}` |

  The id lists are de-duplicated and sorted. A `questions/1` returning
  anything but a map (a keyword list, say) raises `ArgumentError`, naming the
  step and `questions/1`, also before `state/1` runs.

  Anything the adapter or `ALLM.classify/3` returns as an error — validation,
  provider, missing key — is logged and returned as
  `{:error, {:llm_error, reason}}`, the tag every call across the LLM seam
  carries. A `classify/4` returning anything other than
  `{:ok, %ALLM.ClassificationResponse{}}` or `{:error, reason}` raises
  `ArgumentError`, naming the adapter.

  ## What `coerce/2` does, field by field

  For each Output field the answer is the one under the field's name. A
  field's type is read without its `| nil`, which the generated types add to
  every field with neither `required: true` nor `default:`. The first matching
  row wins:

  | Case | Result |
  |---|---|
  | the field is `answers` | the whole answers map, `ALLM.ClassificationAnswer` structs kept |
  | the field is `tokens_used` | the response's total tokens (`0` when unreported) |
  | no answer for the field | left out, so its declared `default:` applies |
  | the answer's headline value (`choice`, `score` or `yes_probability`) is `nil` | left out, so its default applies — never `:other` |
  | a choice, into an `atom()` field | matched against `values:`: a member → its atom; otherwise `:other` if declared, else an `{:unknown_value, raw}` issue |
  | a choice, into a `String.t()`, `term()` or `any()` field | the option string, unchanged |
  | a score or yes/no, into a `float()`, `number()`, `term()` or `any()` field | the float |
  | any other pairing (a probability into `boolean()`, a score into `integer()`, a choice into `float()`) | a `{:type_mismatch, answer_type}` issue |

  Issues are returned together as `{:error, {:coerce, [{field, issue}]}}`. The
  struct is built with `struct/2`, so a `required: true` field no question
  answers stays unset for `post_process/2` to fill.

  ## Thresholds are yours

  The step applies no confidence floor and routes nothing. A step that routes
  on confidence declares `field :answers, map()` and reads each answer's
  `:confidence` or probabilities in `post_process/2`.
  """

  require Logger

  alias ALLM.{ClassificationAnswer, ClassificationResponse}
  alias ALLM.Pipeline.{Context, LLM, LLMStep}

  require LLMStep

  @use_options [:type, :input, :output, :engine]
  @reserved_fields [:answers, :tokens_used]
  # The field types a score or a yes/no probability (a float) lands in.
  @float_types [:float, :number, :term, :any]

  @typedoc """
  A validated `use` declaration. `:input` and `:output` default to the using
  module's nested `Input` / `Output`.
  """
  @type declaration :: %{type: atom(), input: module(), output: module(), engine: atom()}

  @typedoc "The answers `call_classifier/2` returns, keyed by string question id."
  @type answers :: %{String.t() => ClassificationAnswer.t()}

  @typedoc "Why `call_classifier/2` refused the questions before dispatching them."
  @type invalid_questions ::
          {:invalid_questions, [empty: []] | [unknown: [String.t()]] | [duplicate: [String.t()]]}

  @doc """
  Generate the `Step` callbacks, the classification call and the coercion.

  Options — `:type` and `:engine` are required; `:input` and `:output`
  default to the using module's nested `Input` / `Output`. Also imports
  `ALLM.Pipeline.Schema.input_schema/2` and `ALLM.Pipeline.Schema.output_schema/2`.
  """
  defmacro __using__(opts) do
    quote do
      @behaviour ALLM.Pipeline.Step
      @before_compile ALLM.Pipeline.ClassifyStep

      import ALLM.Pipeline.Schema,
        only: [input_schema: 1, input_schema: 2, output_schema: 1, output_schema: 2]

      @allm_classify_step ALLM.Pipeline.ClassifyStep.__validate__!(__MODULE__, unquote(opts))
      @allm_classify_step_type Map.fetch!(@allm_classify_step, :type)
      @allm_classify_step_input Map.fetch!(@allm_classify_step, :input)
      @allm_classify_step_output Map.fetch!(@allm_classify_step, :output)

      @impl ALLM.Pipeline.Step
      @spec step_type() :: atom()
      def step_type, do: @allm_classify_step_type

      @impl ALLM.Pipeline.Step
      @spec input_schema() :: module()
      def input_schema, do: @allm_classify_step_input

      @impl ALLM.Pipeline.Step
      @spec output_schema() :: module()
      def output_schema, do: @allm_classify_step_output

      @doc """
      Validate the question ids, then classify `state/1` against
      `questions/1` through the host adapter, handed the step's `context`.

      A bare map or `nil` context is treated as an empty detached context.
      Returns `{:ok, answers, tokens}`, or an error — an adapter error is
      logged here. See `ALLM.Pipeline.ClassifyStep`.
      """
      @spec call_classifier(ALLM.Pipeline.Context.t() | map() | nil, struct()) ::
              {:ok, ALLM.Pipeline.ClassifyStep.answers(), non_neg_integer()}
              | {:error, {:llm_error, term()}}
              | {:error, ALLM.Pipeline.ClassifyStep.invalid_questions()}
      def call_classifier(context, input) do
        ALLM.Pipeline.ClassifyStep.__call_classifier__(
          __MODULE__,
          @allm_classify_step,
          questions(input),
          fn -> state(input) end,
          ALLM.Pipeline.LLM.__context__(context)
        )
      end

      @doc """
      Read classification answers into the Output struct.

      Public so an overriding `execute/2` can call it. See
      `ALLM.Pipeline.ClassifyStep`'s "What `coerce/2` does, field by field".
      """
      @spec coerce(ALLM.Pipeline.ClassifyStep.answers(), non_neg_integer()) ::
              {:ok, struct()} | {:error, {:coerce, [{atom(), term()}]}}
      def coerce(answers, tokens) do
        ALLM.Pipeline.ClassifyStep.__coerce__(@allm_classify_step_output, answers, tokens)
      end

      @doc "Rewrite the coerced Output before it is returned. Defaults to identity."
      @spec post_process(struct(), struct()) :: struct()
      def post_process(output, _input), do: output

      @impl ALLM.Pipeline.Step
      @spec execute(ALLM.Pipeline.Context.t(), struct()) :: {:ok, struct()} | {:error, term()}
      def execute(context, input) do
        with {:ok, answers, tokens} <- call_classifier(context, input),
             {:ok, output} <- coerce(answers, tokens) do
          {:ok, post_process(output, input)}
        end
      end

      defoverridable execute: 2, post_process: 2
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    declaration = Module.get_attribute(env.module, :allm_classify_step)

    LLMStep.__assert_input_struct__!(env.module, declaration.input)
    assert_schema_module!(env.module, declaration.output)
    assert_no_wire!(env.module, declaration.output)
    assert_atoms_have_values!(env.module, declaration.output)
    assert_defines!(env, {:state, 1}, "the Input struct → the text, map or list to classify")

    assert_defines!(
      env,
      {:questions, 1},
      "the Input struct → a map of question id to ALLM.ClassificationQuestion"
    )

    quote do
    end
  end

  @doc false
  @spec __validate__!(module(), term()) :: declaration()
  def __validate__!(module, opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(module)}: `use ALLM.Pipeline.ClassifyStep` takes a keyword list, " <>
              "got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @use_options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "#{inspect(module)}: unknown `use ALLM.Pipeline.ClassifyStep` option(s) " <>
                "#{inspect(unknown)}. Known options: #{inspect(@use_options)}."
    end

    %{
      type: fetch_atom!(opts, :type, module, nil),
      input: fetch_atom!(opts, :input, module, Module.concat(module, Input)),
      output: fetch_atom!(opts, :output, module, Module.concat(module, Output)),
      engine: fetch_atom!(opts, :engine, module, nil)
    }
  end

  @doc false
  # `state` is a thunk so a refused question map never evaluates `state/1`.
  @spec __call_classifier__(module(), declaration(), term(), (-> term()), Context.t()) ::
          {:ok, answers(), non_neg_integer()}
          | {:error, {:llm_error, term()}}
          | {:error, invalid_questions()}
  def __call_classifier__(module, declaration, questions, state, %Context{} = context)
      when is_map(questions) do
    with {:ok, questions} <- validate_questions(questions, declaration.output) do
      impl = LLM.impl()
      engine = LLM.__resolve_engine__(impl, declaration.engine, context)

      # `LLM.__classify__/5` enforces the callback's return shape, so a success
      # here is always a response.
      case LLM.__classify__(impl, state.(), questions, engine, context) do
        {:ok, %ClassificationResponse{answers: answers, usage: usage}} ->
          {:ok, answers, ALLM.Usage.total_tokens(usage) || 0}

        {:error, reason} ->
          # The shape of `LLMStep`'s seam-error log, minus the schema name a
          # classify step does not have.
          Logger.error("Classification error in #{inspect(module)}: " <> inspect(reason))
          {:error, LLMStep.__llm_error__(reason)}
      end
    end
  end

  # A non-map is a type error in the step, not an id problem a tuple could
  # describe — raised like the other shape errors, naming the step.
  def __call_classifier__(module, _declaration, questions, _state, _context)
      when not is_map(questions) do
    raise ArgumentError,
          "#{inspect(module)}.questions/1 must return a map of question id (atom or " <>
            "string) => ALLM.ClassificationQuestion, got: #{inspect(questions)}"
  end

  # Static author errors, checked in a fixed order and reported one at a time.
  @spec validate_questions(map(), module()) ::
          {:ok, %{String.t() => term()}} | {:error, invalid_questions()}
  defp validate_questions(questions, _output) when map_size(questions) == 0,
    do: {:error, {:invalid_questions, empty: []}}

  defp validate_questions(questions, output) do
    ids = Enum.map(questions, fn {id, _question} -> to_string(id) end)
    known = Enum.map(output.__allm_schema__(:fields) -- @reserved_fields, &Atom.to_string/1)

    cond do
      (unknown = ids |> Enum.reject(&(&1 in known)) |> Enum.uniq() |> Enum.sort()) != [] ->
        {:error, {:invalid_questions, unknown: unknown}}

      (duplicate = (ids -- Enum.uniq(ids)) |> Enum.uniq() |> Enum.sort()) != [] ->
        {:error, {:invalid_questions, duplicate: duplicate}}

      true ->
        {:ok, Map.new(questions, fn {id, question} -> {to_string(id), question} end)}
    end
  end

  @doc false
  @spec __coerce__(module(), answers(), non_neg_integer()) ::
          {:ok, struct()} | {:error, {:coerce, [{atom(), term()}]}}
  def __coerce__(output, answers, tokens) when is_map(answers) do
    values = output.__allm_schema__(:values)
    types = output.__allm_schema__(:generated_types)

    {attrs, issues} =
      Enum.reduce(output.__allm_schema__(:fields), {%{}, []}, fn
        :answers, {attrs, issues} ->
          {Map.put(attrs, :answers, answers), issues}

        :tokens_used, {attrs, issues} ->
          {Map.put(attrs, :tokens_used, tokens), issues}

        name, {attrs, issues} ->
          answer = Map.get(answers, Atom.to_string(name))

          case read(answer, unwrap_nil(Keyword.fetch!(types, name)), Keyword.get(values, name)) do
            :absent -> {attrs, issues}
            {:ok, value} -> {Map.put(attrs, name, value), issues}
            {:error, issue} -> {attrs, [{name, issue} | issues]}
          end
      end)

    case issues do
      [] -> {:ok, struct(output, attrs)}
      issues -> {:error, {:coerce, Enum.reverse(issues)}}
    end
  end

  # The headline field is matched structurally, BEFORE the vocabulary rule:
  # `is_atom(nil)` is true and `to_string(nil) == ""`, so a nil choice reaching
  # `LLMStep.__coerce_atom__/2` would become `:other` — reporting missing data
  # as a classification. (`ClassificationAnswer.value/1` is not used: its spec
  # excludes `nil`, and it raises on an unknown type.)
  @spec read(ClassificationAnswer.t() | nil, Macro.t(), [atom() | String.t()] | nil) ::
          :absent | {:ok, term()} | {:error, term()}
  defp read(nil, _type, _values), do: :absent
  defp read(%ClassificationAnswer{type: :choice, choice: nil}, _type, _values), do: :absent
  defp read(%ClassificationAnswer{type: :score, score: nil}, _type, _values), do: :absent

  defp read(%ClassificationAnswer{type: :yes_no, yes_probability: nil}, _type, _values),
    do: :absent

  defp read(%ClassificationAnswer{type: :choice, choice: choice} = answer, type, values) do
    cond do
      LLMStep.__coercion__(type) == :atom -> LLMStep.__coerce_atom__(choice, values)
      type_named?(type, [:string, :term, :any]) -> {:ok, choice}
      true -> mismatch(answer)
    end
  end

  defp read(%ClassificationAnswer{type: answer_type} = answer, type, _values)
       when answer_type in [:score, :yes_no] do
    if type_named?(type, @float_types), do: {:ok, float_value(answer)}, else: mismatch(answer)
  end

  @spec float_value(ClassificationAnswer.t()) :: float()
  defp float_value(%ClassificationAnswer{type: :score, score: score}), do: score
  defp float_value(%ClassificationAnswer{type: :yes_no, yes_probability: p}), do: p

  @spec mismatch(ClassificationAnswer.t()) :: {:error, {:type_mismatch, atom()}}
  defp mismatch(%ClassificationAnswer{type: type}), do: {:error, {:type_mismatch, type}}

  # Field types are the escaped generated-type AST, matched by name as
  # `LLMStep`'s coercion classifier matches `Date` — no `Macro.Env` exists at
  # runtime to expand an alias. `:string` stands for `String.t()`.
  @spec type_named?(Macro.t(), [atom()]) :: boolean()
  defp type_named?({{:., _, [{:__aliases__, _, [:String]}, :t]}, _, []}, names),
    do: :string in names

  defp type_named?({name, _meta, args}, names) when is_atom(name) and args in [[], nil],
    do: name in names

  defp type_named?(_type, _names), do: false

  @spec unwrap_nil(Macro.t()) :: Macro.t()
  defp unwrap_nil({:|, _meta, [type, nil]}), do: type
  defp unwrap_nil(type), do: type

  @spec assert_schema_module!(module(), module()) :: :ok
  defp assert_schema_module!(module, output) do
    if ALLM.Pipeline.Schema.JsonSchema.schema_module?(output) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(module)}: `output: #{inspect(output)}` is not an ALLM.Pipeline.Schema " <>
              "module. A classify step reads each answer into the Output field named by its " <>
              "question id, so the Output must declare its fields with `use ALLM.Pipeline.Schema` " <>
              "(or an `output_schema do … end` block)."
    end
  end

  @spec assert_no_wire!(module(), module()) :: :ok
  defp assert_no_wire!(module, output) do
    case output.__allm_schema__(:wire) do
      [] ->
        :ok

      wired ->
        raise ArgumentError,
              "#{inspect(module)}: `#{inspect(output)}` declares `wire:` on " <>
                "#{inspect(Keyword.keys(wired))}. A classify step's question id IS the field " <>
                "name; a `wire:` name would make it ambiguous which one the id means. Drop the " <>
                "option."
    end
  end

  @spec assert_atoms_have_values!(module(), module()) :: :ok
  defp assert_atoms_have_values!(module, output) do
    types = output.__allm_schema__(:generated_types)
    values = output.__allm_schema__(:values)

    open =
      for name <- output.__allm_schema__(:fields),
          LLMStep.__coercion__(Keyword.fetch!(types, name)) == :atom,
          not Keyword.has_key?(values, name),
          do: name

    if open == [] do
      :ok
    else
      raise ArgumentError,
            "#{inspect(module)}: `#{inspect(output)}` declares #{inspect(open)} as atom() " <>
              "without `values:`. The vocabulary is the only allowlist a chosen option is " <>
              "matched against; without it every answer fails to coerce. Declare " <>
              "`values: [...]` (with `:other` to absorb an unlisted option)."
    end
  end

  @spec assert_defines!(Macro.Env.t(), {atom(), arity()}, String.t()) :: :ok
  defp assert_defines!(env, {name, arity} = fun, takes) do
    if Module.defines?(env.module, fun) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(env.module)}: `use ALLM.Pipeline.ClassifyStep` requires " <>
              "`#{name}/#{arity}`, taking #{takes}."
    end
  end

  # A missing option with no default (`default: nil`) is a compile error; a
  # supplied one must pass `LLMStep.__atom_option__/1`, the shape rule both
  # step macros share. Whether a module option names a
  # real module is checked in `__before_compile__/1`, where it can be.
  @spec fetch_atom!(keyword(), atom(), module(), module() | nil) :: atom()
  defp fetch_atom!(opts, key, module, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when LLMStep.__atom_option__(value) ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "#{inspect(module)}: `#{key}:` must be an atom, got: #{inspect(other)}"

      :error when is_nil(default) ->
        raise ArgumentError,
              "#{inspect(module)}: `use ALLM.Pipeline.ClassifyStep` requires `#{key}:` " <>
                "(`type:` and `engine:` are mandatory)."

      :error ->
        default
    end
  end
end
