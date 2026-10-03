import Config

# The standalone test harness's repo (test/support/test_repo.ex). `ecto_repos`
# is what `mix ecto.create -r ALLM.Pipeline.TestRepo` (the `test` alias) reads.
# Same env-var shape as the umbrella host's test repo config.
config :allm_pipeline, ecto_repos: [ALLM.Pipeline.TestRepo]

config :allm_pipeline, ALLM.Pipeline.TestRepo,
  username: System.get_env("DATABASE_USER") || "pascalrettig",
  password: System.get_env("DATABASE_PASSWORD") || "",
  hostname: System.get_env("DATABASE_HOST") || "localhost",
  database: "allm_pipeline_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# ── Framework config, all under :allm_pipeline ───────────────────────────────
# Values below mirror the umbrella's `config/test.exs`.

# DynamoDB (local). NOTE: the table name deliberately differs from the
# umbrella's (`amesbury_artifacts_test`) so the two suites never share Dynamo
# state.
config :allm_pipeline, :dynamo,
  table_name: "allm_pipeline_artifacts_test",
  endpoint: System.get_env("DYNAMODB_ENDPOINT") || "http://localhost:4028",
  region: "us-east-1"

# Large-tier artifact storage — local MinIO. The bucket is shared with the
# umbrella suite (acceptable: S3 keys are content-addressed per artifact and
# the live round-trip test writes unique keys).
config :allm_pipeline, ALLM.Pipeline.Artifacts.S3,
  bucket: "amesbury-artifacts-test",
  endpoint: System.get_env("MEDIA_ENDPOINT") || "http://localhost:4026",
  region: "us-east-1"

# ExAws credentials. DynamoDB Local ignores credentials, but the live-S3
# round-trip test hits real MinIO, which enforces them.
config :ex_aws,
  access_key_id: "minioadmin",
  secret_access_key: "minioadmin",
  region: "us-east-1"

# No retries against the local stack: DynamoDB Local / MinIO are either up or
# down, and a refused connection never succeeds on a later attempt. ExAws's
# default (10 attempts, exponential backoff) cost ~50s per full run with the
# stack down — the exclusion probes plus every untagged test whose Executor
# writes artifacts through the Tiered store. All three keys are given because
# ExAws merges `:retries` shallowly (a partial list drops the backoff keys).
config :ex_aws, :retries,
  max_attempts: 1,
  base_backoff_in_ms: 10,
  max_backoff_in_ms: 10_000

# Full LLM-call input/output capture on, mirroring the umbrella's config.exs.
config :allm_pipeline, ALLM.Pipeline.LLMCallLog, enabled: true

# Print only warnings and errors during test
config :logger, level: :warning
