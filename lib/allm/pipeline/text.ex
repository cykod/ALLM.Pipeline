defmodule ALLM.Pipeline.Text do
  @moduledoc """
  Batteries-included text handling for pipeline persistence: scrubbing text so
  Postgres will accept it, whitespace normalization, and head+tail truncation
  for oversized artifact bodies.

  ## `scrub/1` / `scrub_strings/1` are the single implementation

  This module is the one home for text scrubbing: a host depends on
  `allm_pipeline` and calls `ALLM.Pipeline.Text.scrub/1` directly rather than
  carrying its own copy, so there is nothing to keep in sync and no code path
  calls back into a host module.
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
