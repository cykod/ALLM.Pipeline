defmodule ALLMPipeline.MixProject do
  use Mix.Project

  # Bumped by `scripts/release.exs` (Phase A). Keep the literal on this line —
  # the script rewrites `@version "..."` by regex.
  @version "0.1.0"
  @source_url "https://github.com/cykod/ALLM.Pipeline"

  def project do
    [
      app: :allm_pipeline,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # No `mod:` — the package starts no supervision tree. `LLMCallLog` starts its
  # `Agent` on demand, which is why `AmesburyScraper.Application` (whose
  # `children` list is empty) had nothing to port.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "A step-based LLM pipeline framework: typed steps with persistent step logs, " <>
      "artifact lineage, run lifecycle ownership, and a declarative pipeline DSL."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # `HISTORY.md` / `ASKS.md` / `steering` are dev-only and stay out of the
      # tarball; `mix hex.build` strips test-only deps from the metadata itself.
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE CLAUDE.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      # Prose references to private or `@doc false` targets. ExDoc autolinks
      # any `Mod.fun/arity` in backticks and warns when the target is private
      # or hidden; every entry below is a DELIBERATE reference (the moduledocs
      # explain internals by naming them). If a name here stops existing,
      # delete the entry rather than letting it mask a real broken reference.
      skip_code_autolink_to: [
        "ALLM.Pipeline.__before_compile__/1",
        "ALLM.Pipeline.Schema.__before_compile__/1",
        "ALLM.Pipeline.Dsl.__validate__!/2",
        "ALLM.Pipeline.Dsl.Runtime.execute/4",
        "ALLM.Pipeline.Dsl.Runtime.run_concurrent/7",
        "ALLM.Pipeline.Executor.build_envelope/3",
        "ALLM.Pipeline.Executor.run_with_step_log/5",
        "ALLM.Pipeline.Executor.validate_input/2",
        "ALLM.Pipeline.Schema.JsonSchema.strip_nil/1",
        "ALLM.Pipeline.StepLog.serialize_struct/2"
      ]
    ]
  end

  defp deps do
    [
      # ⚠️ THE LOAD-BEARING OMISSION: there is deliberately NO dependency on any
      # host application here. It looks sparse; it is the entire point.
      #
      # `allm_pipeline` began life as a leaf app inside the Amesbury umbrella,
      # where the omitted `{:amesbury, in_umbrella: true}` made the umbrella
      # compiler enforce the dependency direction. The repo boundary now
      # enforces the same rule even harder: naming a host module (`Amesbury.*`,
      # `AmesburyScraper.*`, or any other consumer's namespace) anywhere in
      # `lib/` is a compile error, not a review finding somebody has to notice.
      # That is what lets a host consume the package as a path dep with no
      # version skew.
      #
      # Host-supplied collaborators are resolved at RUNTIME instead — the Ecto
      # repo and the seam adapters, via `use ALLM.Pipeline.Registry` in the
      # host (see `ALLM.Pipeline.Registry`'s moduledoc).

      # Persistence — the package ships Ecto schemas (`PipelineRun`, `StepLog`,
      # `PipelineMetric`) and raw SQL (`StepLog.build_lineage_tree/1`), but owns
      # no repo and no production migrations. Migrations stay in the host
      # ("table names are contract"); `priv/test_repo/migrations/` is
      # test-harness DDL only, parity-checked against the host's.
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},

      # The standalone test harness's `ALLM.Pipeline.TestRepo` uses
      # `Ecto.Adapters.Postgres`, which cannot load without postgrex. A host
      # supplies its own repo (and therefore its own driver), so this is
      # test-only here.
      {:postgrex, ">= 0.0.0", only: :test},

      # Artifact bodies and jsonb-bound metadata.
      {:jason, "~> 1.2"},

      # Event contract (extraction plan §3.7).
      {:telemetry, "~> 1.0"},

      # Hard dependency, and the reason for the namespace: the framework's
      # centre of gravity is LLM pipelines (extraction plan §3.1).
      {:allm, "~> 0.4.2"},

      # Optional, gated per artifact adapter. `Artifacts.Dynamo` needs
      # `ex_aws`/`ex_aws_dynamo`; `Artifacts.S3` (Phase 7) needs
      # `ex_aws`/`ex_aws_s3`. A host that configures a different adapter need not
      # carry them — each adapter checks `Code.ensure_loaded?/1` and degrades to
      # `{:error, :s3_unavailable}` (S3) / a skipped test (Dynamo) when its dep
      # is absent.
      {:ex_aws, "~> 2.5", optional: true},
      {:ex_aws_dynamo, "~> 4.2", optional: true},
      {:ex_aws_s3, "~> 2.5", optional: true},

      # Dialyzer stays a separate manual step, matching the host convention
      # (`mix precommit` does not run it); `scripts/release.exs` runs it unless
      # `--skip-dialyzer`.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # Hexdocs build (`mix docs`), published by `mix hex.publish`.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      test: [
        "ecto.create --quiet -r ALLM.Pipeline.TestRepo",
        "ecto.migrate --quiet -r ALLM.Pipeline.TestRepo --migrations-path priv/test_repo/migrations",
        "test"
      ],
      precommit: ["compile --warnings-as-errors", "format", "test --warnings-as-errors"]
    ]
  end
end
