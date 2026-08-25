import Config

# ExAws → Req as the HTTP client, env-independent. The umbrella host sets this
# in ITS `config/config.exs` (not test.exs) for the same reason: without it
# ExAws defaults to :hackney, which is not in the dependency tree — every
# Dynamo/S3 call would crash rather than degrade/skip. `req` is transitively
# present via `allm`.
config :ex_aws, http_client: ExAws.Request.Req

# Per-env config, only where a file exists (only test.exs today — the package
# has no dev/prod runtime of its own; a host wires it through its registry).
env_config = Path.join(__DIR__, "#{config_env()}.exs")
if File.exists?(env_config), do: import_config(env_config)
