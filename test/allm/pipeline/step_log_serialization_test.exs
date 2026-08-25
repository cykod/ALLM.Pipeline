defmodule ALLM.Pipeline.StepLogSerializationTest.Fixtures do
  @moduledoc """
  Package-owned fixtures for `ALLM.Pipeline.StepLog`'s two-layer serializer.

  Every schema here is defined in the test tree on purpose: a module absent from
  `Application.spec(:allm_pipeline, :modules)` cannot be mistaken for a shipped
  part of the package, and the package tree may not name a host module at all
  (this repo's `CLAUDE.md` §1). The two `AgendaFlagged` / `AgendaLogged`
  schemas are the Phase 2 gate: the SAME field name, divergent flags, which the
  pre-2.2 global-by-field-name drop list made unsayable.
  """

  defmodule AgendaFlagged do
    @moduledoc false
    defmodule Input do
      @moduledoc false
      use ALLM.Pipeline.Schema

      schema do
        field(:label, String.t())
        field(:agenda_items, list(), default: [], log: false)
      end
    end

    @spec step_type() :: atom()
    def step_type, do: :agenda_flagged_fixture

    @spec input_schema() :: module()
    def input_schema, do: Input
  end

  defmodule AgendaLogged do
    @moduledoc false
    defmodule Input do
      @moduledoc false
      use ALLM.Pipeline.Schema

      schema do
        field(:label, String.t())
        field(:agenda_items, list(), default: [])
      end
    end

    @spec step_type() :: atom()
    def step_type, do: :agenda_logged_fixture

    @spec input_schema() :: module()
    def input_schema, do: Input
  end

  defmodule Flags do
    @moduledoc """
    Exercises every flag the serializer reads, plus the fallback interaction.

    `:content` is UNFLAGGED and must still be dropped (layer 2 applies to DSL
    structs too); `:html` carries `log: true` and must survive despite being on
    the fallback list.
    """
    defmodule Input do
      @moduledoc false
      use ALLM.Pipeline.Schema

      schema do
        field(:label, String.t())
        field(:content, String.t())
        field(:html, String.t(), log: true)
        field(:blob, String.t(), artifact: true)
        field(:api_key, String.t(), redact: true)
      end
    end

    @spec step_type() :: atom()
    def step_type, do: :flags_fixture

    @spec input_schema() :: module()
    def input_schema, do: Input
  end

  defmodule Scalars do
    @moduledoc "Serializer-contract coverage: leaves, containers, nesting."
    defmodule Input do
      @moduledoc false
      use ALLM.Pipeline.Schema

      schema do
        field(:payload, term())
      end
    end

    @spec step_type() :: atom()
    def step_type, do: :scalars_fixture

    @spec input_schema() :: module()
    def input_schema, do: Input
  end

  defmodule Plain do
    @moduledoc """
    A NON-DSL struct, nested inside a DSL struct through `:payload`.

    It exports no `__allm_schema__/1`, so it is layer 2's job entirely — the
    case that exists because the serializer recurses into structs the DSL does
    not own.
    """
    defstruct [:name, :raw_html, :content]
    @type t :: %__MODULE__{name: String.t() | nil, raw_html: String.t() | nil, content: term()}
  end
end

defmodule ALLM.Pipeline.StepLogSerializationTest do
  @moduledoc """
  The contract of `ALLM.Pipeline.StepLog`'s two-layer serializer, against
  package-owned fixtures. Discharges the Phase 2 coverage item `.work/HANDOFF.md`
  carried from batch 1.D: the package had **no** test for `StepLog`.

  This file answers *"is the contract right"*. The Amesbury repo's
  `apps/amesbury_scraper/test/amesbury_scraper/pipeline/step_log_test.exs`
  answers *"does it work on Amesbury's real steps"* — a different question, which
  is why that file stayed host-side and must not be folded in here.

  `serialize_struct/2` is private, so every assertion drives it through
  `log_start/4` / `log_success/3` and reads the row back through Postgres. Only a
  reload proves the jsonb write accepted the term.
  """

  use ExUnit.Case, async: true

  alias ALLM.Pipeline.{Config, PipelineRun, StepLog}
  alias ALLM.Pipeline.StepLogSerializationTest.Fixtures

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    {:ok, run} = PipelineRun.create("step_log_serialization_test")
    %{run: run}
  end

  defp log_input(run, step_module, input) do
    {:ok, step_log} = StepLog.log_start(run.id, step_module, input, nil)
    StepLog.get(step_log.id).input_data
  end

  # The same nesting-depth definition `scripts/steplog_depth.py` uses, so the
  # implementation's convention is pinned against the instrument that sized the
  # budget rather than against a restatement of it. The script walks a stack of
  # `{node, level}` with the root at level 1 and takes the maximum level reached,
  # counting SCALARS as nodes — so a flat map of scalars is depth 2, and an empty
  # container is depth 1.
  defp depth(value) when is_map(value) or is_list(value), do: max_level(value, 1)
  defp depth(_scalar), do: 0

  defp max_level(value, level) when is_map(value) or is_list(value) do
    children = if is_map(value), do: Map.values(value), else: value
    Enum.reduce(children, level, fn child, acc -> max(acc, max_level(child, level + 1)) end)
  end

  defp max_level(_scalar, level), do: level

  # `nest(0)` is a scalar; `nest(k)` placed in a field of the serialized struct
  # puts its leaf at level 2 + k, so the row's depth is 2 + k.
  defp nest(0), do: "leaf"
  defp nest(n), do: %{"n" => nest(n - 1)}

  describe "the :agenda_items capability gate (Phase 2 gate, D5)" do
    # Both directions in ONE test. A single-direction assertion passes under the
    # pre-2.2 global-by-field-name design as easily as under this one; only the
    # pair is impossible to satisfy with a global list, because the list would
    # have to both contain and not contain `:agenda_items`.
    test "one struct drops :agenda_items while another persists it", %{run: run} do
      items = [%{"number" => "1", "title" => "87 S Hampton Rd site plan"}]

      flagged =
        log_input(
          run,
          Fixtures.AgendaFlagged,
          %Fixtures.AgendaFlagged.Input{label: "flagged", agenda_items: items}
        )

      logged =
        log_input(
          run,
          Fixtures.AgendaLogged,
          %Fixtures.AgendaLogged.Input{label: "logged", agenda_items: items}
        )

      refute Map.has_key?(flagged, "agenda_items")
      assert flagged["label"] == "flagged"

      assert logged["agenda_items"] == items
      assert logged["label"] == "logged"
    end
  end

  describe "layer 1 — per-field flags" do
    test "an UNFLAGGED field named :content is still dropped", %{run: run} do
      # The regression an "flags REPLACE the fallback" implementation causes, and
      # nothing else in this file catches it: a DSL struct consulting only its
      # own flags would start persisting every unflagged `:content` body the day
      # the flags shipped.
      input = %Fixtures.Flags.Input{label: "l", content: String.duplicate("body ", 5_000)}

      refute Map.has_key?(log_input(run, Fixtures.Flags, input), "content")
    end

    test "log: true keeps a field whose name is on the fallback list", %{run: run} do
      input = %Fixtures.Flags.Input{label: "l", html: "<p>kept on purpose</p>"}

      assert log_input(run, Fixtures.Flags, input)["html"] == "<p>kept on purpose</p>"
    end

    test "artifact: true drops the field, and :artifact reports it", %{run: run} do
      input = %Fixtures.Flags.Input{label: "l", blob: "the artifact body"}

      refute Map.has_key?(log_input(run, Fixtures.Flags, input), "blob")
      assert Fixtures.Flags.Input.__allm_schema__(:artifact) == [:blob]
      assert :blob in Fixtures.Flags.Input.__allm_schema__(:dropped)
    end

    test "redact: true persists the marker and the value appears nowhere in the row",
         %{run: run} do
      secret = "sk-live-9d41f0c2-do-not-persist"
      input = %Fixtures.Flags.Input{label: "l", api_key: secret}

      input_data = log_input(run, Fixtures.Flags, input)

      assert input_data["api_key"] == "[REDACTED]"
      # Asserted on the ENCODED row, not just the key: a nested copy anywhere in
      # the term would survive a `Map.get` assertion.
      refute Jason.encode!(input_data) =~ secret
    end

    test "all four flags resolve on a DSL struct NESTED inside another DSL struct",
         %{run: run} do
      # Every other flag assertion in this file drives `Fixtures.Flags.Input` as
      # the TOP-LEVEL struct, and every nesting test nests a NON-DSL struct. So
      # an implementation that resolved `{drop, redact}` once for the outer
      # module and threaded it down the recursion — instead of re-resolving per
      # module in `serialize_struct/2` — passes the whole file. For `log: false`
      # that costs a bloated row; for `redact:` it persists the credential
      # verbatim, which is the one failure mode D3 exists to prevent.
      secret = "sk-live-nested-do-not-persist"

      nested = %Fixtures.Flags.Input{
        label: "nested",
        content: String.duplicate("body ", 5_000),
        html: "<p>kept on purpose</p>",
        blob: "the artifact body",
        api_key: secret
      }

      input = %Fixtures.Scalars.Input{payload: %{"inner" => nested}}

      input_data = log_input(run, Fixtures.Scalars, input)
      inner = input_data["payload"]["inner"]

      # `Fixtures.Scalars.Input` declares NO flags, so every one of these can
      # only come from the nested module's own `__allm_schema__/1`.
      assert inner["label"] == "nested"
      assert inner["api_key"] == "[REDACTED]"
      assert inner["html"] == "<p>kept on purpose</p>"
      refute Map.has_key?(inner, "content")
      refute Map.has_key?(inner, "blob")
      refute Jason.encode!(input_data) =~ secret
    end
  end

  describe "layer 2 — the package fallback list" do
    test "@fallback_drop is exactly [:raw_html, :html, :content, :engine]" do
      # A membership guard on the LITERAL, not only on behaviour: a behavioural
      # test can only ever cover the names it enumerates, so it cannot see a
      # FIFTH name being added. Same shape as `encodable_test.exs`'s "there is
      # exactly ONE implementation" — including its floor, because a guard whose
      # success signal is "found nothing" fails open when the path moves.
      source_path =
        Path.join([__DIR__, "..", "..", "..", "lib", "allm", "pipeline", "step_log.ex"])

      source = File.read!(source_path)
      assert byte_size(source) > 5_000, "step_log.ex moved or shrank — re-point this guard"

      [[_, names]] = Regex.scan(~r/@fallback_drop \[([^\]]+)\]/, source)

      parsed =
        names
        |> String.split(",")
        |> Enum.map(&(&1 |> String.trim() |> String.trim_leading(":") |> String.to_atom()))

      assert parsed == [:raw_html, :html, :content, :engine]
    end

    test "a plain defstruct nested in a DSL struct still has :raw_html dropped", %{run: run} do
      nested = %Fixtures.Plain{name: "n", raw_html: "<html>heavy</html>", content: "heavy body"}
      input = %Fixtures.Scalars.Input{payload: [nested]}

      [serialized] = log_input(run, Fixtures.Scalars, input)["payload"]

      assert serialized["name"] == "n"
      refute Map.has_key?(serialized, "raw_html")
      refute Map.has_key?(serialized, "content")
    end

    test "a live Ecto struct nested in a DSL struct serializes and does NOT raise",
         %{run: run} do
      # The discriminator for the whole two-layer design. `%PipelineRun{}` is a
      # real Ecto schema: it exports `__schema__/1`, `__schema__(:fields)`
      # SUCCEEDS with a colliding shape, and `__schema__(:dropped)` raises
      # `FunctionClauseError`. An implementation keying the DSL predicate on
      # `function_exported?(m, :__schema__, 1)` passes every other test in this
      # file and dies here — inside `log_start/4`, which is the un-rescued
      # pre-`execute_step` path.
      assert function_exported?(PipelineRun, :__schema__, 1)
      assert is_list(PipelineRun.__schema__(:fields))
      assert_raise FunctionClauseError, fn -> PipelineRun.__schema__(:dropped) end
      refute function_exported?(PipelineRun, :__allm_schema__, 1)

      # Re-loaded from Postgres, so it carries a real `%Ecto.Schema.Metadata{}`
      # and a `%NotLoaded{}` association — the production shape, not a bare
      # `%PipelineRun{}` literal.
      input = %Fixtures.Scalars.Input{payload: PipelineRun.get(run.id)}

      serialized = log_input(run, Fixtures.Scalars, input)["payload"]

      assert serialized["name"] == "step_log_serialization_test"
      assert serialized["__meta__"]["source"] == "pipeline_runs"
    end
  end

  describe "the depth budget (D4)" do
    test "a term nested to the measured real-world maximum of 8 is untouched", %{run: run} do
      payload = nest(6)
      input = %Fixtures.Scalars.Input{payload: payload}

      input_data = log_input(run, Fixtures.Scalars, input)

      # Under `steplog_depth.py`'s convention the row is depth 8 — the deepest
      # thing production has ever produced (n=43,571 rows, both columns).
      assert depth(input_data) == 8
      assert input_data["payload"] == payload
      refute Jason.encode!(input_data) =~ "truncated"
    end

    test "a term nested 20 levels deep truncates at the budget and does not raise",
         %{run: run} do
      input = %Fixtures.Scalars.Input{payload: nest(18)}

      input_data = log_input(run, Fixtures.Scalars, input)

      assert depth(input_data) == 16
      assert Jason.encode!(input_data) =~ "[truncated: max depth 16]"
    end

    test "the budget is spent by containers, not by scalars", %{run: run} do
      # A scalar sitting AT the limit is kept — it adds no level. The
      # discriminator against a budget that truncates by position rather than by
      # what the value costs, which would replace this string with the marker.
      input = %Fixtures.Scalars.Input{payload: nest(14)}

      input_data = log_input(run, Fixtures.Scalars, input)

      assert depth(input_data) == 16
      refute Jason.encode!(input_data) =~ "truncated"
    end
  end

  describe "the serializer contract's leaves" do
    test "Calendar structs render to ISO-8601", %{run: run} do
      payload = %{
        "dt" => ~U[2026-08-14 12:30:00.000000Z],
        "ndt" => ~N[2026-08-14 12:30:00],
        "d" => ~D[2026-08-14],
        "t" => ~T[12:30:00]
      }

      input_data = log_input(run, Fixtures.Scalars, %Fixtures.Scalars.Input{payload: payload})

      assert input_data["payload"]["dt"] == "2026-08-14T12:30:00.000000Z"
      assert input_data["payload"]["ndt"] == "2026-08-14T12:30:00"
      assert input_data["payload"]["d"] == "2026-08-14"
      assert input_data["payload"]["t"] == "12:30:00"
    end

    test "a Decimal renders as a float, not as a struct map", %{run: run} do
      # 2.2 converged this leaf onto `Encodable.encode/1`. Before that,
      # `maybe_serialize/1` fell through to the struct clause and persisted
      # `%{"coef" => 15, "exp" => -1, "sign" => 1}` — arithmetically opaque and
      # not comparable to a number in the review UI.
      input = %Fixtures.Scalars.Input{payload: %{"amount" => Decimal.new("1.5")}}

      assert log_input(run, Fixtures.Scalars, input)["payload"]["amount"] == 1.5
    end

    test "binaries are scrubbed of NUL bytes and invalid UTF-8", %{run: run} do
      # Without this the jsonb write fails with `ERROR 22P05
      # (untranslatable_character)` and the whole meeting is lost. The row
      # reloading at all is half the assertion.
      payload = %{"nul" => "before" <> <<0>> <> "after", "bad" => <<"ok", 0xFF>>}

      input_data = log_input(run, Fixtures.Scalars, %Fixtures.Scalars.Input{payload: payload})

      assert input_data["payload"]["nul"] == "beforeafter"
      refute input_data["payload"]["nul"] =~ <<0>>
      assert String.valid?(input_data["payload"]["bad"])
    end

    test "a tuple flattens to a list rather than crashing the write", %{run: run} do
      # `maybe_serialize/1` had NO tuple clause before 2.2, so a tuple reached
      # the changeset and `Jason` raised `Protocol.UndefinedError` on the
      # un-rescued `log_start/4` path. The rule matches `Encodable`'s; the
      # recursion is this module's, so the drop set still applies inside.
      nested = %Fixtures.Plain{name: "n", raw_html: "<html>heavy</html>"}
      input = %Fixtures.Scalars.Input{payload: %{"pair" => {:meeting_1, "boom", nested}}}

      [tag, reason, struct_map] = log_input(run, Fixtures.Scalars, input)["payload"]["pair"]

      assert tag == "meeting_1"
      assert reason == "boom"
      assert struct_map["name"] == "n"
      refute Map.has_key?(struct_map, "raw_html")
    end

    test "every Encodable struct rule is delegated here, except the declared exception" do
      # 2.2's leaf convergence created a HAND-MIRRORED SET: `maybe_serialize/2`
      # enumerates the struct modules it delegates, and `Encodable.encode/1`
      # enumerates the struct modules it special-cases. Nothing links them, so a
      # SIXTH rule landing on `Encodable` alone falls through `StepLog`'s
      # `is_struct` clause to a struct-map — which is exactly the `Decimal`
      # divergence 2.2 repaired, silently recurring. Root `CLAUDE.md`'s "A rule
      # enforced in more than one shape needs a MEMBERSHIP guard" applies, and
      # this is a source scan for the same reason `@fallback_drop`'s is: a
      # behavioural test can only cover the modules it already knows about.
      #
      # Same floor idiom as that guard — a guard whose success signal is "found
      # nothing" fails open when a file moves or shrinks.
      lib = Path.join([__DIR__, "..", "..", "..", "lib", "allm", "pipeline"])

      encodable_source = File.read!(Path.join(lib, "encodable.ex"))
      step_log_source = File.read!(Path.join(lib, "step_log.ex"))

      assert byte_size(encodable_source) > 3_000, "encodable.ex moved or shrank — re-point this"
      assert byte_size(step_log_source) > 5_000, "step_log.ex moved or shrank — re-point this"

      encodable_structs = scan_struct_heads(encodable_source, ~r/def encode\(%([\w.]+)\{/)

      # Anchored on the DELEGATION, not merely on a struct head: a future
      # `maybe_serialize/2` clause that matches a struct and does something
      # else is not a converged leaf and must not count as one.
      delegated =
        scan_struct_heads(
          step_log_source,
          ~r/defp maybe_serialize\(%([\w.]+)\{[^\n]*Encodable\.encode/
        )

      assert length(encodable_structs) > 3, "the Encodable scan found nothing — re-point it"
      assert length(delegated) > 3, "the delegation scan found nothing — re-point it"

      # THE declared divergence, and the only one. `Encodable` renders a
      # changeset as `%{"changeset_errors" => …}`; `StepLog` flattens it as an
      # ordinary struct. Recorded as decision 3 in
      # `steering/2026-08-10_ALLM_PIPELINE_PHASE_2_RECORDS.md` → "Batch 2.2":
      # no DSL field declares a changeset type, so nothing drives the rule.
      # Delete this line only by converging the clause, never to make a red go
      # away.
      assert encodable_structs -- delegated == [Ecto.Changeset]

      # The other direction: a leaf rule `StepLog` states and `Encodable` does
      # not is the same mirror running backwards.
      assert delegated -- encodable_structs == []
    end
  end

  defp scan_struct_heads(source, regex) do
    regex
    |> Regex.scan(source)
    |> Enum.map(fn [_, mod] -> Module.concat([mod]) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  describe "log_success/3 serializes the Output through the same path" do
    test "flags apply to output_data, not only input_data", %{run: run} do
      {:ok, step_log} =
        StepLog.log_start(
          run.id,
          Fixtures.Flags,
          %Fixtures.Flags.Input{label: "in"},
          nil
        )

      output = %Fixtures.Flags.Input{
        label: "out",
        content: "heavy",
        api_key: "sk-live-output-secret",
        blob: "artifact body"
      }

      {:ok, _} = StepLog.log_success(step_log, output)
      output_data = StepLog.get(step_log.id).output_data

      assert output_data["label"] == "out"
      assert output_data["api_key"] == "[REDACTED]"
      refute Map.has_key?(output_data, "content")
      refute Map.has_key?(output_data, "blob")
      refute Jason.encode!(output_data) =~ "sk-live-output-secret"
    end
  end
end
