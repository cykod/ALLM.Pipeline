defmodule ALLM.Pipeline.ArtifactStoreGunzipTest do
  @moduledoc """
  Pins the bounded-decompression ceiling on `ALLM.Pipeline.ArtifactStore.fetch/1`
  (Phase 7.5 security fix — an unbounded `:zlib.gunzip/1` is a decompression-bomb
  memory-exhaustion vector).

  Infra-free: uses the `Memory` adapter, so no DynamoDB/MinIO. The ceiling is
  overridden to a tiny value so the bomb fixture inflates PAST it without the
  test allocating anything near the real 64 MB budget — the fixture is
  `:zlib.gzip/1` of a 200 KB buffer (the real wire producer), which inflates well
  past the 1 KB ceiling but is trivial to hold.

  **Not `async: true`** — it rewrites `:allm_pipeline` application env (the
  adapter and the ceiling), which is global to the VM, and `Memory`'s Agent is
  process-global.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.ArtifactStore
  alias ALLM.Pipeline.Artifacts
  alias ALLM.Pipeline.Artifacts.Memory

  @ceiling 1024

  setup do
    prev_impl = Application.get_env(:allm_pipeline, Artifacts)
    prev_store = Application.get_env(:allm_pipeline, ArtifactStore)

    Application.put_env(:allm_pipeline, Artifacts, impl: Memory)
    Application.put_env(:allm_pipeline, ArtifactStore, max_decompressed_bytes: @ceiling)
    {:ok, _} = Memory.gc()

    on_exit(fn ->
      restore(Artifacts, prev_impl)
      restore(ArtifactStore, prev_store)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:allm_pipeline, key)
  defp restore(key, value), do: Application.put_env(:allm_pipeline, key, value)

  # Store an already-gzipped payload with `compressed: true`, bypassing
  # `ArtifactStore.store/4` (which would re-gzip) so the fixture is a real gzip
  # stream of a known size.
  defp put_gzipped(id, gzipped) do
    {:ok, url} =
      Memory.put(id, gzipped, "application/octet-stream", %{
        size_bytes: 0,
        checksum: "x",
        compressed: true
      })

    url
  end

  test "a gzip bomb whose inflated size exceeds the ceiling returns :artifact_too_large" do
    # 200 KB of zeros gzips to ~200 bytes but inflates to 200 KB — well past the
    # 1 KB test ceiling. Real `:zlib.gzip/1` output; nothing near the ceiling is
    # allocated at fetch time (the loop stops as soon as it crosses 1 KB).
    inflated = :binary.copy(<<0>>, 200 * 1024)
    bomb = :zlib.gzip(inflated)
    assert byte_size(bomb) < @ceiling

    url = put_gzipped("bomb", bomb)

    assert {:error, :artifact_too_large} = ArtifactStore.fetch(url)
  end

  test "a normal compressed artifact under the ceiling still round-trips" do
    content = "Amesbury City Council agenda — a small, ordinary artifact."
    url = put_gzipped("ok", :zlib.gzip(content))

    assert {:ok, ^content} = ArtifactStore.fetch(url)
  end

  test "an artifact whose inflated size sits right at the ceiling is accepted" do
    # Exactly `@ceiling` bytes inflated — the boundary is inclusive.
    inflated = :binary.copy(<<?a>>, @ceiling)
    url = put_gzipped("edge", :zlib.gzip(inflated))

    assert {:ok, ^inflated} = ArtifactStore.fetch(url)
  end
end
