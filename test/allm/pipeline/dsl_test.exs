defmodule ALLM.Pipeline.DslTest do
  @moduledoc """
  Pins the COMPILE-TIME half of `use ALLM.Pipeline`: what the construct macros
  accept, what they reject, and what `__pipeline__/1` reports.

  The runtime half — lineage, fan-out, the accumulator, the terminal write —
  is `dsl/runtime_test.exs`, which is DB-backed. Nothing here touches the
  database.
  """

  use ExUnit.Case, async: true

  alias ALLM.Pipeline.Dsl
  alias ALLM.Pipeline.Dsl.Stage
  alias ALLM.Pipeline.TestSupport.TargetDeclaration

  # Each rejection test compiles a throwaway module, so every one needs a name
  # nothing else in the VM has used — a redefinition would emit a warning and,
  # worse, make a second run of the same test observe the FIRST module.
  defp unique_module, do: "ALLMPipelineDslRejection#{System.unique_integer([:positive])}"

  defp compile!(body) do
    Code.eval_string("defmodule #{unique_module()} do\n#{body}\nend")
  end

  describe "the target declaration (4.1's acceptance spec)" do
    test "compiles and reports its three stages, in declaration order" do
      assert Enum.map(TargetDeclaration.__pipeline__(:stages), & &1.name) ==
               [:committee_cache, :list, :meeting]
    end

    test "reports its stages as Dsl.Stage structs, not bare atoms" do
      for stage <- TargetDeclaration.__pipeline__(:stages) do
        assert %Stage{} = stage
      end
    end

    test "carries the run-name string, not a cron atom" do
      assert TargetDeclaration.__pipeline__(:name) == "meeting_agenda_scrape"
      assert TargetDeclaration.__pipeline__(:concurrency) == 1
    end

    test "the fan_out declares the flat tree over a Step target" do
      meeting = Enum.find(TargetDeclaration.__pipeline__(:stages), &(&1.name == :meeting))

      assert meeting.kind == :fan_out
      assert meeting.parent == :source_stage
      assert meeting.step == TargetDeclaration.MeetingListScraper
      assert is_function(meeting.over, 1)
      assert is_function(meeting.input, 2)
      # `section:`/`delay:`/`body:`-mode fan_out were removed in Phase 4.5.2;
      # `gate:` in 4.5.3 (the `:gate` field is gone from `%Stage{}`).
    end

    test "every hook resolved to a PRIVATE function of the declaring module" do
      # The whole point of the atom form (D6). If these had been captured as
      # remote calls, `TargetDeclaration.funnel/1` would have to be public.
      refute function_exported?(TargetDeclaration, :funnel, 1)
      refute function_exported?(TargetDeclaration, :process_single_meeting, 2)

      assert is_function(TargetDeclaration.__pipeline__(:metrics).from, 1)
      assert is_function(TargetDeclaration.__pipeline__(:hooks).summarize, 2)
      assert is_function(TargetDeclaration.__pipeline__(:hooks).init, 0)
    end

    test "metrics carries the entity type it will write to pipeline_metrics" do
      assert TargetDeclaration.__pipeline__(:metrics).entity_type == "meetings"
    end
  end

  describe "construct set guards" do
    # (a) The macro set. A construct added to the DSL without being exported —
    # or one silently dropped — fails HERE, by name.
    test "Dsl exports exactly the construct macros, and the reflection is non-empty" do
      macros = Enum.sort(Dsl.__info__(:macros))

      # FLOOR FIRST: an empty or truncated reflection would otherwise satisfy
      # any `==` against a list built from the same broken source. Same
      # fail-open protection `executor_test.exs` and `encodable_test.exs` put
      # on their `Path.wildcard/1` results, transposed to the right instrument.
      assert length(macros) >= 9,
             "ALLM.Pipeline.Dsl exports only #{length(macros)} macros — the module moved or " <>
               "the constructs were renamed, and this guard is no longer scanning them."

      assert macros == [
               child_pipeline: 3,
               child_pipeline: 4,
               fan_out: 2,
               fan_out: 3,
               metrics: 2,
               resource: 2,
               stage: 2,
               stage: 3,
               summarize: 1
             ]
    end

    # (b) Only the stage-producing macros reach `__pipeline__(:stages)`.
    test "metrics and summarize are NOT stages" do
      names = Enum.map(TargetDeclaration.__pipeline__(:stages), & &1.name)

      assert length(names) >= 3,
             "the fixture reports #{length(names)} stages — it stopped declaring them, and " <>
               "the exclusions below would pass vacuously."

      refute :metrics in names
      refute :summarize in names
      refute :meetings in names
    end

    # (c) The hook-arity vocabulary. `@hook_arities` is the SINGLE source: it is
    # what an atom hook's capture is built at AND what
    # `__assert_hooks_defined__!/2` checks the module defines, and the moduledoc
    # cites it rather than restating a column of arities. A hook added to the DSL
    # without a row here cannot be declared as an atom at all; a row silently
    # dropped or re-arity'd produces `"names foo/2, which this module does not
    # define"` against a correctly-written hook — an error blaming the wrong side.
    test "every hook option has exactly one declared arity, and the table is non-empty" do
      arities = Dsl.__hook_arities__()

      assert length(arities) >= 13,
             "__hook_arities__/0 reports only #{length(arities)} hooks — rows were dropped, " <>
               "and the equality below would pass vacuously."

      # `gate: 2` was removed in Phase 4.5.3 (`section: 1` / `when: 1` in 4.5.2).
      assert Enum.sort(arities) ==
               Enum.sort(
                 metadata: 1,
                 complete_metadata: 1,
                 init: 0,
                 input: 2,
                 over: 1,
                 body: 2,
                 skip_when: 1,
                 from: 1,
                 summarize: 2,
                 start: 1,
                 stop: 1,
                 args: 2,
                 dry_run: 1
               )

      assert Keyword.keys(arities) == Enum.uniq(Keyword.keys(arities))
    end

    # (d) The `use` option vocabulary — the THIRD mirrored vocabulary, and the
    # one that was still eye-checked after (a) and (c) got guards (code review
    # 4.3 F8). `@use_options` is what `use ALLM.Pipeline` accepts; the
    # `## `use` options` table in `ALLM.Pipeline`'s moduledoc is what a reader
    # is told it accepts. An option added to one and not the other is either an
    # undocumented feature or a documented one that raises `ArgumentError`.
    test "every `use` option has a moduledoc table row, and the table is non-empty" do
      options = Dsl.__use_options__()

      assert length(options) >= 9,
             "__use_options__/0 reports only #{length(options)} options — the attribute was " <>
               "truncated, and the row check below would pass vacuously."

      # Scoped to THIS ONE TABLE, not the whole moduledoc and not every table in
      # it. Two ways a looser scope fails open, both measured: `returns:`,
      # `concurrency:` and `dry_run:` are discussed in prose sections further
      # down, so a whole-doc `=~` reports a row for an option that has none; and
      # the `--dry-run` semantics table 200 lines below carries `dry_run:` in
      # four of its own rows, so filtering the whole moduledoc for lines
      # starting `|` let a deleted `use`-options row survive (verified by
      # mutation: that mutant lived until this scoping landed).
      rows =
        ALLM.Pipeline
        |> Code.fetch_docs()
        |> then(fn {:docs_v1, _, _, _, %{"en" => doc}, _, _} -> doc end)
        |> String.split("\n")
        |> Enum.drop_while(&(String.trim(&1) != "## `use` options"))
        |> Enum.drop(1)
        |> Enum.take_while(&(not String.starts_with?(String.trim_leading(&1), "## ")))
        |> Enum.filter(&String.starts_with?(String.trim_leading(&1), "|"))

      # POSITIVE CONTROL: the section AND its table were found. Floor sits at
      # header + separator + one row, WELL below the live count — not at
      # `length(options) + 2`, which would trip first when a row is deleted and
      # report "the guard stopped reading the table" instead of naming the
      # option that lost its row (the diagnosis-ordering trap `fan_out_test.exs`
      # documents at its own `>= 4`; verified by mutation, which reached the
      # wrong assertion until this floor came down).
      assert length(rows) >= 3,
             "found only #{length(rows)} rows in ALLM.Pipeline's `## `use` options` table — " <>
               "the heading was renamed or the table moved, and this guard is no longer " <>
               "reading it."

      table = Enum.join(rows, "\n")

      missing = Enum.reject(options, &(table =~ "`#{&1}:`"))

      assert missing == [],
             "these `use` options have no row in ALLM.Pipeline's `## `use` options` table: " <>
               "#{inspect(missing)}. Add the row — the table is the only place a caller " <>
               "learns the option exists."
    end
  end

  describe "stage/3's two forms are told apart by AST SHAPE" do
    test "an alias is the Step form, never a hook" do
      # The trap: an alias IS an atom once expanded, so an implementation
      # matching `is_atom/1` treats every Step module as a body.
      {{:module, mod, _, _}, _} =
        compile!("""
          use ALLM.Pipeline, name: "shape"
          stage :s, ALLM.Pipeline.TestSupport.TargetDeclaration.MeetingListScraper,
            input: :build_input
          defp build_input(_ctx, _prev), do: %{}
        """)

      [stage] = mod.__pipeline__(:stages)

      assert stage.step == ALLM.Pipeline.TestSupport.TargetDeclaration.MeetingListScraper
      assert is_nil(stage.body)
    end

    test "anything else is the escape hatch, at arity 2" do
      {{:module, mod, _, _}, _} =
        compile!("""
          use ALLM.Pipeline, name: "shape"
          stage :inline, fn _ctx, _prev -> {:ok, :done} end
          stage :named, :do_work
          defp do_work(_ctx, _prev), do: {:ok, :done}
        """)

      for stage <- mod.__pipeline__(:stages) do
        assert is_nil(stage.step)
        assert is_function(stage.body, 2)
      end
    end
  end

  describe "`concurrency: {:opt, key, default}`" do
    # This whole form was a COMPILE ERROR until Phase 4.4 — on the `use` line and
    # on a `fan_out` alike — and no consumer had ever declared it, so nothing
    # noticed. `validate_concurrency!/3` returned the real 3-element tuple, which
    # is not a valid AST node, and BOTH splice sites put it straight back inside
    # a `quote`: `__stage_ast__/1`'s `{:%{}, [], fields}` and
    # `ALLM.Pipeline.__before_compile__/1`'s `def __pipeline__(:concurrency)`.
    # The failure was `** (CompileError) invalid quoted expression:
    # {:opt, :concurrency, 2}` at the USING module, naming neither.
    #
    # Discriminator: this test compiles a module declaring the form at BOTH
    # levels. A fix applied to only one splice site leaves the other a compile
    # error, so the module never loads and this fails at `compile!/1`.
    test "compiles at both levels and reaches `__pipeline__/1` as a real tuple" do
      {{:module, module, _bin, _exports}, _bindings} =
        compile!("""
        use ALLM.Pipeline, name: "x", concurrency: {:opt, :concurrency, 2}
        fan_out :f, ALLM.Pipeline.TestSupport.TargetDeclaration.MeetingListScraper,
          over: :items, input: :inp, concurrency: {:opt, :llm_concurrency, 1}
        defp items(_), do: []
        defp inp(_, _), do: %{}
        """)

      assert module.__pipeline__(:concurrency) == {:opt, :concurrency, 2}

      assert Enum.map(module.__pipeline__(:stages), &{&1.name, &1.concurrency}) ==
               [{:f, {:opt, :llm_concurrency, 1}}]
    end

    test "a non-positive default is still rejected at compile time" do
      assert_raise ArgumentError, ~r/`concurrency:` must be a positive integer or/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x", concurrency: {:opt, :concurrency, 0}\nstage :s, fn _, _ -> {:ok, 1} end|
        )
      end
    end
  end

  describe "compile-time rejections" do
    test "an unknown `use` option" do
      assert_raise ArgumentError, ~r/unknown `use ALLM.Pipeline` option\(s\) \[:registry\]/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x", registry: Some.Registry\nstage :s, fn _, _ -> {:ok, 1} end|
        )
      end
    end

    test "a missing `name:`" do
      assert_raise ArgumentError, ~r/requires `name:`/, fn ->
        compile!("use ALLM.Pipeline\nstage :s, fn _, _ -> {:ok, 1} end")
      end
    end

    test "a `name:` that is a cron atom rather than the run-name string" do
      assert_raise ArgumentError, ~r/`name:` must be a non-empty string literal/, fn ->
        compile!("use ALLM.Pipeline, name: :committee\nstage :s, fn _, _ -> {:ok, 1} end")
      end
    end

    test "`concurrency: 0`" do
      assert_raise ArgumentError, ~r/`concurrency:` must be a positive integer, got: 0/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x", concurrency: 0\nstage :s, fn _, _ -> {:ok, 1} end|
        )
      end
    end

    test "a fan_out with no Step module (the removed body-mode form)" do
      assert_raise ArgumentError, ~r/a `fan_out` requires a Step-module target/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x"\nfan_out :f, over: :items\ndefp items(_), do: []|
        )
      end
    end

    test "a fan_out with no `over:`" do
      assert_raise ArgumentError, ~r/requires `over:`/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x"\nfan_out :f, ALLM.Pipeline.TestSupport.TargetDeclaration.MeetingListScraper, input: :inp\ndefp inp(_, _), do: %{}|
        )
      end
    end

    test "a hook atom naming a function the module does not define" do
      assert_raise ArgumentError,
                   ~r/`body: :nowhere` names nowhere\/2, which this module does not define/,
                   fn ->
                     compile!(~s|use ALLM.Pipeline, name: "x"\nstage :s, :nowhere|)
                   end
    end

    test "a `use`-level hook atom naming a function the module does not define" do
      assert_raise ArgumentError, ~r/`init: :missing` names missing\/0/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x", init: :missing\nstage :s, fn _, _ -> {:ok, 1} end|
        )
      end
    end

    test "a Step-form stage with no `input:`" do
      assert_raise ArgumentError, ~r/requires `input:`/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x"\nstage :s, ALLM.Pipeline.TestSupport.TargetDeclaration.MeetingListScraper|
        )
      end
    end

    test "duplicate stage names" do
      assert_raise ArgumentError, ~r/duplicate stage name\(s\) \[:s\]/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x"\nstage :s, fn _, _ -> {:ok, 1} end\nstage :s, fn _, _ -> {:ok, 2} end|
        )
      end
    end

    test "a pipeline declaring no stage at all" do
      assert_raise ArgumentError, ~r/must declare at least one `stage` or `fan_out`/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"|)
      end
    end

    test "a stage handed a keyword list where a module or body belongs" do
      assert_raise ArgumentError,
                   ~r/was given a keyword list where a Step module or a body was expected/,
                   fn ->
                     compile!(
                       ~s|use ALLM.Pipeline, name: "x"\nstage :s, input: :i\ndefp i(_, _), do: %{}|
                     )
                   end
    end

    test "an unknown stage option" do
      assert_raise ArgumentError, ~r/unknown `stage :s` option\(s\) \[:retries\]/, fn ->
        compile!(~s|use ALLM.Pipeline, name: "x"\nstage :s, fn _, _ -> {:ok, 1} end, retries: 3|)
      end
    end

    test "`parent:` on a fan_out must be one of the two modes" do
      assert_raise ArgumentError, ~r/`parent:` must be `:source_stage` or `:per_item`/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x"\nfan_out :f, ALLM.Pipeline.TestSupport.TargetDeclaration.MeetingListScraper, over: :i, input: :inp, parent: :chained\ndefp i(_), do: []\ndefp inp(_, _), do: %{}|
        )
      end
    end

    test "`on_error:` on a fan_out, which cannot fail as a stage" do
      assert_raise ArgumentError,
                   ~r/does not apply to a `fan_out`.*catch_item_failures: true/s,
                   fn ->
                     compile!(
                       ~s|use ALLM.Pipeline, name: "x"\nfan_out :f, ALLM.Pipeline.TestSupport.TargetDeclaration.MeetingListScraper, over: :i, input: :inp, on_error: :continue\ndefp i(_), do: []\ndefp inp(_, _), do: %{}|
                     )
                   end
    end

    test "`on_error:` on a plain stage is still accepted" do
      assert {_, _} =
               compile!(
                 ~s|use ALLM.Pipeline, name: "x"\nstage :s, fn _, _ -> {:ok, 1} end, on_error: :continue|
               )
    end

    # Phase 4.5.3 removed `gate:` from `@fan_out_options` and `@hook_arities`, so
    # it falls to the generic unknown-option gate. Rejects the option surviving.
    test "`gate:` on a fan_out is an unknown option" do
      assert_raise ArgumentError, ~r/unknown `fan_out :f` option\(s\) \[:gate\]/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x"\nfan_out :f, ALLM.Pipeline.TestSupport.TargetDeclaration.MeetingListScraper, over: :i, input: :inp, gate: :g\ndefp i(_), do: []\ndefp inp(_, _), do: %{}\ndefp g(_, _), do: true|
        )
      end
    end

    # Phase 4.5.3: `carry:` is off `@fan_out_options`, and a targeted message
    # names the item-chain alternative rather than a bare "unknown option".
    # Rejects silently accepting it (the trap it used to be).
    test "`carry:` on a fan_out is a compile error naming the item-chain alternative" do
      assert_raise ArgumentError, ~r/not available on a `fan_out`.*ok_items\/1/s, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x"\nfan_out :f, ALLM.Pipeline.TestSupport.TargetDeclaration.MeetingListScraper, over: :i, input: :inp, carry: [:token]\ndefp i(_), do: []\ndefp inp(_, _), do: %{}|
        )
      end
    end

    # `carry:` remains valid on a `stage` (the surviving form).
    test "`carry:` on a plain stage is still accepted" do
      assert {_, _} =
               compile!(
                 ~s|use ALLM.Pipeline, name: "x"\nstage :s, fn _, _ -> {:ok, 1} end, carry: [:token]|
               )
    end

    test "`metrics` without `from:`" do
      assert_raise ArgumentError, ~r/requires `from:`/, fn ->
        compile!(
          ~s|use ALLM.Pipeline, name: "x"\nstage :s, fn _, _ -> {:ok, 1} end\nmetrics "things", alert_on_empty: true|
        )
      end
    end
  end

  describe "no third completion-token mint point" do
    test "the DSL tree never mints one" do
      # Criterion 5's in-suite half. `PipelineRun.create/3` and
      # `assume_ownership/1` remain the only two mint entry points; the
      # repo-wide sweep is in the records file.
      base = Path.join([__DIR__, "..", "..", "..", "lib", "allm"])

      dsl_files =
        Path.wildcard(base <> "/pipeline.ex") ++
          Path.wildcard(base <> "/pipeline/dsl.ex") ++
          Path.wildcard(base <> "/pipeline/dsl/*.ex")

      assert length(dsl_files) >= 4,
             "the guard glob matched only #{length(dsl_files)} DSL files — the tree moved and " <>
               "this test is no longer scanning it. Re-point the guard."

      # Anchored to a CALL shape, not a bare literal: `ALLM.Pipeline`'s moduledoc
      # legitimately names `PipelineRun.assume_ownership/1` in prose explaining
      # why the DSL does not call it, and a substring match would flag that.
      offenders =
        Enum.filter(
          dsl_files,
          &(File.read!(&1) =~ ~r/(assume_ownership|mint_token)\s*\(|completion_token:/)
        )

      # POSITIVE CONTROL: an empty `offenders` and a broken regex are the same
      # observation. `pipeline_run.ex` holds both real mint points, so the same
      # pattern MUST match there — if it stops, the guard above proves nothing.
      mint_site = Path.join(base, "pipeline/pipeline_run.ex")

      assert File.read!(mint_site) =~ ~r/(assume_ownership|mint_token)\s*\(|completion_token:/,
             "the mint-point pattern no longer matches #{mint_site}, so its zero hits across " <>
               "the DSL files prove nothing."

      assert offenders == [],
             "these DSL files name a completion-token mint point: #{inspect(offenders)}. " <>
               "The generated run/1 gets its owning handle from " <>
               "Executor.create_pipeline_run/3 and never re-mints."
    end
  end
end
