defmodule ALLM.Pipeline.Text do
  @moduledoc """
  Batteries-included text handling for pipeline persistence: scrubbing text so
  Postgres will accept it, whitespace normalization, and head+tail truncation
  for oversized artifact bodies.

  ## ⚠️ `scrub/1` and `scrub_strings/1` are a deliberate DUPLICATE of `Amesbury.TextSanitizer`

  The other copy is `apps/amesbury/lib/amesbury/text_sanitizer.ex`. Neither is
  generated from the other, so per root `CLAUDE.md`'s hand-mirrored-list rule the
  pair carries a **machine drift guard**:
  `apps/amesbury_scraper/test/amesbury_scraper/text_parity_test.exs` calls both
  implementations on one shared fixture table plus a deterministic random byte
  corpus and asserts they agree. That test lives in the host tree because it is
  the only one that can see both modules — **1.D must not move it** along with
  the rest of the framework tests. Each moduledoc naming the other is the human
  index; the parity test is the enforcement.

  It is a copy rather than a move because `Amesbury.Government` calls
  `TextSanitizer.scrub/1` and `scrub_strings/1` at three sites
  (`grep -anE "TextSanitizer\\.(scrub|scrub_strings)\\(" apps/amesbury/lib/amesbury/government.ex`
  → `:1864`, `:1908`, `:2424`, measured 2026-08-13). Moving the module
  would force `{:allm_pipeline, in_umbrella: true}` into `apps/amesbury` — the
  *core* app — which the extraction plan's Decision #2 defers to Phase 7. A
  package headed for hex must own this code regardless; there is no end state in
  which `ALLM.Pipeline.Text` calls back into `Amesbury.*`.

  The duplication is inert for the length of Phases 1–6: each copy has its own
  test, the parity test above pins that they agree, and neither calls the other.
  **Phase 7 retires it** — when the core app takes the dependency,
  `Amesbury.TextSanitizer` either `defdelegate`s here or is deleted with its
  three call sites re-pointed (and the parity test goes with it: a module
  delegating to another cannot drift). Until then, a fix to one is a fix owed to
  the other.

  See `steering/2026-08-10_ALLM_PIPELINE_PHASE_1.md` §5.2.
  """

  @typedoc """
  Head+tail truncation window, in bytes. Text longer than twice this is reduced
  to the first and last `window` bytes with an elision marker between.
  """
  @type window :: pos_integer()

  @default_window 4_000

  @doc """
  Remove NUL bytes and invalid UTF-8 from `text`.

  Document extraction and external transcript feeds occasionally carry bytes
  that PostgreSQL's `text`/`jsonb` columns reject, surfacing as
  `ERROR 22P05 (untranslatable_character)` on insert. Two distinct problems are
  handled here:

    * **NUL bytes (`U+0000`).** PostgreSQL cannot store a NUL in a text column,
      yet `<<0>>` is a perfectly valid UTF-8 codepoint, so `String.valid?/1`
      reports `true` and won't catch it. These are dropped explicitly.

    * **Invalid UTF-8 byte sequences.** Mojibake / truncated multibyte
      sequences from scanned-PDF OCR. These bytes are dropped, preserving every
      well-formed codepoint around them.

  Passes `nil` through unchanged so callers can sanitize optional fields without
  a guard. The common case (already-valid text with no NUL bytes) returns the
  original binary without allocating a new one.
  """
  @spec scrub(String.t() | nil) :: String.t() | nil
  def scrub(nil), do: nil

  def scrub(text) when is_binary(text) do
    text
    |> remove_nuls()
    |> ensure_valid()
  end

  @doc """
  Scrub every binary value in a (shallow) map, leaving non-binary values
  (integers, atoms, nested structs, etc.) untouched.

  Useful for sanitizing a changeset attrs map before insert without naming each
  string field individually.
  """
  @spec scrub_strings(map()) :: map()
  def scrub_strings(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(value) -> {key, scrub(value)}
      pair -> pair
    end)
  end

  @doc """
  Collapses internal whitespace runs to a single space and trims both ends.

  The canonical cleanup for HTML-extracted text, which arrives with the source
  document's line breaks and indentation embedded.

      iex> ALLM.Pipeline.Text.normalize("  Board   Meeting\\n ")
      "Board Meeting"
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Head+tail truncate `text` to roughly `2 * window` bytes, elided in the middle.

  Used when an LLM prompt or response is too large to store whole in an artifact
  body. Both ends are kept because the interesting parts of an oversized prompt
  are its instructions (head) and its most recent context (tail); a plain prefix
  truncation discards the latter.

  Text at or under `2 * window` bytes is returned unchanged, as is `nil`, so
  callers can pipe optional fields through without a guard. `window` counts
  BYTES, not graphemes — the point is fitting a storage limit — so a cut can
  land mid-codepoint and the result is not guaranteed to be valid UTF-8. Run it
  through `scrub/1` if the result is bound for a Postgres text column.

      iex> ALLM.Pipeline.Text.truncate("abcdefghij", 2)
      "ab\\n…[truncated]…\\nij"

      iex> ALLM.Pipeline.Text.truncate("abcd", 2)
      "abcd"
  """
  @spec truncate(String.t() | nil, window()) :: String.t() | nil
  def truncate(text, window \\ @default_window)

  def truncate(text, window)
      when is_binary(text) and is_integer(window) and window > 0 and byte_size(text) > 2 * window do
    head = binary_part(text, 0, window)
    tail = binary_part(text, byte_size(text) - window, window)
    head <> "\n…[truncated]…\n" <> tail
  end

  def truncate(text, _window), do: text

  @doc "The default head+tail truncation window, in bytes."
  @spec default_window() :: window()
  def default_window, do: @default_window

  @spec remove_nuls(String.t()) :: String.t()
  defp remove_nuls(text) do
    if String.contains?(text, <<0>>) do
      String.replace(text, <<0>>, "")
    else
      text
    end
  end

  @spec ensure_valid(String.t()) :: String.t()
  defp ensure_valid(text) do
    if String.valid?(text) do
      text
    else
      text |> drop_invalid([]) |> IO.iodata_to_binary()
    end
  end

  @spec drop_invalid(binary(), iodata()) :: iodata()
  defp drop_invalid(<<>>, acc), do: acc

  defp drop_invalid(<<codepoint::utf8, rest::binary>>, acc),
    do: drop_invalid(rest, [acc, <<codepoint::utf8>>])

  defp drop_invalid(<<_byte, rest::binary>>, acc), do: drop_invalid(rest, acc)
end
