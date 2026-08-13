defmodule ALLM.Pipeline.ArtifactStore do
  @moduledoc """
  Stores and retrieves pipeline artifacts (HTML, JSON, extracted text) in DynamoDB.

  Uses DynamoDB for artifacts that fit its 400KB item limit, S3 for larger files.
  Returns a URL reference that is stored in the PostgreSQL step_log.

  ## URL Format

  - DynamoDB: `dynamo://table_name/artifact_id`
  - S3: `s3://bucket_name/key` (for artifacts that do not fit a DynamoDB item)

  ## Which bytes the size gate measures

  DynamoDB's 400KB ceiling constrains the item **as stored**, so the gate is
  applied to the payload that actually reaches it: gzipped (unless
  `compress: false`) and then base64-encoded by `Dynamo.put_artifact/6`. It is
  NOT applied to the caller's original byte count — doing so routed a 600KB HTML
  artifact that gzips to 40KB down the (unimplemented) S3 path, where it was
  discarded. `size_bytes` in the return tuple and in the stored item is still the
  ORIGINAL uncompressed size; only the routing decision changed.

  This module owns the *routing* decision; `Dynamo.fits_item?/1` owns the
  capacity arithmetic behind it (the item limit, the base64 inflation, the
  metadata reserve). Keeping the two apart is deliberate — every future artifact
  adapter answers "does this fit me?" for itself rather than adding a pair of
  constants here.
  """

  alias ALLM.Pipeline.Artifacts.Dynamo

  @type store_result ::
          {:ok, url :: String.t(), size :: non_neg_integer(), checksum :: String.t()}
  @type fetch_result :: {:ok, binary()} | {:error, term()}

  @doc """
  Store artifact and return URL.

  Artifacts whose stored payload fits a DynamoDB item go to DynamoDB, larger ones
  to S3. "Stored payload" means post-compression and post-base64 — see the
  moduledoc.

  ## Options

  - `:compress` - Whether to gzip compress the content (default: true)

  ## Returns

  `{:ok, url, size_bytes, checksum}` where:
  - `url` is `dynamo://table/id` or `s3://bucket/key`
  - `size_bytes` is the original uncompressed size
  - `checksum` is the SHA-256 hash of the original content
  """
  @spec store(String.t(), binary(), String.t(), keyword()) :: store_result() | {:error, term()}
  def store(step_id, content, content_type, opts \\ []) do
    compress = Keyword.get(opts, :compress, true)
    original_size = byte_size(content)
    checksum = compute_checksum(content)

    content_to_store =
      if compress do
        :zlib.gzip(content)
      else
        content
      end

    if Dynamo.fits_item?(content_to_store) do
      store_in_dynamo(step_id, content_to_store, content_type, original_size, checksum, compress)
    else
      store_in_s3(step_id, content_to_store, content_type, original_size, checksum, compress)
    end
  end

  @doc """
  Retrieve artifact content by URL.
  """
  @spec fetch(String.t()) :: fetch_result()
  def fetch("dynamo://" <> rest) do
    [_table, artifact_id] = String.split(rest, "/", parts: 2)
    fetch_from_dynamo(artifact_id)
  end

  def fetch("s3://" <> rest) do
    [_bucket, key] = String.split(rest, "/", parts: 2)
    fetch_from_s3(key)
  end

  def fetch(url) do
    {:error, {:invalid_artifact_url, url}}
  end

  @doc """
  Delete artifact by URL.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete("dynamo://" <> rest) do
    [_table, artifact_id] = String.split(rest, "/", parts: 2)
    Dynamo.delete_artifact(artifact_id)
  end

  def delete("s3://" <> _rest) do
    # TODO: Implement S3 deletion
    {:error, :not_implemented}
  end

  def delete(_url) do
    {:error, :invalid_url}
  end

  @doc """
  Check if artifact exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?("dynamo://" <> rest) do
    [_table, artifact_id] = String.split(rest, "/", parts: 2)

    case Dynamo.get_artifact(artifact_id) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end

  def exists?("s3://" <> _rest) do
    # TODO: Implement S3 exists check
    false
  end

  def exists?(_url), do: false

  # Private functions

  defp store_in_dynamo(step_id, content, content_type, original_size, checksum, compressed) do
    case Dynamo.put_artifact(step_id, content, content_type, original_size, checksum, compressed) do
      :ok ->
        table_name = Dynamo.table_name()
        url = "dynamo://#{table_name}/#{step_id}"
        {:ok, url, original_size, checksum}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_in_s3(_step_id, _content, _content_type, _original_size, _checksum, _compressed) do
    # TODO: Implement S3 storage for large artifacts
    {:error, :s3_not_implemented}
  end

  defp fetch_from_dynamo(artifact_id) do
    case Dynamo.get_artifact(artifact_id) do
      {:ok, %{content: content, compressed: true}} ->
        {:ok, :zlib.gunzip(content)}

      {:ok, %{content: content, compressed: false}} ->
        {:ok, content}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_from_s3(_key) do
    # TODO: Implement S3 fetch
    {:error, :s3_not_implemented}
  end

  defp compute_checksum(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
