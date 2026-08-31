defmodule ALLM.Pipeline.Artifacts do
  @moduledoc """
  Storage behaviour for pipeline artifacts — the heavy bodies a `step_logs` row
  deliberately does not carry (scraped HTML, extracted PDF text, decision JSON,
  the per-step LLM-call envelope).

  ## The wrapper owns the bytes; the adapter owns the backend

  `ALLM.Pipeline.ArtifactStore` is the shared wrapper and the only thing that
  should call an adapter's `put/4` / `fetch/1`. It owns **compression, checksum
  and size accounting**: it gzips (unless `compress: false`), computes the
  SHA-256 of the ORIGINAL bytes, records the ORIGINAL size, and gunzips on the
  way back out. An adapter receives an opaque, already-encoded payload plus a
  `t:meta/0` describing it, and stores both verbatim.

  Calling an adapter directly bypasses all of that — the artifact is stored
  uncompressed with no checksum and `ArtifactStore.fetch/1` will hand back the
  raw bytes. Go through the wrapper.

  ## What stays in the adapter

  "Does this payload fit me?" is the adapter's question, not the wrapper's.
  DynamoDB has a 400KB item ceiling and stores the body base64-encoded, so its
  admissible size is a function of both; S3 and the filesystem have no
  comparable limit. An adapter that cannot take a payload returns
  `{:error, :too_large}` and the wrapper routes to the next tier. See
  `ALLM.Pipeline.Artifacts.Dynamo.fits_item?/1`.

  ## Configuration

  The adapter is chosen by an explicit config key on this module, defaulting to
  `ALLM.Pipeline.Artifacts.Dynamo`:

      config :allm_pipeline, ALLM.Pipeline.Artifacts,
        impl: ALLM.Pipeline.Artifacts.Filesystem

  Resolved at RUNTIME (`impl/0`), like every other config read in this package
  — see `ALLM.Pipeline.Config`. Batch 1.C moved *which module* onto a
  compile-time host registry (`ALLM.Pipeline.Registry`), so for a host that
  declares one the `artifacts:` declaration supplies this key's default and the
  config form above overrides it per environment (see that module's
  "Precedence"). Adapters keep resolving their own values (table names, roots,
  buckets) at runtime regardless.

  ## Adapters

  | Adapter | URL scheme | Notes |
  |---|---|---|
  | `ALLM.Pipeline.Artifacts.Dynamo` | `dynamo://` | fits a 400KB item; the small tier |
  | `ALLM.Pipeline.Artifacts.S3` | `s3://` | the large tier — oversize bodies (Phase 7.5); optional `ex_aws_s3` dep |
  | `ALLM.Pipeline.Artifacts.Tiered` | routes by size | the production default: `{small: Dynamo, large: S3}` |
  | `ALLM.Pipeline.Artifacts.Filesystem` | `file://` | a fresh clone runs pipelines with zero cloud infra |
  | `ALLM.Pipeline.Artifacts.Memory` | `memory://` | tests; dies with the VM |

  Since Phase 7.5 `Tiered` gives an oversize artifact a real home (S3), so the
  wrapper no longer discards it and `Executor.build_envelope/3` no longer drops
  bodies to fit a DynamoDB item — it applies only a single pathological-size
  sanity bound.
  """

  @typedoc """
  The artifact's identity, and the last segment of the URL it is stored under.

  In practice a `step_logs.id`, or `"<step_logs.id>:llm"` for the per-step
  LLM-call envelope. An adapter that maps this onto a filesystem path or an
  object key must encode it — it is not guaranteed path-safe.
  """
  @type id :: String.t()

  @typedoc "A stored artifact's location, e.g. `dynamo://<table>/<id>`. Persisted in `step_logs.artifact_url`."
  @type url :: String.t()

  @typedoc """
  What the wrapper knows about the payload it is handing over.

  `:size_bytes` and `:checksum` describe the caller's ORIGINAL content, not the
  (possibly gzipped) bytes in `content` — `:compressed` says which of the two
  the adapter is holding. An adapter stores all three so `fetch/1` can return
  them, and so an operator inspecting the backend directly can tell what they
  are looking at.
  """
  @type meta :: %{
          size_bytes: non_neg_integer(),
          checksum: String.t(),
          compressed: boolean()
        }

  @typedoc """
  A fetched artifact, as the adapter holds it.

  `:content` is the payload exactly as `put/4` received it, so the wrapper —
  which owns compression — decides whether to gunzip based on `:compressed`.
  Adapters MAY carry extra keys (`Dynamo` returns its `:artifact_id` and
  `:created_at`); consumers must not depend on them.
  """
  @type stored :: %{
          required(:content) => binary(),
          required(:compressed) => boolean(),
          optional(:content_type) => String.t() | nil,
          optional(:checksum) => String.t() | nil,
          optional(:size_bytes) => non_neg_integer() | nil,
          optional(atom()) => term()
        }

  @doc """
  Store `content` under `id` and return the URL it can be fetched by.

  `content` is already encoded by the wrapper (see the moduledoc) — store it
  verbatim. Return `{:error, :too_large}`, without contacting the backend, when
  the payload cannot fit; the wrapper treats that as "try the next tier" rather
  than as a failure.
  """
  @callback put(id(), binary(), content_type :: String.t(), meta()) ::
              {:ok, url()} | {:error, :too_large} | {:error, term()}

  @doc """
  Retrieve the artifact at `url`, as stored.

  Must NOT decompress — the wrapper owns that. A URL this adapter does not
  recognize returns `{:error, {:invalid_artifact_url, url}}`; a well-formed URL
  with nothing behind it returns `{:error, :not_found}`.
  """
  @callback fetch(url()) :: {:ok, stored()} | {:error, term()}

  @doc "Delete the artifact at `url`. A URL this adapter does not recognize returns `{:error, :invalid_url}`."
  @callback delete(url()) :: :ok | {:error, term()}

  @doc """
  Whether an artifact exists at `url`.

  Any unrecognized or absent URL is `false`, never a raise. A *backend* failure
  is a different question and is adapter-defined: `ALLM.Pipeline.Artifacts.Dynamo.exists?/1`
  deliberately raises on a transport error rather than answering `false`,
  because `exists?` cannot say "I could not tell" and reporting a reachable
  artifact as absent whenever DynamoDB blinks is the worse lie. Do not read
  `false` as "definitely not there" without knowing the adapter.
  """
  @callback exists?(url()) :: boolean()

  @doc """
  Drop artifacts older than `opts[:older_than]` (a `DateTime`, default now),
  returning how many were removed.

  **Optional**, and no Phase 1 caller dispatches to it — retention/TTL is the
  Phase 7 item (extraction plan §3.6). `Memory` and `Filesystem` implement it
  because it is also their natural reset hook; `Dynamo` does not (its lifecycle
  is the table's, via `clear_table/0`).
  """
  @callback gc(opts :: keyword()) :: {:ok, non_neg_integer()} | {:error, term()}

  @optional_callbacks gc: 1

  @doc """
  The currently-configured artifact adapter (default
  `ALLM.Pipeline.Artifacts.Dynamo`).

  Deliberately the ONLY function on this module: `ArtifactStore` is the wrapper
  and the single front door, so mirroring `put/4` and friends here would give
  the package two entry points where one of them skips compression and
  checksumming. Compare `ALLM.Pipeline.Lock`, which DOES carry a `with_lock/2`
  dispatcher — there the behaviour is the whole contract and there is no
  wrapper above it.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:allm_pipeline, __MODULE__, [])
    |> Keyword.get(:impl, ALLM.Pipeline.Artifacts.Dynamo)
  end
end
