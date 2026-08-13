defmodule ALLMPipeline.MixProject do
  use Mix.Project

  def project do
    [
      app: :allm_pipeline,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
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

  defp deps do
    [
      # ⚠️ THE LOAD-BEARING OMISSION: there is deliberately NO
      # `{:amesbury, in_umbrella: true}` here, and none of the other umbrella
      # apps either. It looks like a mistake; it is the entire point.
      #
      # `allm_pipeline` is a leaf app headed for hex (extraction plan Phase 8).
      # Leaving the host out of its dep list makes the umbrella compiler enforce
      # the dependency direction: any reach back into `Amesbury.*` or
      # `AmesburyScraper.*` from this tree is a compile error at
      # `--warnings-as-errors`, not a review finding somebody has to notice.
      # That is what lets the package be developed in-tree with no version skew
      # against the published copy.
      #
      # Host-supplied collaborators are resolved at RUNTIME instead — today just
      # the Ecto repo, via `ALLM.Pipeline.Config.repo/0`.
      # See steering/2026-08-10_ALLM_PIPELINE_PHASE_1.md §1, §5.1.

      # Persistence — the package ships Ecto schemas (`PipelineRun`, `StepLog`,
      # `PipelineMetric`) and raw SQL (`StepLog.build_lineage_tree/1`), but owns
      # no repo and no migrations. Migrations stay in the host (§5.4).
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},

      # Artifact bodies and jsonb-bound metadata.
      {:jason, "~> 1.2"},

      # Event contract (extraction plan §3.7).
      {:telemetry, "~> 1.0"},

      # Hard dependency, and the reason for the namespace: the framework's
      # centre of gravity is LLM pipelines (extraction plan §3.1).
      {:allm, "~> 0.4.2"},

      # Optional, gated per artifact adapter. `Artifacts.Dynamo` needs both;
      # a host that configures a different adapter need not carry them.
      # `ex_aws_s3` is NOT a dependency in this phase — there is no S3 adapter
      # until Phase 7.
      {:ex_aws, "~> 2.5", optional: true},
      {:ex_aws_dynamo, "~> 4.2", optional: true}
    ]
  end
end
