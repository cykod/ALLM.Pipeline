defmodule ALLM.Pipeline.Encodable do
  @moduledoc """
  The single implementation of "make an arbitrary term safe for a jsonb column".

  Two divergent copies of this used to exist — `Executor.normalize_metadata/1` and
  `PipelineRun.stringify_keys/1` — and a term that survived one crashed the
  other. Worse, they ran in SEQUENCE on the create path
  (`Executor.create_pipeline_run/3` normalized, then `PipelineRun.create/3`
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
  stays a string, and `to_string/1`-ed keys re-stringify to themselves.
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

  ## The `struct -> map` widening is a LOUD failure turned QUIET

  The `is_struct/1` rule above is the intended fix for a real abort: before it,
  a struct that reached `metadata` crashed the jsonb write at `complete/2` —
  after every item in the run had already been processed. Note what the fix
  costs, because nothing signals it: a term that used to raise now serializes
  **silently**, field by field. So a future `complete/2` metadata map that picks
  up a credential-bearing struct persists its contents to `pipeline_runs`
  with no error and no log line.

  Not reachable today — every `complete/2` call site passes counts and scalars,
  and `%ALLM.Engine{}` (the most plausible carrier) holds no `:api_key` in its
  `defstruct`. The mitigation if that changes is a field-name exclusion during
  struct flattening, mirroring `ALLM.Pipeline.StepLog`'s `@fallback_drop` and its
  `redact:` flag. Deliberately not built here: this module has no schema to read
  flags from, and a hardcoded name list is the global-by-name wart Phase 2
  removed from `StepLog`.

  ## Partly unified with `StepLog`

  `ALLM.Pipeline.StepLog.serialize_struct/2` / `maybe_serialize/2` is a second
  serializer with a *different* contract: it applies a two-layer heavy-field drop
  set (per-field `log:` / `artifact:` flags over a package fallback list),
  substitutes `"[REDACTED]"` for `redact:` fields, carries a recursion depth
  budget, and preserves nested atom map keys in the in-memory term where this
  module stringifies every key (not observable after the jsonb round-trip —
  Jason stringifies atom keys either way).

  Phase 2.2 converged the **leaves** and left the containers separate:
  `maybe_serialize/2` delegates `Decimal`, the four Calendar structs and binaries
  straight to `encode/1`, so those rules have one implementation. Its container
  clauses are re-stated rather than delegated, for two reasons that ARE
  observable in the persisted row: (a) `StepLog` applies its drop set, its
  `redact:` substitution and its depth budget *inside* every container, and this
  module applies none of them; (b) this module folds a non-empty keyword list
  into a map (`encode/1`'s list clause below) where `StepLog` maps it to a list
  of two-element lists. The tuple rule (tuple -> list) is duplicated in
  *semantics* only; `StepLog` recurses with its own function so the drop set and
  depth budget still apply inside a tuple.

  (Corrected 2026-08-14 by the 2.2 fix pass, code review F3: this section
  previously gave key-stringification as the lead reason. The decision is right;
  that reason was not observable.)

  The leaf sets are hand-mirrored across the two modules and pinned by
  `step_log_serialization_test.exs`'s "every Encodable struct rule is delegated
  here, except the declared exception" — `Ecto.Changeset` is the one declared
  divergence. Adding a struct clause here without one there reddens it.
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

  @doc """
  Render an arbitrary term into a **bounded** string for a message that will be
  persisted to `pipeline_runs.metadata` or `step_logs.error`.

  `inspect/1` is bounded in *encoding* — it renders a NUL-bearing or invalid
  UTF-8 binary in `<<…>>` byte notation, so it cannot produce a `22P05` — but it
  is unbounded in *content*: an exit reason such as
  `{:timeout, {GenServer, :call, [pid, message, 5000]}}` inlines the call's
  message term, which is exactly where a session token or bearer credential
  would sit. `Executor.render_shape/1` settled the same question for a rejected
  Step payload in subphase 2.3 by rendering type and key names only; that is the
  right trade there, where the value carries no diagnostic weight, and the wrong
  one here, where the reason IS the diagnostic. So bound it instead of erasing
  it: a truncated credential is not a credential.

  Use this — not bare `inspect/1` — for any term that reaches a persisted
  message or metadata value. `limit:` caps collection elements and
  `printable_limit:` caps binary length; struct `Inspect` implementations are
  left in place deliberately, since a `@derive {Inspect, except: …}` redaction
  is strictly better than what this can do.
  """
  @spec render(term()) :: String.t()
  def render(term), do: inspect(term, limit: 5, printable_limit: 256)
end
