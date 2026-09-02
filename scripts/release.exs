# scripts/release.exs — ALLM.Pipeline Hex release script
#
# Ported from ALLM's `scripts/release.exs` (~/Projects/ALLM); same two-phase
# flow, this package's gates.
#
# Usage (two-phase flow)
# ----------------------
#
# Phase A — gates + bump (writes mix.exs only; no commit, no publish):
#
#     mix run scripts/release.exs patch          # 0.1.0 -> 0.1.1
#     mix run scripts/release.exs minor          # 0.1.0 -> 0.2.0
#     mix run scripts/release.exs major          # 0.1.0 -> 1.0.0
#     mix run scripts/release.exs 0.2.0-rc.1     # explicit SemVer
#
# Then publish manually (so OAuth device flow + interactive prompts get a
# real terminal):
#
#     mix hex.publish
#
# Phase B — commit + tag (after publish succeeds):
#
#     mix run scripts/release.exs --finalize
#
#     mix run scripts/release.exs --help
#
# Flags
# -----
#
#     --finalize        Phase B mode (no <bump> arg; reads mix.exs).
#     --skip-dialyzer   Skip `mix dialyzer` (PLT is slow; OK for patches you
#                       just ran dialyzer against).
#     --dry-run         Run every Phase A gate; stop before bump. No
#                       working-tree mutations.
#     --allow-dirty     Bypass the working-tree-clean check. Loud warning.
#
# Setup (one-time, per maintainer workstation)
# --------------------------------------------
#
# Hex auth lives in `~/.hex/hex.config`. There is no `HEX_API_KEY` in CI, no
# GitHub Actions secret, no shared key. Releases are local-only by design.
#
#     mix hex.user whoami           # confirm cykod
#     mix hex.user auth             # log in if needed (interactive; 2FA if enrolled)
#
# Inside the devcontainer (headless) the device-flow auth cannot open a
# browser: either run `mix hex.user auth` once on the host and copy
# `~/.hex/hex.config` in, or export `HEX_API_KEY=<key>` before
# `mix hex.publish`.
#
# Hotfix runbook (broken release)
# -------------------------------
#
# 1. Within 24 hours of the FIRST-EVER publish of `allm_pipeline`:
#
#        mix hex.publish --revert <version>
#
# 2. For any subsequent version the revert window narrows to 1 hour.
#
# 3. After the window closes: soft-retire and patch forward.
#
#        mix hex.retire allm_pipeline <version> invalid \
#          --message "Use <next>, contains <bug>"
#
# Never `git commit --amend` past a release. Once `mix hex.publish` has
# uploaded the tarball the version is committed on Hex regardless of local
# git state — any fix is the next patch. The idempotent re-run path (mix.exs
# already at target -> skip the bump) handles "publish failed mid-flight,
# fix and re-run" without amending.
#
# Package-specific gates
# ----------------------
#
# - The quality gates mirror `mix precommit`'s four steps (compile
#   `--warnings-as-errors`, format, test `--warnings-as-errors`, `dialyzer`)
#   plus `mix hex.build`. This script runs its own explicit gate list rather
#   than shelling out to `mix precommit`, and inserts `mix dialyzer` (skippable)
#   itself — keep the two lists in sync by hand. Credo is not a dep here.
# - `mix test` needs Postgres (and, for the full set, DynamoDB Local + MinIO —
#   see README "Test setup"). With the stack down the `:dynamo` tests are
#   EXCLUDED, not failed, so a green gate with the stack down is a weaker
#   gate: the script warns when `Excluding tags` appears in the test output.
# - Migration-touch warning: `priv/test_repo/migrations/` is test-harness DDL
#   that is schema-parity-checked against the host's tables ("table names are
#   contract"). If it changed since the last release tag the script warns to
#   re-run the parity check from the umbrella before publishing.
#
# What this script does NOT do
# ----------------------------
#
# - Does NOT invoke `mix hex.publish` (Mix archives are not loaded into
#   `mix run`'s runtime, and Hex's device-flow auth crashes headless). Hex's
#   prompts ARE part of the safety story; never `--yes`.
# - Does NOT publish from CI. No `--non-interactive` mode by design.
# - Does NOT edit CHANGELOG content. Run the `/changelog` skill first; the
#   script only verifies a `## ` heading containing `v<X.Y.Z>` exists.
# - Does NOT contact `origin` (no fetch / ls-remote / push). Tag collision is
#   checked locally only; Hex rejects a duplicate version server-side.
# - Does NOT `git push`. Phase B commits + tags locally and prints the push
#   command.
# - Does NOT bump the Amesbury umbrella. The umbrella consumes this repo as a
#   PATH dep (`apps/amesbury_scraper/mix.exs`), so a Hex release changes
#   nothing there until it switches to `{:allm_pipeline, "~> X.Y"}`.

defmodule ALLM.Pipeline.Release do
  @moduledoc false

  @package "allm_pipeline"
  @mix_exs_path "mix.exs"
  @changelog_path "CHANGELOG.md"
  @asks_path "ASKS.md"
  @migrations_dir "priv/test_repo/migrations/"

  # Paths the clean-tree check tolerates dirty going INTO Phase A, and that Phase
  # B stages into the release commit: `/changelog` writes CHANGELOG.md and leaves
  # it uncommitted, and ask-logging appends to ASKS.md throughout a release. Both
  # are maintainer-written record files, expected-dirty at release time — so a
  # tree dirty by ONLY these does not need the blunt `--allow-dirty`. Any other
  # dirty path still aborts (or needs `--allow-dirty`).
  @release_dirty_allowlist [@changelog_path, @asks_path]

  # The hard banned-pattern regex for published-doc history, mirroring the `HARD`
  # literal in `agent-spec/DOCS.md` C2 (single source of truth). Development-phase
  # numbering, ISO-dated rationale, `batch N` / `extraction plan` / `steering/20…`
  # references, and consumer-specific proper nouns. Reproduced here so the release
  # can grep the regenerated hexdocs; keep it byte-for-byte in step with DOCS.md
  # (which names this `@hexdocs_history_pattern` back as its executable copy).
  # The only sanctioned difference is this sigil escaping `steering\/20`. There
  # is no automated drift guard by design; the two files reference each other and
  # are edited as a pair.
  @hexdocs_history_pattern ~r/[Pp]hases? [0-9]|\(D[0-9]|used to |no longer|predates|retired|Before Phase|As of 20[0-9][0-9]|20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]|batch [0-9]|extraction plan|steering\/20|meeting_agenda|MeetingAgenda|MeetingList|MeetingImportance|MeetingsPipeline|CommitteePipeline|committee|Government|Scorer|Ordinance|ordinance|Amesbury|amesbury/

  def main(argv) do
    case parse_args(argv) do
      :help ->
        print_help()
        System.halt(0)

      {:ok, opts} ->
        run(opts)

      {:error, msg} ->
        IO.puts(:stderr, "ERROR: " <> msg)
        IO.puts(:stderr, "")
        print_help()
        System.halt(1)
    end
  end

  # ----- argument parsing ----------------------------------------------------

  defp parse_args([]), do: {:error, "missing version-bump argument"}

  defp parse_args(argv) do
    cond do
      "--help" in argv or "-h" in argv ->
        :help

      "--finalize" in argv ->
        flags = Enum.reject(argv, &(&1 == "--finalize"))

        case parse_flags(flags) do
          {:ok, opts} -> {:ok, Map.put(opts, :phase, :finalize)}
          {:error, _} = err -> err
        end

      true ->
        {flags, positionals} = Enum.split_with(argv, &String.starts_with?(&1, "--"))

        with {:ok, bump} <- parse_bump(positionals),
             {:ok, opts} <- parse_flags(flags) do
          {:ok, opts |> Map.put(:bump, bump) |> Map.put(:phase, :prepare)}
        end
    end
  end

  defp parse_bump([]), do: {:error, "missing version-bump argument"}
  defp parse_bump([single]), do: {:ok, single}
  defp parse_bump(many), do: {:error, "expected one positional arg, got #{inspect(many)}"}

  defp parse_flags(flags) do
    valid = ["--skip-dialyzer", "--dry-run", "--allow-dirty"]

    Enum.reduce_while(flags, {:ok, default_opts()}, fn flag, {:ok, acc} ->
      cond do
        flag == "--skip-dialyzer" -> {:cont, {:ok, %{acc | skip_dialyzer: true}}}
        flag == "--dry-run" -> {:cont, {:ok, %{acc | dry_run: true}}}
        flag == "--allow-dirty" -> {:cont, {:ok, %{acc | allow_dirty: true}}}
        true -> {:halt, {:error, "unknown flag: #{flag} (valid: #{Enum.join(valid, ", ")})"}}
      end
    end)
  end

  defp default_opts, do: %{skip_dialyzer: false, dry_run: false, allow_dirty: false}

  defp print_help do
    IO.puts("""
    ALLM.Pipeline release script — runs the quality gates around a manual `mix hex.publish`.

    Usage:
      mix run scripts/release.exs <bump> [flags]      # Phase A — gates + bump
      mix run scripts/release.exs --finalize [flags]  # Phase B — commit + tag

    Phase A (`<bump>`):
      Runs git/branch/tag/CHANGELOG/quality gates, bumps `mix.exs:@version`,
      prompts for confirmation, then PRINTS the `mix hex.publish` command
      and exits. Publish manually so its OAuth flow gets a real terminal.

    Phase B (`--finalize`):
      After `mix hex.publish` succeeds: commit `mix.exs` + `CHANGELOG.md` +
      `ASKS.md`, create an annotated tag, print the `git push` command
      (push is manual).

    <bump>:
      patch | minor | major | <semver>   e.g. 0.2.0-rc.1

    Flags:
      --finalize        Phase B mode (no <bump> arg)
      --skip-dialyzer   skip `mix dialyzer` (PLT slow)
      --dry-run         run every Phase A gate; stop before bump; no mutations
      --allow-dirty     bypass git-clean check entirely (loud warning);
                        CHANGELOG.md + ASKS.md are already tolerated without it
      --help, -h        this message
    """)
  end

  # ----- main flow -----------------------------------------------------------

  defp run(%{phase: :finalize} = opts), do: run_finalize(opts)
  defp run(%{phase: :prepare} = opts), do: run_prepare(opts)

  defp run_finalize(_opts) do
    log_step("finalize.1", "read current version from #{@mix_exs_path}")
    new_version = current_version()
    tag = "v#{new_version}"
    IO.puts("  version: #{new_version}")
    IO.puts("  tag:     #{tag}")

    log_step("finalize.2", "CHANGELOG entry for #{new_version}?")
    check_changelog(new_version)

    log_step("finalize.3", "tag #{tag} doesn't already exist locally?")
    check_tag_absent(tag)

    log_step("finalize.4", "git commit + tag (push is manual)")
    finalize_release!(new_version, tag)

    log_step("finalize.5", "done")
    print_success(new_version)
  end

  defp run_prepare(opts) do
    log_step("step 1", "compute new version from #{@mix_exs_path}")
    current = current_version()
    new_version = compute_new_version(current, opts.bump)
    IO.puts("  current: #{current}")
    IO.puts("  new:     #{new_version}")
    tag = "v#{new_version}"

    log_step("step 2", "git working tree clean?")
    check_working_tree(opts.allow_dirty)

    log_step("step 3", "on `main`?")
    check_branch()

    log_step("step 4", "up-to-date check (offline; maintainer's responsibility)")
    IO.puts("  (offline; sync main before invoking)")

    log_step("step 5", "tag #{tag} doesn't already exist?")
    check_tag_absent(tag)

    log_step("step 6", "CHANGELOG entry for #{new_version}?")
    check_changelog(new_version)

    log_step("step 6b", "test-harness migrations changed since last tag?")
    migration_touch_warning(current)

    log_step("step 6c", "hexdocs free of development-history references?")
    hexdocs_history_warning()

    log_step("step 7", "quality gates")
    run_quality_gates(opts)

    log_step("step 8", "bump @version in #{@mix_exs_path}")

    if current == new_version do
      IO.puts("  mix.exs already at #{new_version}; skipping bump (idempotent re-run path)")
    else
      bump_mix_version!(new_version, opts.dry_run)
    end

    log_step("step 9", "diff preview")
    show_diff()

    if opts.dry_run do
      IO.puts("")
      IO.puts("--- DRY RUN: stopping before bump + manual-publish handoff ---")
      # No rollback here: `bump_mix_version!/2` never writes under --dry-run,
      # and a `git checkout -- mix.exs` would discard UNCOMMITTED mix.exs edits
      # under --allow-dirty (caught by reading the code while porting).
      log_step("step 10", "would prompt for confirmation (skipped)")
      log_step("finalize.*", "Phase B would commit + tag #{tag} locally (skipped)")
      System.halt(0)
    end

    log_step("step 10", "confirmation prompt")

    case prompt_yes_no(
           "Ready to hand off to `mix hex.publish` for #{@package} #{new_version}? [y/N] "
         ) do
      :yes ->
        :ok

      :no ->
        IO.puts("Aborted; rolling back mix.exs edits.")
        rollback_edits(:user_declined)
        System.halt(1)
    end

    log_step("step 11", "Phase A complete — publish manually")
    print_phase_a_complete(new_version, tag)
    System.halt(0)
  end

  # ----- step 1: version computation -----------------------------------------

  defp current_version, do: Mix.Project.config()[:version]

  defp compute_new_version(current, "patch"), do: bump_segment(current, :patch)
  defp compute_new_version(current, "minor"), do: bump_segment(current, :minor)
  defp compute_new_version(current, "major"), do: bump_segment(current, :major)

  defp compute_new_version(_current, explicit) do
    case Version.parse(explicit) do
      {:ok, %Version{} = v} ->
        to_string(v)

      :error ->
        abort("invalid version: #{inspect(explicit)} (must be patch|minor|major|<semver>)")
    end
  end

  defp bump_segment(current, segment) do
    case Version.parse(current) do
      {:ok, %Version{major: ma, minor: mi, patch: pa}} ->
        case segment do
          :patch -> "#{ma}.#{mi}.#{pa + 1}"
          :minor -> "#{ma}.#{mi + 1}.0"
          :major -> "#{ma + 1}.0.0"
        end

      :error ->
        abort("could not parse current version #{inspect(current)} from mix.exs")
    end
  end

  # ----- steps 2-5: git gates ------------------------------------------------

  defp check_working_tree(true),
    do: IO.puts("  --allow-dirty set: skipping clean-tree check (BE CAREFUL).")

  defp check_working_tree(false) do
    {out, 0} = System.cmd("git", ["status", "--porcelain"])

    cond do
      out == "" ->
        IO.puts("  clean")

      dirty_paths(out) -- @release_dirty_allowlist == [] ->
        IO.puts(
          "  clean except #{Enum.join(@release_dirty_allowlist, ", ")} " <>
            "(allowed dirty; Phase B commits them)"
        )

      true ->
        IO.puts(:stderr, out)

        abort(
          "git working tree is dirty beyond #{Enum.join(@release_dirty_allowlist, ", ")}; " <>
            "commit/stash or pass --allow-dirty"
        )
    end
  end

  # Paths from `git status --porcelain` output. Porcelain v1 is `XY <path>`; a
  # rename is `R  <old> -> <new>` — take the destination. CHANGELOG.md / ASKS.md
  # are plain names (never quoted or renamed), so this stays simple.
  defp dirty_paths(porcelain_out) do
    porcelain_out
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      line
      |> String.slice(3..-1//1)
      |> String.split(" -> ")
      |> List.last()
      |> String.trim()
    end)
  end

  defp check_branch do
    {out, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"])
    branch = String.trim(out)

    if branch == "main",
      do: IO.puts("  on main"),
      else: abort("not on `main` (current: #{branch}); release must run from `main`")
  end

  defp check_tag_absent(tag) do
    case System.cmd("git", ["rev-parse", tag], stderr_to_stdout: true) do
      {_out, 0} -> abort("tag #{tag} already exists locally; bump again or delete the local tag")
      {_out, _} -> IO.puts("  tag #{tag} not present locally (origin not consulted; offline)")
    end
  end

  # ----- step 6: CHANGELOG check ---------------------------------------------

  defp check_changelog(new_version) do
    body = File.read!(@changelog_path)
    pattern = ~r/^##\s+.*v#{Regex.escape(new_version)}\b/m

    if Regex.match?(pattern, body) do
      IO.puts("  found `## ` heading containing `v#{new_version}`")
    else
      abort(
        "CHANGELOG.md missing release notes heading for v#{new_version}. " <>
          "Run the `/changelog` skill to add a heading for v#{new_version} " <>
          "(e.g., '## [REL] v#{new_version} — <summary>'), then re-run."
      )
    end
  end

  # ----- step 6b: migration-touch warning ------------------------------------

  defp migration_touch_warning(current_version) do
    previous_tag = "v#{current_version}"

    case System.cmd("git", ["rev-parse", previous_tag], stderr_to_stdout: true) do
      {_out, 0} ->
        {out, 0} = System.cmd("git", ["diff", "#{previous_tag}..HEAD", "--name-only"])

        changed =
          out
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, @migrations_dir))

        if changed == [] do
          IO.puts("  no changes under #{@migrations_dir} since #{previous_tag}")
        else
          IO.puts(:stderr, "")

          IO.puts(
            :stderr,
            "WARNING: test-harness DDL changed since #{previous_tag}: #{Enum.join(changed, ", ")}"
          )

          IO.puts(
            :stderr,
            "         Re-run the schema-parity check against the host's `amesbury_test`"
          )

          IO.puts(
            :stderr,
            "         (site named in the migration's moduledoc) BEFORE publishing."
          )

          IO.puts(:stderr, "")
        end

      {_out, _} ->
        IO.puts("  (no previous tag #{previous_tag}; skipping migration-touch warning)")
    end
  end

  # ----- step 6c: hexdocs history warning ------------------------------------
  #
  # Regenerates the published surface (`doc/*.md` — this is the release path's
  # first `mix docs` run) and greps it for the C2 `HARD` pattern
  # (`@hexdocs_history_pattern`, mirrored from `agent-spec/DOCS.md`). `doc/` is
  # gitignored build output; ExDoc renders only `@moduledoc`/`@doc`, so this is
  # the literal published text. `changelog.md` is carved out — a changelog
  # legitimately records the rename it performed. A hit only WARNs (advisory tone,
  # like the migration-touch and `Excluding tags` warnings); a release is never
  # blocked by a doc grep, only flagged.
  defp hexdocs_history_warning do
    case System.cmd("mix", ["docs"], stderr_to_stdout: true) do
      {_out, 0} ->
        hits =
          "doc/*.md"
          |> Path.wildcard()
          |> Enum.reject(&(Path.basename(&1) == "changelog.md"))
          |> Enum.flat_map(fn path ->
            path
            |> File.read!()
            |> String.split("\n")
            |> Enum.with_index(1)
            |> Enum.filter(fn {line, _n} -> Regex.match?(@hexdocs_history_pattern, line) end)
            |> Enum.map(fn {line, n} -> "#{path}:#{n}: #{line}" end)
          end)

        if hits == [] do
          IO.puts("  hexdocs free of development-history references")
        else
          IO.puts(:stderr, "")

          IO.puts(
            :stderr,
            "WARNING: hexdocs still contain development-history references " <>
              "(#{length(hits)} line#{if length(hits) == 1, do: "", else: "s"}) " <>
              "— see agent-spec/DOCS.md."
          )

          Enum.each(hits, &IO.puts(:stderr, "         #{&1}"))
          IO.puts(:stderr, "")
        end

      {out, code} ->
        IO.puts(:stderr, out)

        IO.puts(
          :stderr,
          "  (mix docs failed, exit #{code}; skipping hexdocs-history warning)"
        )
    end
  end

  # ----- step 7: quality gates -----------------------------------------------

  defp run_quality_gates(opts) do
    gates = [
      {"mix deps.get", ["deps.get"]},
      {"mix compile --warnings-as-errors", ["compile", "--warnings-as-errors"]},
      {"mix format --check-formatted", ["format", "--check-formatted"]},
      {"mix test --warnings-as-errors", ["test", "--warnings-as-errors"]},
      {"mix hex.build", ["hex.build"]}
    ]

    gates =
      if opts.skip_dialyzer do
        IO.puts("  --skip-dialyzer set: dialyzer gate skipped")
        gates
      else
        List.insert_at(gates, -2, {"mix dialyzer", ["dialyzer"]})
      end

    Enum.each(gates, fn {label, args} ->
      IO.puts("  -> #{label}")

      case System.cmd("mix", args, stderr_to_stdout: true) do
        {out, 0} ->
          if label =~ "mix test" and out =~ "Excluding tags" do
            IO.puts(:stderr, "")
            IO.puts(:stderr, "WARNING: `mix test` excluded tags (DynamoDB Local / MinIO down?).")

            IO.puts(
              :stderr,
              "         The :dynamo set did NOT run. Bring the stack up and re-run"
            )

            IO.puts(:stderr, "         for a full gate (README \"Test setup\").")
            IO.puts(:stderr, "")
          end

        {out, code} ->
          IO.puts(:stderr, out)
          abort("#{label} failed (exit #{code}); fix and re-run (working tree NOT mutated)")
      end
    end)
  end

  # ----- step 8: bump mix.exs -----------------------------------------------

  defp bump_mix_version!(new_version, dry_run?) do
    body = File.read!(@mix_exs_path)
    pattern = ~r/(@version\s+")[^"]+(")/

    unless Regex.match?(pattern, body) do
      abort("could not find `@version \"...\"` in #{@mix_exs_path}")
    end

    # `\g{N}` not `\N`: a version starting with a digit would otherwise be
    # parsed as back-ref 10 by Erlang's `re` and mangle the file.
    new_body = Regex.replace(pattern, body, "\\g{1}#{new_version}\\g{2}", global: false)

    cond do
      new_body == body ->
        IO.puts("  no change (already #{new_version})")

      dry_run? ->
        IO.puts("  [dry-run] would write #{@mix_exs_path} with @version \"#{new_version}\"")

      true ->
        File.write!(@mix_exs_path, new_body)
        IO.puts("  bumped @version -> #{new_version}")
    end
  end

  # ----- step 9: diff preview -----------------------------------------------

  defp show_diff do
    case System.cmd("git", ["diff", "--" | [@mix_exs_path | @release_dirty_allowlist]]) do
      {"", 0} -> IO.puts("  (no diff in mix.exs / CHANGELOG.md / ASKS.md)")
      {out, 0} -> IO.puts("\n" <> out <> "\n")
    end
  end

  # ----- step 10: confirmation prompt + rollback -----------------------------

  defp prompt_yes_no(prompt) do
    case IO.gets(prompt) do
      input when is_binary(input) ->
        case input |> String.trim() |> String.downcase() do
          "y" -> :yes
          "yes" -> :yes
          _ -> :no
        end

      _ ->
        :no
    end
  end

  # Only mix.exs is mutated by the script; CHANGELOG.md and ASKS.md are
  # maintainer-written and must NOT be checked out (would blow away notes/logs).
  defp rollback_edits(reason) do
    {_out, _code} = System.cmd("git", ["checkout", "--", @mix_exs_path], stderr_to_stdout: true)
    IO.puts("  reverted #{@mix_exs_path} (#{reason})")
  end

  # ----- step 11: Phase A handoff -------------------------------------------

  defp print_phase_a_complete(new_version, tag) do
    IO.puts("""

    Phase A complete. mix.exs carries the v#{new_version} bump; all gates passed.

    Publish manually so Hex's prompts and OAuth flow get a real terminal:

        mix hex.publish

    (Auth: `~/.hex/hex.config` must already carry credentials — run
     `mix hex.user auth` once on a browser-capable workstation — OR set
     `HEX_API_KEY=<key>` in the environment.)

    After the publish succeeds:

        mix run scripts/release.exs --finalize

    Phase B commits mix.exs + CHANGELOG.md + ASKS.md, creates annotated tag
    #{tag}, and prints the `git push` command.

    If the publish fails or you abort, roll back with
    `git checkout -- #{@mix_exs_path}` or just re-run Phase A.
    """)
  end

  # ----- Phase B: commit + tag (NO push) -------------------------------------

  defp finalize_release!(new_version, tag) do
    run!("git", ["add" | [@mix_exs_path | @release_dirty_allowlist]])

    # `git diff --cached --quiet` exits 0 when nothing is staged (bump already
    # committed — tag HEAD directly), 1 when there are staged changes.
    case System.cmd("git", ["diff", "--cached", "--quiet"]) do
      {_out, 0} ->
        IO.puts("  no staged changes — release commit already exists at HEAD; tagging directly")

      {_out, 1} ->
        run!("git", ["commit", "-m", "Release #{tag}"])

      {out, code} ->
        IO.puts(:stderr, out)
        abort("git diff --cached --quiet failed (exit #{code})")
    end

    run!("git", ["tag", "-a", tag, "-m", "v#{new_version}"])
  end

  defp run!(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        IO.puts(:stderr, out)
        abort("#{cmd} #{Enum.join(args, " ")} failed (exit #{code})")
    end
  end

  defp print_success(new_version) do
    tag = "v#{new_version}"

    IO.puts("""

    Phase B complete — local commit + annotated tag #{tag} created.

    If `mix hex.publish` already succeeded, the package is at:
      https://hex.pm/packages/#{@package}/#{new_version}
      https://hexdocs.pm/#{@package}/#{new_version}/

    Push from a workstation with GitHub access:

        git push origin main #{tag}

    Hexdocs `[source]` links 404 until that push lands.

    Consumer note: the Amesbury umbrella still consumes this repo as a PATH
    dep; a Hex release changes nothing there until it switches to
    `{:allm_pipeline, "~> #{major_minor(new_version)}"}`.
    """)
  end

  defp major_minor(version) do
    case Version.parse(version) do
      {:ok, %Version{major: ma, minor: mi}} -> "#{ma}.#{mi}"
      :error -> version
    end
  end

  # ----- helpers -------------------------------------------------------------

  defp log_step(label, msg), do: IO.puts("[#{label}] #{msg}")

  defp abort(msg) do
    IO.puts(:stderr, "ERROR: " <> msg)
    System.halt(1)
  end
end

ALLM.Pipeline.Release.main(System.argv())
