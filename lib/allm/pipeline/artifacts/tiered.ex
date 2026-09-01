defmodule ALLM.Pipeline.Artifacts.Tiered do
  @moduledoc """
  A size-routing `ALLM.Pipeline.Artifacts` adapter — small artifacts go to one
  backend, large ones to another. It is what makes the tier list an adapter
  *choice* rather than a size decision hard-coded into
  `ALLM.Pipeline.ArtifactStore`.

  The canonical wiring: DynamoDB for what fits an item, S3 for what does not.

      config :allm_pipeline, ALLM.Pipeline.Artifacts,
        impl: ALLM.Pipeline.Artifacts.Tiered

      config :allm_pipeline, ALLM.Pipeline.Artifacts.Tiered,
        small: ALLM.Pipeline.Artifacts.Dynamo,
        large: ALLM.Pipeline.Artifacts.S3

  (A host declaring an `ALLM.Pipeline.Registry` writes those keys from
  `artifacts: {ALLM.Pipeline.Artifacts.Tiered, small: …, large: …}` — see that
  module's "The `artifacts:` tuple form".)

  ## The routing decision is measured on POST-ENCODE bytes — this is the §2.7 fix

  `put/4` receives the payload already gzipped by `ArtifactStore`. It routes on
  `ALLM.Pipeline.Artifacts.Dynamo.encoded_size/1` — the base64-inflated,
  as-stored size DynamoDB actually constrains — NOT the caller's raw content
  length. A 640 KB HTML scrape that gzips to 40 KB therefore stays in the small
  tier, where the old pre-encode `store/4` branch wrongly sent it to the
  (unimplemented) large tier and lost it.

  `threshold:` is the post-encode ceiling for the small tier and defaults to
  `Dynamo.max_payload_bytes/0` — the DynamoDB item capacity — so `small: Dynamo`
  with no explicit threshold routes exactly as `Dynamo.fits_item?/1` does. It is
  overridable (chiefly for tests, which want a small boundary without large
  payloads).

  ## Read dispatch

  `fetch/1` / `delete/1` / `exists?/1` route by URL, not by size. Each backing
  adapter answers a URL it does not own with a structured "not mine" error
  (`{:error, {:invalid_artifact_url, url}}` for `fetch`, `{:error, :invalid_url}`
  for `delete`, `false` for `exists?`), so this adapter tries the small tier and
  falls through to the large one on that signal — adapter-agnostic, so it works
  for any disjoint-scheme pair (`dynamo://`/`s3://` in production,
  `memory://`/`file://` in tests) without hard-coding a scheme.
  """

  @behaviour ALLM.Pipeline.Artifacts

  alias ALLM.Pipeline.Artifacts
  alias ALLM.Pipeline.Artifacts.Dynamo

  @impl true
  @spec put(Artifacts.id(), binary(), String.t(), Artifacts.meta()) ::
          {:ok, Artifacts.url()} | {:error, term()}
  def put(id, content, content_type, meta) do
    {small, large} = tiers()

    # NOTE: the routing metric is hard-coded to `Dynamo.encoded_size/1` (base64
    # inflation) and `threshold/0` defaults to DynamoDB's item capacity — correct
    # for the only shipped wiring (`small: Dynamo`), leaky for any other. A
    # non-Dynamo small tier would inherit Dynamo-shaped routing; only that
    # adapter's own `:too_large` fallback below would correct a misroute. Left
    # coupled by YAGNI (one wiring today); derive the size-measure from `small`
    # when a second small tier lands. Read dispatch (fetch/delete/exists) IS
    # adapter-agnostic — see the moduledoc.
    adapter =
      if Dynamo.encoded_size(content) <= threshold() do
        small
      else
        large
      end

    case adapter.put(id, content, content_type, meta) do
      # A payload that lands right at the small tier's own ceiling still routes
      # to large rather than being lost — the threshold is the router's estimate;
      # the adapter's own `:too_large` is authoritative.
      {:error, :too_large} when adapter == small -> large.put(id, content, content_type, meta)
      other -> other
    end
  end

  @impl true
  @spec fetch(Artifacts.url()) :: {:ok, Artifacts.stored()} | {:error, term()}
  def fetch(url) do
    {small, large} = tiers()

    case small.fetch(url) do
      {:error, {:invalid_artifact_url, ^url}} -> large.fetch(url)
      result -> result
    end
  end

  @impl true
  @spec delete(Artifacts.url()) :: :ok | {:error, term()}
  def delete(url) do
    {small, large} = tiers()

    case small.delete(url) do
      {:error, :invalid_url} -> large.delete(url)
      result -> result
    end
  end

  @impl true
  @spec exists?(Artifacts.url()) :: boolean()
  def exists?(url) do
    {small, large} = tiers()
    # Each adapter answers `false` for a URL it does not own AND for an
    # owned-but-absent one, so the OR yields the owning adapter's real verdict:
    # the non-owner short-circuits to `false` with no I/O (its fallback clause).
    small.exists?(url) or large.exists?(url)
  end

  # ── config ───────────────────────────────────────────────────────────────

  @spec tiers() :: {module(), module()}
  defp tiers do
    config = config()
    {Keyword.fetch!(config, :small), Keyword.fetch!(config, :large)}
  end

  @spec threshold() :: non_neg_integer()
  defp threshold do
    Keyword.get(config(), :threshold, Dynamo.max_payload_bytes())
  end

  @spec config() :: keyword()
  defp config, do: Application.get_env(:allm_pipeline, __MODULE__, [])
end
