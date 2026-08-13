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
    end
  end
  ```

  ## Options

  - `json: true` - Adds `@derive Jason.Encoder` to make the struct JSON-encodable

  ## Field Options

  - `:required` - When `true`, adds the field to `@enforce_keys`
  - `:default` - The default value for the field (defaults to `nil`)

  ## Generated Functions

  - `new/0` - Creates a struct with defaults (only when no required fields)
  - `new/1` - Creates a struct from a keyword list
  """

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
  """
  defmacro field(name, type, opts \\ []) do
    quote do
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
        @doc "Creates a new struct from a keyword list."
        @spec new(keyword()) :: t()
        def new(attrs) when is_list(attrs), do: struct!(__MODULE__, attrs)
      end

    quote do
      unquote(json_derive)
      unquote(enforce_keys)
      defstruct unquote(struct_fields)
      unquote(type_def)
      unquote(new_0)
      unquote(new_1)
    end
  end

  @doc false
  def process_fields(fields) do
    Enum.reduce(fields, {[], [], []}, fn {name, type, opts}, {required, struct_def, type_def} ->
      is_required = Keyword.get(opts, :required, false)
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
end
