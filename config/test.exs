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

# ── Framework config, all under :amesbury_scraper ────────────────────────────
# The config namespace is a deliberate non-goal of the extraction: the package
# reads/writes `:amesbury_scraper` (hardcoded in `Registry.@otp_app` and the
# seam modules). Renaming it is deferred until a second consumer makes the name
# a real API. Values below mirror the umbrella's `config/test.exs`.

# DynamoDB (local). NOTE: the table name deliberately differs from the
# umbrella's (`amesbury_artifacts_test`) so the two suites never share Dynamo
# state.
config :amesbury_scraper, :dynamo,
  table_name: "allm_pipeline_artifacts_test",
  endpoint: System.get_env("DYNAMODB_ENDPOINT") || "http://localhost:4028",
  region: "us-east-1"

# Large-tier artifact storage — local MinIO. The bucket is shared with the
# umbrella suite (acceptable: S3 keys are content-addressed per artifact and
# the live round-trip test writes unique keys).
config :amesbury_scraper, ALLM.Pipeline.Artifacts.S3,
  bucket: "amesbury-artifacts-test",
  endpoint: System.get_env("MEDIA_ENDPOINT") || "http://localhost:4026",
  region: "us-east-1"

# ExAws credentials. DynamoDB Local ignores credentials, but the live-S3
# round-trip test hits real MinIO, which enforces them.
config :ex_aws,
  access_key_id: "minioadmin",
  secret_access_key: "minioadmin",
  region: "us-east-1"

# Full LLM-call input/output capture on, mirroring the umbrella's config.exs.
config :amesbury_scraper, ALLM.Pipeline.LLMCallLog, enabled: true

# Print only warnings and errors during test
config :logger, level: :warning
