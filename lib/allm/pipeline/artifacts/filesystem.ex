defmodule ALLM.Pipeline.Artifacts.Filesystem do
  @moduledoc """
  Local-disk `ALLM.Pipeline.Artifacts` adapter — the one that lets a fresh
  clone run pipelines with **zero cloud infrastructure**.

  Configure it and no DynamoDB (nor `docker-compose`) is needed for artifacts
  to store, round-trip and render in the review UI:

      config :allm_pipeline, ALLM.Pipeline.Artifacts,
        impl: ALLM.Pipeline.Artifacts.Filesystem

      config :allm_pipeline, ALLM.Pipeline.Artifacts.Filesystem,
        root: "/var/tmp/my-artifacts"

  That first key still works on a host that declares an
  `ALLM.Pipeline.Registry`: the registry's `artifacts:` supplies the DEFAULT and
  a config-file `impl:` overrides it per environment (`install/0` writes the
  seam keys with `put_new` for exactly this promise — see that module's
  "Precedence", pinned by `registry_test.exs`). Put it in `config/dev.exs` and
  the production `artifacts:` declaration is untouched.

  `:root` defaults to `allm_pipeline_artifacts` under the system temp
  directory, and is read at RUNTIME on every call.

  ## Layout and URLs

  Each artifact is two files under `:root`, named after the URL-encoded id —
  ids are not path-safe (`"<step_log_id>:llm"` is a real one), so
  `URI.encode_www_form/1` runs before anything touches the filesystem:

    * `<root>/<encoded-id>` — the payload, byte-for-byte as `put/4` received
      it. Still gzipped if `ArtifactStore` gzipped it, which is why a bare
      `cat` of a compressed artifact shows binary; `ArtifactStore.fetch/1` is
      what decompresses.
    * `<root>/<encoded-id>.meta.json` — `content_type`, `checksum`,
      `size_bytes` (the ORIGINAL, pre-gzip size), `compressed`, `stored_at`.

  A URL is `file://` plus the payload file's absolute path, so an operator
  holding a `step_logs.artifact_url` can find the bytes without this module.

  ## The sidecar is load-bearing, and is written FIRST

  `compressed` lives only in the sidecar, and `ArtifactStore.fetch/1` gunzips
  only when it says `true` — so a payload with no readable sidecar cannot be
  decoded, it can only be mis-decoded. Two consequences, both deliberate:

    * `put/4` writes the sidecar before the payload. A failed write therefore
      strands at worst an orphaned *sidecar*, which is inert — `fetch/1`
      answers `{:error, :not_found}`, `exists?/1` is `false`, and `gc/1` never
      counts it (`payload_paths/1` rejects `.meta.json`). The reverse order
      would strand a payload that `exists?` reports and `fetch/1` hands back as
      an undecompressed gzip stream inside an `{:ok, _}` tuple.
    * `fetch/1` answers `{:error, :missing_artifact_metadata}` when the sidecar
      is absent or unparseable, rather than assuming `compressed: false`. The
      bytes are still on disk for an operator to recover by hand; what this
      adapter will not do is present them as the artifact.

  ## Moving `:root` invalidates existing URLs

  `fetch/1` refuses a path outside the currently-configured `:root`
  (`{:error, :outside_artifact_root}`) — which both closes the traversal a
  path-carrying URL would otherwise open, and turns "I moved the root and old
  artifacts silently vanished" into a named error. Re-point `:root` at the old
  directory, or accept that pre-move artifacts are unreachable.

  ## No size ceiling

  `put/4` never returns `{:error, :too_large}`; a filesystem has no item limit
  to enforce. So a payload the DynamoDB adapter would refuse is written here
  without comment, and this adapter cannot exercise `ArtifactStore`'s oversize
  routing.
  """

  @behaviour ALLM.Pipeline.Artifacts

  alias ALLM.Pipeline.Artifacts

  @scheme "file://"
  @meta_suffix ".meta.json"

  @impl true
  @spec put(Artifacts.id(), binary(), String.t(), Artifacts.meta()) ::
          {:ok, Artifacts.url()} | {:error, term()}
  def put(id, content, content_type, %{
        size_bytes: size_bytes,
        checksum: checksum,
        compressed: compressed
      }) do
    path = path_for(id)

    meta =
      Jason.encode!(%{
        content_type: content_type,
        checksum: checksum,
        size_bytes: size_bytes,
        compressed: compressed,
        stored_at: DateTime.to_iso8601(DateTime.utc_now())
      })

    # Sidecar FIRST, payload second — see the moduledoc. An orphaned sidecar is
    # inert; an orphaned payload is an artifact that `exists?` and decodes
    # wrongly.
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> @meta_suffix, meta),
         :ok <- File.write(path, content) do
      {:ok, @scheme <> path}
    else
      {:error, reason} -> {:error, {:artifact_write_failed, reason}}
    end
  end

  @impl true
  @spec fetch(Artifacts.url()) :: {:ok, Artifacts.stored()} | {:error, term()}
  def fetch(@scheme <> path) do
    with :ok <- within_root(path),
         {:ok, content} <- read_payload(path),
         {:ok, meta} <- read_meta(path) do
      {:ok,
       %{
         content: content,
         content_type: meta["content_type"],
         compressed: meta["compressed"] == true,
         checksum: meta["checksum"],
         size_bytes: meta["size_bytes"]
       }}
    end
  end

  def fetch(url), do: {:error, {:invalid_artifact_url, url}}

  @impl true
  @spec delete(Artifacts.url()) :: :ok | {:error, term()}
  def delete(@scheme <> path) do
    with :ok <- within_root(path) do
      _ = File.rm(path)
      _ = File.rm(path <> @meta_suffix)
      :ok
    end
  end

  def delete(_url), do: {:error, :invalid_url}

  @impl true
  @spec exists?(Artifacts.url()) :: boolean()
  def exists?(@scheme <> path), do: within_root(path) == :ok and File.regular?(path)
  def exists?(_url), do: false

  @doc """
  Delete every artifact under `:root` last modified at or before
  `opts[:older_than]` (a `DateTime`, default: now), returning how many payloads
  went. With no options this empties the root.

  Compares filesystem mtime, whose resolution is one second — hence "at or
  before" rather than "before", so an artifact written in the same second as
  the cutoff is collected rather than surviving a full purge.

  The count is of payloads actually **removed**, not of payloads selected: a
  payload whose `File.rm/1` fails (permissions, a concurrent `gc/1` that got
  there first) is not counted.
  """
  @impl true
  @spec gc(keyword()) :: {:ok, non_neg_integer()}
  def gc(opts \\ []) do
    cutoff =
      opts
      |> Keyword.get(:older_than, DateTime.utc_now())
      |> DateTime.to_unix()

    collected =
      root()
      |> payload_paths()
      |> Enum.filter(&expired?(&1, cutoff))
      |> Enum.count(&delete_artifact_files/1)

    {:ok, collected}
  end

  @doc """
  The directory artifacts are written under, resolved at runtime.

  Public so an operator (or a test's teardown) can find the tree without
  re-deriving the default.
  """
  @spec root() :: Path.t()
  def root do
    Application.get_env(:allm_pipeline, __MODULE__, [])
    |> Keyword.get(:root, Path.join(System.tmp_dir!(), "allm_pipeline_artifacts"))
  end

  @spec path_for(Artifacts.id()) :: Path.t()
  defp path_for(id), do: Path.join(root(), URI.encode_www_form(id))

  @spec expired?(Path.t(), integer()) :: boolean()
  defp expired?(path, cutoff) do
    match?({:ok, %{mtime: mtime}} when mtime <= cutoff, File.stat(path, time: :posix))
  end

  # Removes a payload and its sidecar, reporting whether the PAYLOAD went. An
  # already-absent sidecar is not a failure (`gc/1` may be racing another), but
  # a payload that survives must not be counted as collected — which it was
  # while the deletions lived inside `Enum.count/2`'s predicate and discarded
  # `File.rm/1`'s result.
  @spec delete_artifact_files(Path.t()) :: boolean()
  defp delete_artifact_files(path) do
    removed? = File.rm(path) == :ok
    _ = File.rm(path <> @meta_suffix)
    removed?
  end

  # Payloads only — the sidecars share the directory and must not be collected
  # as artifacts in their own right (each is removed with its payload).
  @spec payload_paths(Path.t()) :: [Path.t()]
  defp payload_paths(root) do
    root
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, @meta_suffix))
  end

  @spec within_root(Path.t()) :: :ok | {:error, :outside_artifact_root}
  defp within_root(path) do
    expanded = Path.expand(path)
    root = Path.expand(root())

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      :ok
    else
      {:error, :outside_artifact_root}
    end
  end

  @spec read_payload(Path.t()) :: {:ok, binary()} | {:error, :not_found}
  defp read_payload(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # A payload with no readable sidecar is a NAMED failure, not a degraded
  # success. Falling back to `%{}` yields `compressed: false`, so
  # `ArtifactStore.fetch/1` skips the gunzip and returns the raw gzip stream in
  # an `{:ok, _}` tuple — silent, plausible-looking corruption, which is
  # strictly worse than the `:not_found` such a fallback is usually defended
  # as avoiding. Sniffing gzip's two magic bytes to recover the flag is not
  # sound either: a `compress: false` payload may legitimately BE gzip.
  #
  # `put/4` writes the sidecar first, so a partial write cannot reach this
  # state; reaching it means the sidecar was removed or corrupted out of band,
  # and the payload is still on disk to be recovered by hand.
  @spec read_meta(Path.t()) :: {:ok, map()} | {:error, :missing_artifact_metadata}
  defp read_meta(path) do
    with {:ok, json} <- File.read(path <> @meta_suffix),
         {:ok, meta} <- Jason.decode(json) do
      {:ok, meta}
    else
      _ -> {:error, :missing_artifact_metadata}
    end
  end
end
