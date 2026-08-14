defmodule ALLM.Pipeline.ArtifactStore do
  @moduledoc """
  The shared wrapper over `ALLM.Pipeline.Artifacts` — stores and retrieves
  pipeline artifacts (HTML, JSON, extracted text) through the configured
  adapter, and returns a URL reference for the PostgreSQL `step_log`.

  ## What this module owns, and what the adapter owns

  **Here: compression, checksum and size accounting.** `store/4` gzips (unless
  `compress: false`), SHA-256s the ORIGINAL bytes, records the ORIGINAL size,
  and `fetch/1` gunzips on the way back out. An adapter receives an opaque,
  already-encoded payload plus a `t:ALLM.Pipeline.Artifacts.meta/0` and stores
  both verbatim — so a new backend never re-derives any of it.

  **There: capacity.** "Does this fit me?" is the adapter's question. An
  adapter that cannot take a payload returns `{:error, :too_large}` and this
  module routes to the next tier. DynamoDB's answer is the interesting one: its
  400KB ceiling constrains the item **as stored**, i.e. gzipped and then
  base64-encoded, so `Dynamo.fits_item?/1` measures that and not the caller's
  original byte count — gating on the original routed a 600KB HTML artifact
  that gzips to 40KB down the (unimplemented) S3 path, where it was discarded.
  `size_bytes` in the return tuple and in the stored item is still the ORIGINAL
  uncompressed size; only the routing decision changed.

  ## URL Format

  - DynamoDB: `dynamo://table_name/artifact_id`
  - Filesystem: `file:///path/to/artifact`
  - Memory: `memory://artifact_id`
  - S3: `s3://bucket_name/key` (for artifacts that do not fit a DynamoDB item)

  ## Tiering is still hard-coded, and Phase 7 replaces it

  `store/4` routes oversize payloads to S3 and the read paths recognize an
  `s3://` URL, but S3 itself is unimplemented — so an oversize artifact is
  discarded with `{:error, :s3_not_implemented}`, which is why
  `ALLM.Pipeline.Executor.build_envelope/3` still truncates its LLM envelope in
  two rounds. Those `s3://` arms are the tier router's residue, not adapter
  knowledge: `Artifacts.Tiered` (extraction plan §3.6, Phase 7) subsumes both
  by making the tier list an adapter choice. Every other URL is handed to
  `Artifacts.impl/0`, which recognizes its own scheme and rejects the rest.
  """

  alias ALLM.Pipeline.Artifacts

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

    meta = %{size_bytes: original_size, checksum: checksum, compressed: compress}

    case Artifacts.impl().put(step_id, content_to_store, content_type, meta) do
      {:ok, url} -> {:ok, url, original_size, checksum}
      {:error, :too_large} -> store_in_s3()
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Retrieve artifact content by URL, decompressed.

  The adapter returns the payload as stored (see
  `t:ALLM.Pipeline.Artifacts.stored/0`); the gunzip happens here, because
  compression is this layer's concern.
  """
  @spec fetch(String.t()) :: fetch_result()
  def fetch("s3://" <> _rest), do: fetch_from_s3()

  def fetch(url) do
    case Artifacts.impl().fetch(url) do
      {:ok, %{content: content, compressed: true}} -> {:ok, :zlib.gunzip(content)}
      {:ok, %{content: content}} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete artifact by URL.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete("s3://" <> _rest) do
    # TODO: Implement S3 deletion (Phase 7 — `Artifacts.S3`).
    # Answers `:s3_not_implemented`, the same atom `store_in_s3/0` and
    # `fetch_from_s3/0` use for the identical condition. It read
    # `:not_implemented` until the Phase 1 polish pass, which made it the only
    # occurrence of that atom in the repo — three names for one unbuilt tier.
    {:error, :s3_not_implemented}
  end

  def delete(url), do: Artifacts.impl().delete(url)

  @doc """
  Check if artifact exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?("s3://" <> _rest) do
    # TODO: Implement S3 exists check
    false
  end

  def exists?(url), do: Artifacts.impl().exists?(url)

  # Private functions

  @spec store_in_s3() :: {:error, :s3_not_implemented}
  defp store_in_s3 do
    # TODO: Implement S3 storage for large artifacts (Phase 7 — `Artifacts.S3`).
    # Until then an artifact the configured adapter refuses is DISCARDED, which
    # is why `Executor.build_envelope/3` truncates rather than relying on this.
    {:error, :s3_not_implemented}
  end

  @spec fetch_from_s3() :: {:error, :s3_not_implemented}
  defp fetch_from_s3 do
    # TODO: Implement S3 fetch
    {:error, :s3_not_implemented}
  end

  @spec compute_checksum(binary()) :: String.t()
  defp compute_checksum(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
