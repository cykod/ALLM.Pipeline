defmodule ALLM.Pipeline.TextTest do
  use ExUnit.Case, async: true

  doctest ALLM.Pipeline.Text

  alias ALLM.Pipeline.Text

  # The `scrub/1` and `scrub_strings/1` cases below deliberately mirror
  # `apps/amesbury/test/amesbury/text_sanitizer_test.exs`. The two modules are a
  # hand-maintained duplicate pair (see `ALLM.Pipeline.Text`'s moduledoc), and
  # nothing machine-checks that they agree — so each side carries its own
  # coverage rather than one side testing "the" implementation. Phase 7 collapses
  # both the modules and these two test files.

  describe "scrub/1" do
    test "passes nil through" do
      assert Text.scrub(nil) == nil
    end

    test "leaves clean text untouched" do
      text = "Planning Board Agenda — April 23, 2026"
      assert Text.scrub(text) == text
    end

    test "returns the same binary for clean text (no reallocation)" do
      text = "no problems here"
      assert Text.scrub(text) === text
    end

    test "removes NUL bytes (the U+0000 that triggers PG 22P05)" do
      assert Text.scrub("a\0b\0c") == "abc"
    end

    test "removes a NUL embedded mid-word without disturbing surrounding text" do
      assert Text.scrub("Item \0 1. Roll call") == "Item  1. Roll call"
    end

    test "preserves valid multibyte UTF-8 (accents, em dash, emoji)" do
      text = "café — naïve — 🏛️"
      assert Text.scrub(text) == text
    end

    test "drops invalid UTF-8 bytes while keeping valid codepoints around them" do
      # 0xFF is never valid in UTF-8
      assert Text.scrub(<<"good ", 0xFF, "text">>) == "good text"
    end

    test "drops a truncated multibyte sequence" do
      # 0xE2 0x82 starts a 3-byte sequence (€ is E2 82 AC) but is cut short
      assert Text.scrub(<<"price ", 0xE2, 0x82, " each">>) == "price  each"
    end

    test "handles combined NUL bytes and invalid UTF-8" do
      result = Text.scrub(<<"a", 0, "b", 0xFF, "c">>)
      assert result == "abc"
      assert String.valid?(result)
    end

    test "output is always valid and NUL-free" do
      messy = <<"Meeting \0 minutes ", 0xC0, 0x80, " 7:00 PM ", 0xFF>>
      result = Text.scrub(messy)
      assert String.valid?(result)
      refute String.contains?(result, <<0>>)
    end
  end

  describe "scrub_strings/1" do
    test "scrubs every binary value in the map" do
      attrs = %{
        title: <<"Roll", 0, " call">>,
        description: <<"notes ", 0xFF>>,
        category: "Old Business"
      }

      assert Text.scrub_strings(attrs) == %{
               title: "Roll call",
               description: "notes ",
               category: "Old Business"
             }
    end

    test "leaves non-binary values untouched" do
      attrs = %{title: <<"a", 0, "b">>, position: 3, project_id: nil, flagged?: true}

      assert Text.scrub_strings(attrs) == %{
               title: "ab",
               position: 3,
               project_id: nil,
               flagged?: true
             }
    end

    test "preserves string keys" do
      assert Text.scrub_strings(%{"title" => <<"x", 0>>}) == %{"title" => "x"}
    end
  end

  describe "normalize/1" do
    test "collapses whitespace runs and trims" do
      assert Text.normalize("  Board   Meeting\n ") == "Board Meeting"
    end

    test "collapses newlines and tabs, not just spaces" do
      assert Text.normalize("Special\tPermit\n\nHearing") == "Special Permit Hearing"
    end

    test "leaves already-normal text untouched" do
      assert Text.normalize("City Council") == "City Council"
    end

    test "reduces an all-whitespace string to empty" do
      assert Text.normalize("  \n\t ") == ""
    end
  end

  describe "truncate/2" do
    test "passes nil through" do
      assert Text.truncate(nil, 10) == nil
    end

    test "leaves text at or under 2 * window untouched" do
      # exactly at the boundary — the guard is strictly greater-than
      text = String.duplicate("a", 20)
      assert Text.truncate(text, 10) === text
    end

    test "keeps the head AND the tail, eliding the middle" do
      assert Text.truncate("abcdefghij", 2) == "ab\n…[truncated]…\nij"
    end

    test "the result is shorter than the input for a large body" do
      text = String.duplicate("x", 100_000)
      result = Text.truncate(text, 4_000)

      assert byte_size(result) < byte_size(text)
      assert String.starts_with?(result, String.duplicate("x", 4_000))
      assert result =~ "…[truncated]…"
    end

    test "defaults to the module's declared window" do
      window = Text.default_window()
      text = String.duplicate("y", 2 * window + 1)

      assert Text.truncate(text) == Text.truncate(text, window)
      assert Text.truncate(text) =~ "…[truncated]…"
    end

    test "default_window is a positive integer" do
      assert is_integer(Text.default_window())
      assert Text.default_window() > 0
    end
  end
end
