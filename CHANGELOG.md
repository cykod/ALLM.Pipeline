## [REL] v0.1.0 — Standalone, consumer-ready

Consumer-facing configuration (wire against these):
- Read and write all framework configuration under the package's own OTP app,
  `:allm_pipeline` (previously the host's `:amesbury_scraper`). Every seam,
  `:repo`, `:alert_on_empty`, `:lock_keys`, and adapter config now lives under
  this namespace — an existing path-dep host must move its config in lockstep.
- Default DynamoDB artifact table name is now `allm_pipeline_artifacts` when
  unset (set `config :allm_pipeline, :dynamo, table_name:` to override).

Other changes:
- Initial standalone release of `ALLM.Pipeline`: `Step` / `Executor` /
  `StepLog` / `ArtifactStore` (DynamoDB + S3 tiered), run lifecycle ownership
  (`Lifecycle`), the `use ALLM.Pipeline` DSL, `use ALLM.Pipeline.LLMStep`
  on top of `allm`, and `use ALLM.Pipeline.Registry` for host wiring.
- Add a `guides/host_wiring.md` onboarding guide (a hexdocs extra) covering
  registry wiring, the optional `llm:` seam, production DDL adoption, artifact
  infrastructure, and the consumer test-suite pattern.
- Ship the canonical test-harness migration (`priv/test_repo/migrations`) in
  the package tarball as the DDL a new host copies and freezes.
- Host-neutral hexdocs: no consumer-specific names appear in `lib/` moduledocs.
- Self-contained test harness (`ALLM.Pipeline.TestRepo` + test-only
  migrations + test registry); host repos and production migrations stay in
  the consumer.
