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
  - S3: `s3://bucket_name/key`

  ## Tiering is an adapter choice (Phase 7)

  This module no longer routes by size or special-cases an `s3://` URL. Every
  URL is handed to `Artifacts.impl/0`, which for the production wiring is
  `ALLM.Pipeline.Artifacts.Tiered` — it measures the post-encode size and routes
  small→DynamoDB / large→S3 on `put/4`, and dispatches `fetch`/`delete`/`exists?`
  by URL scheme. An oversize artifact now has a real home, which is why
  `ALLM.Pipeline.Executor.build_envelope/3` no longer truncates its LLM envelope
  in two rounds.

  ## The gunzip is bounded (memory-safety)

  `fetch/1` gunzips a stored payload with an EXPLICIT decompressed-size ceiling
  (`max_decompressed_bytes/0`, default 64 MB), returning
  `{:error, :artifact_too_large}` rather than inflating an unbounded amount into
  memory. The ceiling is a fixed memory-safety budget — what one `fetch` may
  safely hold — chosen INDEPENDENTLY of any store's capacity: `Tiered`/`S3`
  removed the 400 KB DynamoDB bound, so "the max stored size" is undefined, and a
  cap generous enough to inflate a legitimate huge artifact whole would still
  admit a decompression bomb of that size. A genuinely huge artifact simply
  cannot be fetched whole into memory — the correct posture.
  """

  alias ALLM.Pipeline.{Artifacts, Telemetry}

  @type store_result ::
          {:ok, url :: String.t(), size :: non_neg_integer(), checksum :: String.t()}
  @type fetch_result :: {:ok, binary()} | {:error, term()}

  # An explicit memory-safety budget for a single decompressing `fetch/1`, NOT
  # derived from any store's capacity — see the "gunzip is bounded" moduledoc
  # section. Overridable per environment (a test uses a small value to prove the
  # bound without allocating the real ceiling).
  @default_max_decompressed_bytes 64 * 1024 * 1024

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
    adapter = Artifacts.impl()

    result = adapter.put(step_id, content_to_store, content_type, meta)

    # Consumer-less public integration surface (see `ALLM.Pipeline.Telemetry`);
    # `compressed_bytes` is the payload the adapter actually stored.
    Telemetry.artifact_store(
      %{bytes: original_size, compressed_bytes: byte_size(content_to_store)},
      %{adapter: adapter, outcome: store_outcome(result)}
    )

    case result do
      {:ok, url} ->
        {:ok, url, original_size, checksum}

      # With the `Tiered` adapter an oversize payload routes to the large tier
      # internally and never reaches here. A host still on a single DynamoDB
      # adapter gets the honest `:too_large` (the artifact does not fit and there
      # is no configured large tier) rather than the old fake `:s3_not_implemented`.
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec store_outcome({:ok, String.t()} | {:error, term()}) :: :ok | term()
  defp store_outcome({:ok, _url}), do: :ok
  defp store_outcome({:error, reason}), do: reason

  @doc """
  Retrieve artifact content by URL, decompressed.

  The adapter returns the payload as stored (see
  `t:ALLM.Pipeline.Artifacts.stored/0`); the gunzip happens here, because
  compression is this layer's concern.
  """
  @spec fetch(String.t()) :: fetch_result()
  def fetch(url) do
    case Artifacts.impl().fetch(url) do
      {:ok, %{content: content, compressed: true}} -> bounded_gunzip(content)
      {:ok, %{content: content}} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete artifact by URL.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(url), do: Artifacts.impl().delete(url)

  @doc """
  Check if artifact exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(url), do: Artifacts.impl().exists?(url)

  @doc """
  The decompressed-size ceiling `fetch/1` enforces, in bytes (default 64 MB).

  A memory-safety budget, overridable per environment via
  `config :allm_pipeline, ALLM.Pipeline.ArtifactStore, max_decompressed_bytes: N`.
  """
  @spec max_decompressed_bytes() :: pos_integer()
  def max_decompressed_bytes do
    Application.get_env(:allm_pipeline, __MODULE__, [])
    |> Keyword.get(:max_decompressed_bytes, @default_max_decompressed_bytes)
  end

  # Private functions

  # Streaming gunzip with a hard ceiling: `:zlib.safeInflate/2` yields bounded
  # chunks, so a decompression bomb is stopped once the accumulated inflated size
  # passes `max_decompressed_bytes/0` — the full inflated payload is never
  # allocated. Returns `{:error, :artifact_too_large}` in that case.
  @spec bounded_gunzip(binary()) :: fetch_result()
  defp bounded_gunzip(gzipped) do
    z = :zlib.open()

    try do
      # 31 = 15 (max window) + 16 (gzip header autodetect), matching `:zlib.gunzip/1`.
      :zlib.inflateInit(z, 31)
      inflate_loop(z, :zlib.safeInflate(z, gzipped), [], 0, max_decompressed_bytes())
    catch
      # Malformed/corrupt gzip stream — `:zlib` throws `:data_error`. Report it
      # rather than crashing the caller (the review UI fetches arbitrary rows).
      :error, reason -> {:error, {:inflate_failed, reason}}
    after
      :zlib.close(z)
    end
  end

  @spec inflate_loop(
          :zlib.zstream(),
          {:continue | :finished, iodata()},
          iodata(),
          non_neg_integer(),
          pos_integer()
        ) :: fetch_result()
  defp inflate_loop(z, {status, output}, acc, total, limit) do
    total = total + IO.iodata_length(output)

    cond do
      total > limit ->
        {:error, :artifact_too_large}

      status == :continue ->
        inflate_loop(z, :zlib.safeInflate(z, []), [acc, output], total, limit)

      true ->
        {:ok, IO.iodata_to_binary([acc, output])}
    end
  end

  @spec compute_checksum(binary()) :: String.t()
  defp compute_checksum(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
