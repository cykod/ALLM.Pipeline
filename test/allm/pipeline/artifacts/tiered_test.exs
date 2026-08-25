defmodule ALLM.Pipeline.Artifacts.TieredTest do
  @moduledoc """
  Pins `ALLM.Pipeline.Artifacts.Tiered` — the size-routing adapter (Phase 7.5).

  Infra-free: wired as `small: Memory, large: Filesystem` so the two tiers have
  distinct, observable URL schemes (`memory://` / `file://`) and neither needs
  DynamoDB or S3. The production wiring is `small: Dynamo, large: S3`; the
  routing logic is identical.

  The load-bearing test is the **§2.7 discriminator**: the threshold is measured
  on the POST-encode (gzipped, base64-inflated) size, not the raw content length,
  so a large-but-compressible payload lands in the SMALL tier. A mutant measuring
  raw bytes sends it to the large tier and fails.

  **Not `async: true`** — rewrites `:amesbury_scraper` application env, global to
  the VM, and `Memory`'s Agent is process-global.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.ArtifactStore
  alias ALLM.Pipeline.Artifacts
  alias ALLM.Pipeline.Artifacts.{Filesystem, Memory, Tiered}

  # Post-encode ceiling for the small tier. Small enough that an incompressible
  # payload of a few KB crosses it, large enough that a compressible 100 KB one
  # (which gzips to a few hundred bytes) does not.
  @threshold 5_000

  setup do
    prev_impl = Application.get_env(:amesbury_scraper, Artifacts)
    prev_tiered = Application.get_env(:amesbury_scraper, Tiered)
    prev_fs = Application.get_env(:amesbury_scraper, Filesystem)

    root =
      Path.join(System.tmp_dir!(), "allm-tiered-test-#{System.unique_integer([:positive])}")

    Application.put_env(:amesbury_scraper, Artifacts, impl: Tiered)

    Application.put_env(:amesbury_scraper, Tiered,
      small: Memory,
      large: Filesystem,
      threshold: @threshold
    )

    Application.put_env(:amesbury_scraper, Filesystem, root: root)
    {:ok, _} = Memory.gc()

    on_exit(fn ->
      restore(Artifacts, prev_impl)
      restore(Tiered, prev_tiered)
      restore(Filesystem, prev_fs)
      File.rm_rf(root)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:amesbury_scraper, key)
  defp restore(key, value), do: Application.put_env(:amesbury_scraper, key, value)

  describe "put/4 routes by post-encode size" do
    test "a payload whose stored size is under the threshold goes to the small tier" do
      content = "a small artifact"

      assert {:ok, url, _size, _checksum} = ArtifactStore.store("small-id", content, "text/plain")
      assert String.starts_with?(url, "memory://")
      assert {:ok, ^content} = ArtifactStore.fetch(url)
    end

    test "a payload whose stored size exceeds the threshold goes to the large tier" do
      # Incompressible: gzip does not shrink it and base64 inflates it, so the
      # stored size clears the 5 KB threshold.
      content = :crypto.strong_rand_bytes(10_000)

      assert {:ok, url, _size, _checksum} =
               ArtifactStore.store("large-id", content, "application/octet-stream")

      assert String.starts_with?(url, "file://")
      assert {:ok, ^content} = ArtifactStore.fetch(url)
    end

    test "§2.7: a LARGE-raw but highly-compressible payload lands in the SMALL tier" do
      # 100 KB raw — far over the 5 KB threshold if measured on RAW bytes — but it
      # gzips to a few hundred bytes, so its POST-encode size is tiny. The whole
      # point of Tiered: this stays in DynamoDB (here, Memory), where the old
      # pre-encode router wrongly sent it large and lost it. A mutant measuring
      # raw bytes routes it to `file://` and fails this assertion.
      content = String.duplicate("Amesbury City Council ", 5_000)
      assert byte_size(content) > @threshold

      assert {:ok, url, size, _checksum} =
               ArtifactStore.store("compressible", content, "text/plain")

      assert String.starts_with?(url, "memory://")
      # size_bytes still reports the ORIGINAL uncompressed size.
      assert size == byte_size(content)
      assert {:ok, ^content} = ArtifactStore.fetch(url)
    end
  end

  describe "fetch/delete/exists? dispatch by scheme" do
    test "each read routes to the owning tier" do
      {:ok, small_url, _, _} = ArtifactStore.store("s", "small", "text/plain")

      {:ok, large_url, _, _} =
        ArtifactStore.store("l", :crypto.strong_rand_bytes(10_000), "application/octet-stream")

      assert String.starts_with?(small_url, "memory://")
      assert String.starts_with?(large_url, "file://")

      assert ArtifactStore.exists?(small_url)
      assert ArtifactStore.exists?(large_url)

      assert :ok = ArtifactStore.delete(small_url)
      refute ArtifactStore.exists?(small_url)
      # Deleting the small one leaves the large one untouched.
      assert ArtifactStore.exists?(large_url)

      assert :ok = ArtifactStore.delete(large_url)
      refute ArtifactStore.exists?(large_url)
    end
  end
end
