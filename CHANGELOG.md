## [REL] v0.1.0 — Standalone extraction

- Initial standalone release of `ALLM.Pipeline`, extracted from its original
  host umbrella (extraction plan Phases 1–8): `Step` / `Executor` / `StepLog` /
  `ArtifactStore` (DynamoDB + S3 tiered), run lifecycle ownership
  (`Lifecycle`), the `use ALLM.Pipeline` DSL, `use ALLM.Pipeline.LLMStep`
  on top of `allm`, and `use ALLM.Pipeline.Registry` for host wiring.
- Self-contained test harness (`ALLM.Pipeline.TestRepo` + test-only
  migrations + test registry); host repos and production migrations stay in
  the consumer.
