defmodule ALLM.Pipeline.Encodable do
  @moduledoc """
  The single implementation of "make an arbitrary term safe for a jsonb column".

  Two divergent copies of this used to exist — `Runner.normalize_metadata/1` and
  `PipelineRun.stringify_keys/1` — and a term that survived one crashed the
  other. Worse, they ran in SEQUENCE on the create path
  (`Runner.create_pipeline_run/3` normalized, then `PipelineRun.create/3`
  stringified the same term), so metadata was double-processed on every run
  while `complete/2` and `fail/2` saw only the second set of rules. This module
  takes the UNION of both rule sets:

  | Term | Encoded as | Came from |
  |---|---|---|
  | `Decimal` | float | `stringify_keys/1` |
  | `DateTime` / `NaiveDateTime` / `Date` / `Time` | ISO-8601 string | `normalize_metadata/1` |
  | `Ecto.Changeset` | `%{"changeset_errors" => …}` | `stringify_keys/1` |
  | any other struct | `Map.from_struct/1`, recursed | `normalize_metadata/1` |
  | map | string keys, values recursed | both |
  | non-empty keyword list | map | `normalize_metadata/1` |
  | any other list | list, elements recursed | both |
  | tuple | list | `stringify_keys/1` |
  | binary | NUL/invalid-UTF-8 scrubbed | neither (see below) |

  ## Idempotency is a hard requirement

  Because the create path applied both functions in sequence, the unified
  implementation is applied **twice** to the same term there. Every rule above
  is therefore a fixed point after one pass: a rendered changeset is a plain
  map, a flattened tuple is a list, a float stays a float, an ISO-8601 string
  stays a string, and `String.to_string/1`-ed keys re-stringify to themselves.
  `encode(encode(term)) == encode(term)` is pinned by test.

  ## Two deliberate divergences from what either function did alone

  1. **`[]` stays `[]`.** `Keyword.keyword?([])` is `true`, so
     `normalize_metadata/1` turned every empty list into `%{}` while
     `stringify_keys/1` left it a list — the two paths already disagreed, and
     unification had to pick one. An empty list is overwhelmingly an empty
     collection (`errors: []`, `Keyword.take(opts, …)` on no opts), not an
     empty object, so only a NON-EMPTY keyword list becomes a map.
  2. **Binaries are scrubbed.** Neither function did this, but `StepLog`'s
     serializer has always had to (`Text.scrub/1`) for exactly the
     reason that applies here: an un-scrubbed NUL or invalid UTF-8 byte fails
     the jsonb write with `ERROR 22P05`. On the metadata path that aborts a run
     at `complete/2` — after every item has already been processed.

  ## Not unified here

  `StepLog.serialize_struct/1` / `maybe_serialize/1` is a third serializer with
  a *different* contract: it applies the heavy-field drop list and deliberately
  preserves atom map keys. It overlaps on the Calendar and binary rules only.
  Folding the two together is Phase 2 work (design doc §3.5's two-layer
  serializer), not this one.
  """

  alias ALLM.Pipeline.Text

  @doc """
  Encode `term` into a shape `Jason` can serialize into a jsonb column.

  Idempotent: safe to apply to an already-encoded term.
  """
  @spec encode(term()) :: term()
  def encode(%Decimal{} = value), do: Decimal.to_float(value)

  # Calendar structs carry a `microsecond: {n, precision}` tuple Jason cannot
  # encode, and they are not Enumerable, so render them rather than recursing.
  def encode(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def encode(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def encode(%Date{} = value), do: Date.to_iso8601(value)
  def encode(%Time{} = value), do: Time.to_iso8601(value)

  # A failed loader returns its `Ecto.Changeset`, which pipelines stash in
  # `metadata["errors"]` (e.g. `{bill_number, changeset}`). A changeset has no
  # `Jason.Encoder` impl, so left alone it crashes the jsonb write — aborting the
  # whole run on the final `complete/2` even though every item was processed.
  # Reduce it to its rendered, JSON-safe validation errors instead.
  def encode(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    %{"changeset_errors" => encode(errors)}
  end

  # Any other struct is `is_map/1`-true but NOT Enumerable, so it would crash the
  # map clause below. Drop `__struct__` and recurse over its fields.
  def encode(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> encode()
  end

  def encode(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), encode(v)} end)
  end

  # A non-empty keyword list is an options blob and reads far better as a jsonb
  # object. `[]` is left alone — see the moduledoc's divergence (1).
  def encode(value) when is_list(value) do
    if value != [] and Keyword.keyword?(value) do
      value
      |> Map.new()
      |> encode()
    else
      Enum.map(value, &encode/1)
    end
  end

  # `Jason.Encoder` has no impl for tuples, and pipelines stash
  # `{meeting_id, error_reason}` pairs in `metadata["errors"]`. Without this,
  # those crash the Postgres write the moment a single item fails.
  def encode(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&encode/1)
  end

  def encode(value) when is_binary(value), do: Text.scrub(value)

  def encode(value), do: value
end
