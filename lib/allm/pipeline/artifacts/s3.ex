defmodule ALLM.Pipeline.Artifacts.S3 do
  @moduledoc """
  S3 `ALLM.Pipeline.Artifacts` adapter — the large-tier backend for artifacts
  that do not fit a DynamoDB item.

  Speaks `s3://<bucket>/<key>` URLs. The wrapper (`ALLM.Pipeline.ArtifactStore`)
  still owns compression, checksum and size accounting; this adapter stores the
  already-encoded payload verbatim as an object, and records the caller's
  `checksum` / `size_bytes` / `compressed` flag as object metadata so `fetch/1`
  can hand them back and `ArtifactStore` knows whether to gunzip.

  ## Optional dependency

  `ex_aws_s3` is an **optional** dependency of this package (`mix.exs`), matching
  `ex_aws` / `ex_aws_dynamo`: a host that configures a different artifact adapter
  need not carry it. Every entry point therefore checks `Code.ensure_loaded?/1`
  and returns `{:error, :s3_unavailable}` when the dep is absent — the same
  posture as `ALLM.Pipeline.Artifacts.Dynamo.available?/0`. The package compiles
  and its non-S3 tests pass without the dep loaded.

  ## Configuration

  Resolved at RUNTIME (a `mix release` build never evaluates `config/runtime.exs`,
  so the bucket cannot be baked at compile time):

      config :allm_pipeline, ALLM.Pipeline.Artifacts.S3,
        bucket: "amesbury-artifacts",
        # optional — a MinIO/localstack endpoint for local dev/test; unset in prod
        endpoint: "http://host.docker.internal:4026",
        region: "us-east-1"

  When `:endpoint` is set the adapter threads a per-request host/port/scheme
  override into `ExAws.request/2` (the same pattern as `Amesbury.Media.S3`), so
  no global `config :ex_aws, :s3` is needed and MinIO and real S3 can coexist.
  Credentials come from the standard `config :ex_aws` keys the rest of the app
  already uses.

  ## Object layout

  - Object key: the artifact `id` verbatim (`"<step_log_id>"` or
    `"<step_log_id>:llm"`) — both are valid S3 keys.
  - Object metadata: `checksum`, `size_bytes`, `compressed` (string-encoded).
  - `content_type` is the S3 object's `Content-Type`.
  """

  @behaviour ALLM.Pipeline.Artifacts

  require Logger

  alias ALLM.Pipeline.Artifacts

  @scheme "s3://"

  @doc """
  The configured artifacts S3 bucket, resolved at runtime. `nil` when unset —
  `put/4` then refuses rather than writing to an unnamed bucket.
  """
  @spec bucket() :: String.t() | nil
  def bucket do
    Application.get_env(:allm_pipeline, __MODULE__, [])
    |> Keyword.get(:bucket)
  end

  @doc """
  Whether the S3 adapter is configured — `ex_aws_s3` is loaded and a bucket is
  named. Mirrors `ALLM.Pipeline.Artifacts.Dynamo.available?/0`. Configuration
  only; see `reachable?/0` for whether the backend actually answers.
  """
  @spec available?() :: boolean()
  def available? do
    dep_loaded?() and is_binary(bucket())
  end

  @doc """
  Whether the configured S3 backend actually answers — the probe the live
  round-trip test gates on. A `head_bucket` that returns any HTTP response
  (including 404 for a not-yet-created bucket) means the server is up; a
  connection error or a raise means it is not.
  """
  @spec reachable?() :: boolean()
  def reachable? do
    available?() and
      case ExAws.request(ExAws.S3.head_bucket(bucket()), ex_aws_config()) do
        {:ok, _} -> true
        {:error, {:http_error, _status, _}} -> true
        _ -> false
      end
  rescue
    _ -> false
  end

  @doc """
  The ExUnit tags to exclude when S3/MinIO is unreachable, plus an operator hint.
  Mirrors `ALLM.Pipeline.Artifacts.Dynamo.exclusions/0`. Returns `{[], nil}` when
  the backend answers.
  """
  @spec exclusions() :: {[atom()], String.t() | nil}
  def exclusions do
    if reachable?() do
      {[], nil}
    else
      endpoint =
        Application.get_env(:allm_pipeline, __MODULE__, [])
        |> Keyword.get(:endpoint, "the default AWS endpoint")

      {[:s3, :skip_unless_s3],
       "\n[test_helper] S3/MinIO is unreachable at #{endpoint} " <>
         "(bucket #{inspect(bucket())}) — excluding :s3 / :skip_unless_s3 tests. " <>
         "Start the local stack — in the Amesbury umbrella repo that is " <>
         "`docker-compose -f docker-compose.dev.yml up -d minio`.\n"}
    end
  end

  @impl true
  @spec put(Artifacts.id(), binary(), String.t(), Artifacts.meta()) ::
          {:ok, Artifacts.url()} | {:error, term()}
  def put(id, content, content_type, %{
        size_bytes: size_bytes,
        checksum: checksum,
        compressed: compressed
      }) do
    with :ok <- ensure_dep(),
         {:ok, bucket} <- require_bucket() do
      request =
        ExAws.S3.put_object(bucket, id, content,
          content_type: content_type,
          meta: [
            {"checksum", checksum},
            {"size-bytes", Integer.to_string(size_bytes)},
            {"compressed", to_string(compressed)}
          ]
        )

      case ExAws.request(request, ex_aws_config()) do
        {:ok, _} ->
          {:ok, @scheme <> "#{bucket}/#{id}"}

        {:error, reason} ->
          Logger.error("Failed to store S3 artifact #{id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  @spec fetch(Artifacts.url()) :: {:ok, Artifacts.stored()} | {:error, term()}
  def fetch(@scheme <> rest = url) do
    with :ok <- ensure_dep(),
         {:ok, bucket, key} <- parse(rest) do
      request = ExAws.S3.get_object(bucket, key)

      case ExAws.request(request, ex_aws_config()) do
        {:ok, %{body: body, headers: headers}} ->
          {:ok, decode(body, headers)}

        {:error, {:http_error, 404, _}} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_url} -> {:error, {:invalid_artifact_url, url}}
      other -> other
    end
  end

  def fetch(url), do: {:error, {:invalid_artifact_url, url}}

  @impl true
  @spec delete(Artifacts.url()) :: :ok | {:error, term()}
  def delete(@scheme <> rest) do
    with :ok <- ensure_dep(),
         {:ok, bucket, key} <- parse(rest) do
      request = ExAws.S3.delete_object(bucket, key)

      case ExAws.request(request, ex_aws_config()) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def delete(_url), do: {:error, :invalid_url}

  @impl true
  @spec exists?(Artifacts.url()) :: boolean()
  def exists?(@scheme <> rest) do
    with :ok <- ensure_dep(),
         {:ok, bucket, key} <- parse(rest) do
      request = ExAws.S3.head_object(bucket, key)

      case ExAws.request(request, ex_aws_config()) do
        {:ok, _} -> true
        {:error, _} -> false
      end
    else
      _ -> false
    end
  end

  def exists?(_url), do: false

  # ── helpers ────────────────────────────────────────────────────────────────

  # `s3://<bucket>/<key>` — bucket is the first path segment, key is everything
  # after it (an id may itself contain a `/`, so split on the FIRST `/` only).
  @spec parse(String.t()) :: {:ok, String.t(), String.t()} | {:error, :invalid_url}
  defp parse(rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] when bucket != "" and key != "" -> {:ok, bucket, key}
      _ -> {:error, :invalid_url}
    end
  end

  @spec decode(binary(), list()) :: Artifacts.stored()
  defp decode(body, headers) do
    meta = header_meta(headers)

    %{
      content: body,
      content_type: header(headers, "content-type"),
      compressed: meta["compressed"] == "true",
      checksum: meta["checksum"],
      size_bytes: parse_int(meta["size-bytes"])
    }
  end

  # Case-insensitive header lookup — ExAws returns `[{"Content-Type", …}, …]`
  # and header casing is not guaranteed across S3-compatible backends.
  @spec header(list(), String.t()) :: String.t() | nil
  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name, do: v
    end)
  end

  # The `x-amz-meta-<key>` object metadata, keyed by the bare `<key>`.
  @spec header_meta(list()) :: %{String.t() => String.t()}
  defp header_meta(headers) do
    for {k, v} <- headers,
        downcased = String.downcase(to_string(k)),
        String.starts_with?(downcased, "x-amz-meta-"),
        into: %{} do
      {String.replace_prefix(downcased, "x-amz-meta-", ""), v}
    end
  end

  @spec parse_int(String.t() | nil) :: non_neg_integer() | nil
  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  @spec require_bucket() :: {:ok, String.t()} | {:error, :s3_bucket_not_configured}
  defp require_bucket do
    case bucket() do
      bucket when is_binary(bucket) -> {:ok, bucket}
      _ -> {:error, :s3_bucket_not_configured}
    end
  end

  @spec ensure_dep() :: :ok | {:error, :s3_unavailable}
  defp ensure_dep do
    if dep_loaded?(), do: :ok, else: {:error, :s3_unavailable}
  end

  @spec dep_loaded?() :: boolean()
  defp dep_loaded?, do: Code.ensure_loaded?(ExAws.S3)

  # Per-request ExAws config. Credentials resolve from `config :ex_aws`; when a
  # `:endpoint` is configured (local MinIO/localstack) its host/port/scheme are
  # threaded through so S3 requests hit it instead of real AWS — mirroring
  # `Amesbury.Media.S3.aws_config/0`. Region falls back to the ExAws default.
  #
  # Exposed `@doc false` (not `defp`) so `s3_test.exs` exercises the real config
  # threading instead of hand-copying it — the sanctioned escape hatch for a
  # test that may not call a private helper (see `CLAUDE.md`,
  # `MeetingSummaryTransformer.meeting_summary_schema/0`).
  @doc false
  @spec ex_aws_config() :: keyword()
  def ex_aws_config do
    config = Application.get_env(:allm_pipeline, __MODULE__, [])
    base = if region = Keyword.get(config, :region), do: [region: region], else: []

    case Keyword.get(config, :endpoint) do
      nil ->
        base

      endpoint ->
        uri = URI.parse(endpoint)

        base
        |> Keyword.put(:host, uri.host)
        |> Keyword.put(:port, uri.port)
        |> Keyword.put(:scheme, "#{uri.scheme}://")
    end
  end
end
