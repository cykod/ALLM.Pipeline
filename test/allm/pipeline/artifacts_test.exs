defmodule ALLM.Pipeline.ArtifactsTest do
  @moduledoc """
  Pins the `ALLM.Pipeline.Artifacts` behaviour and its two infra-free adapters
  (`Memory`, `Filesystem`) through the real wrapper, `ArtifactStore`.

  Three things are under test, and the third is the one worth naming:

    1. **The optional callback.** `gc/1` is the one callback an adapter may
       skip, and which two of the three provide. Membership and
       mandatory-callback conformance for the SET of adapters is **not** here —
       it is pinned once, for every seam, in `behaviours_test.exs`, which
       also discovers adapters the list forgets.
    2. **Round-trip** through `ArtifactStore` for both adapters.
    3. **The compression boundary.** `ArtifactStore` owns gzip; the adapter
       stores opaque bytes. A bare "store then fetch returns the original"
       assertion passes identically whether compression happens or not — so
       these tests reach into the ADAPTER and assert it is holding bytes that
       differ from the caller's and gunzip back to them. That difference is the
       observable a broken boundary would destroy.

  **Not `async: true`** — every test here rewrites `:amesbury_scraper`
  application env (the configured adapter, the filesystem root), which is
  global to the VM, and `Memory`'s Agent is process-global too.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.ArtifactStore
  alias ALLM.Pipeline.Artifacts
  alias ALLM.Pipeline.Artifacts.{Dynamo, Filesystem, Memory}

  @adapters [Dynamo, Filesystem, Memory]

  setup do
    original = Application.get_env(:amesbury_scraper, Artifacts)
    original_fs = Application.get_env(:amesbury_scraper, Filesystem)

    on_exit(fn ->
      restore(Artifacts, original)
      restore(Filesystem, original_fs)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:amesbury_scraper, key)
  defp restore(key, value), do: Application.put_env(:amesbury_scraper, key, value)

  defp use_adapter(module) do
    Application.put_env(:amesbury_scraper, Artifacts, impl: module)
  end

  defp use_memory do
    use_adapter(Memory)
    {:ok, _} = Memory.gc()
    :ok
  end

  defp use_filesystem do
    root =
      Path.join(System.tmp_dir!(), "allm-artifacts-test-#{System.unique_integer([:positive])}")

    use_adapter(Filesystem)
    Application.put_env(:amesbury_scraper, Filesystem, root: root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  # `@behaviour` declaration and mandatory-callback conformance for all three
  # adapters is pinned once, for every seam, in `behaviours_test.exs`.
  describe "a URL an adapter does not own" do
    # One rule, three implementations — so pin the SET rather than the
    # instances. `Dynamo` used to satisfy this in one shape and violate it in
    # another: its catch-all clause answered correctly, while a `dynamo://`
    # URL with no `/` raised a `MatchError` out of `String.split/3` — in
    # exactly the case the behaviour's callback docs single out. Nothing here
    # contacts a backend: every one of these short-circuits before the request.
    @not_mine [
      "invalid://url",
      "dynamo://noslash",
      "memory-ish://x",
      "file:/single-slash",
      ""
    ]

    test "is a structured fetch/1 error from every adapter, never a raise" do
      for adapter <- @adapters, url <- @not_mine do
        assert {:error, {:invalid_artifact_url, ^url}} = adapter.fetch(url),
               "#{inspect(adapter)}.fetch/1 did not reject #{inspect(url)} cleanly"
      end
    end

    test "is {:error, :invalid_url} from every adapter's delete/1, never a raise" do
      for adapter <- @adapters, url <- @not_mine do
        assert {:error, :invalid_url} = adapter.delete(url),
               "#{inspect(adapter)}.delete/1 did not reject #{inspect(url)} cleanly"
      end
    end

    test "is false from every adapter's exists?/1, never a raise" do
      for adapter <- @adapters, url <- @not_mine do
        refute adapter.exists?(url),
               "#{inspect(adapter)}.exists?/1 did not answer false for #{inspect(url)}"
      end
    end
  end

  describe "gc/1 is the optional callback" do
    test "and only the two infra-free adapters provide it" do
      for adapter <- @adapters, do: Code.ensure_loaded!(adapter)

      assert {:gc, 1} in ALLM.Pipeline.Artifacts.behaviour_info(:optional_callbacks)

      assert function_exported?(Memory, :gc, 1)
      assert function_exported?(Filesystem, :gc, 1)
      # Dynamo deliberately does not: its lifecycle is the table's, via
      # `clear_table/0`. Retention/TTL is the Phase 7 item.
      refute function_exported?(Dynamo, :gc, 1)
    end
  end

  describe "ArtifactStore over Artifacts.Memory" do
    setup do: use_memory()

    test "stores, and reports the ORIGINAL size and checksum" do
      content = String.duplicate("Amesbury City Council ", 200)
      id = Ecto.UUID.generate()

      assert {:ok, url, size, checksum} = ArtifactStore.store(id, content, "text/plain")

      assert url == "memory://#{id}"
      assert size == byte_size(content)
      assert checksum == :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    end

    test "the wrapper compresses and the adapter holds the compressed bytes" do
      content = String.duplicate("Amesbury City Council ", 500)
      id = Ecto.UUID.generate()

      {:ok, url, _size, _checksum} = ArtifactStore.store(id, content, "text/plain")

      # The discriminating observable: what the ADAPTER holds is NOT what the
      # caller passed, and gunzips back to it.
      assert {:ok, stored} = Memory.fetch(url)
      assert stored.compressed
      assert stored.content != content
      assert byte_size(stored.content) < byte_size(content)
      assert :zlib.gunzip(stored.content) == content

      # ...and the wrapper hides all of that.
      assert {:ok, ^content} = ArtifactStore.fetch(url)
    end

    test "compress: false stores the caller's bytes verbatim" do
      content = "small"
      id = Ecto.UUID.generate()

      {:ok, url, _size, _checksum} =
        ArtifactStore.store(id, content, "text/plain", compress: false)

      assert {:ok, stored} = Memory.fetch(url)
      refute stored.compressed
      assert stored.content == content
      assert {:ok, ^content} = ArtifactStore.fetch(url)
    end

    test "exists?/1 and delete/1 round-trip" do
      id = Ecto.UUID.generate()
      {:ok, url, _, _} = ArtifactStore.store(id, "body", "text/plain")

      assert ArtifactStore.exists?(url)
      assert :ok = ArtifactStore.delete(url)
      refute ArtifactStore.exists?(url)
      assert {:error, :not_found} = ArtifactStore.fetch(url)
    end

    test "a URL the adapter does not own is rejected, not raised" do
      assert {:error, {:invalid_artifact_url, "invalid://url"}} =
               ArtifactStore.fetch("invalid://url")

      assert {:error, :invalid_url} = ArtifactStore.delete("invalid://url")
      refute ArtifactStore.exists?("invalid://url")
    end

    test "gc/1 empties the store" do
      {:ok, url, _, _} = ArtifactStore.store(Ecto.UUID.generate(), "body", "text/plain")
      assert ArtifactStore.exists?(url)

      assert {:ok, n} = Memory.gc()
      assert n >= 1
      refute ArtifactStore.exists?(url)
    end

    test "gc/1 keeps artifacts newer than the cutoff" do
      cutoff = DateTime.utc_now()
      # Stored strictly after the cutoff, so it must survive.
      {:ok, url, _, _} = ArtifactStore.store(Ecto.UUID.generate(), "body", "text/plain")

      assert {:ok, 0} = Memory.gc(older_than: cutoff)
      assert ArtifactStore.exists?(url)
    end
  end

  describe "ArtifactStore over Artifacts.Filesystem" do
    setup do
      root = use_filesystem()
      {:ok, root: root}
    end

    test "writes the payload and a metadata sidecar under the configured root", %{root: root} do
      content = String.duplicate("<div>meeting</div>", 100)
      id = Ecto.UUID.generate()

      assert {:ok, url, size, checksum} = ArtifactStore.store(id, content, "text/html")

      assert "file://" <> path = url
      assert Path.dirname(path) == root
      assert File.regular?(path)
      assert File.regular?(path <> ".meta.json")

      meta = path |> Kernel.<>(".meta.json") |> File.read!() |> Jason.decode!()
      assert meta["content_type"] == "text/html"
      assert meta["checksum"] == checksum
      assert meta["size_bytes"] == size
      assert meta["compressed"] == true

      # Same compression boundary as the Memory case: the bytes ON DISK are the
      # gzipped ones, and the wrapper is what makes them readable again.
      on_disk = File.read!(path)
      assert on_disk != content
      assert :zlib.gunzip(on_disk) == content
      assert {:ok, ^content} = ArtifactStore.fetch(url)
    end

    test "an id that is not path-safe is encoded rather than nesting a directory", %{root: root} do
      step_id = Ecto.UUID.generate()

      # `"<step_log_id>:llm"` is the real key `Executor.drain_and_store_llm/2`
      # uses for the per-step LLM envelope.
      assert {:ok, "file://" <> path, _, _} =
               ArtifactStore.store("#{step_id}:llm", "{}", "application/json")

      assert Path.dirname(path) == root
      refute String.contains?(Path.basename(path), ":")
      assert {:ok, "{}"} = ArtifactStore.fetch("file://" <> path)
    end

    test "exists?/1 and delete/1 round-trip, and delete removes the sidecar too" do
      {:ok, url, _, _} = ArtifactStore.store(Ecto.UUID.generate(), "body", "text/plain")
      "file://" <> path = url

      assert ArtifactStore.exists?(url)
      assert :ok = ArtifactStore.delete(url)
      refute ArtifactStore.exists?(url)
      refute File.exists?(path)
      refute File.exists?(path <> ".meta.json")
    end

    test "a path outside the configured root is refused" do
      assert {:error, :outside_artifact_root} = ArtifactStore.fetch("file:///etc/passwd")
      assert {:error, :outside_artifact_root} = ArtifactStore.delete("file:///etc/passwd")
      refute ArtifactStore.exists?("file:///etc/passwd")
    end

    test "gc/1 empties the root without collecting sidecars as artifacts", %{root: root} do
      for _ <- 1..3, do: ArtifactStore.store(Ecto.UUID.generate(), "body", "text/plain")

      assert length(Path.wildcard(Path.join(root, "*"))) == 6

      # 3, not 6: the sidecars go with their payloads, not as artifacts of
      # their own.
      assert {:ok, 3} = Filesystem.gc()
      assert Path.wildcard(Path.join(root, "*")) == []
    end

    test "gc/1 counts payloads REMOVED, not payloads selected", %{root: root} do
      {:ok, _url, _, _} = ArtifactStore.store(Ecto.UUID.generate(), "body", "text/plain")

      # An entry `File.rm/1` refuses. `Path.wildcard` returns it, `File.stat`
      # ages it, so it is selected — and every deletion attempt fails. While
      # `gc/1`'s deletions lived inside `Enum.count/2`'s predicate they were
      # `_ = File.rm(path)`, so this was counted as collected and `{:ok, n}`
      # overstated by one against a directory that is still there.
      undeletable = Path.join(root, "not-a-payload-dir")
      File.mkdir_p!(Path.join(undeletable, "occupied"))

      assert {:ok, 1} = Filesystem.gc()

      assert File.dir?(undeletable)
    end

    test "gc/1 collects only what is older than the cutoff, sidecar and all", %{root: root} do
      {:ok, old_url, _, _} = ArtifactStore.store(Ecto.UUID.generate(), "stale", "text/plain")
      {:ok, fresh_url, _, _} = ArtifactStore.store(Ecto.UUID.generate(), "fresh", "text/plain")

      "file://" <> old_path = old_url

      # mtime resolution is one second, so backdate rather than sleep. The
      # sidecar is backdated with its payload — they are one artifact.
      backdated = DateTime.to_unix(~U[2020-01-01 00:00:00Z])
      :ok = File.touch(old_path, backdated)
      :ok = File.touch(old_path <> ".meta.json", backdated)

      assert {:ok, 1} = Filesystem.gc(older_than: ~U[2021-01-01 00:00:00Z])

      refute File.exists?(old_path)
      refute File.exists?(old_path <> ".meta.json")

      # The survivor keeps BOTH its files. Losing the sidecar alone would cost
      # the `compressed` flag, which is why `fetch/1` refuses rather than
      # guesses — pinned by "a payload whose sidecar is gone is a named error"
      # below.
      assert ArtifactStore.exists?(fresh_url)
      assert {:ok, "fresh"} = ArtifactStore.fetch(fresh_url)
      assert length(Path.wildcard(Path.join(root, "*"))) == 2
    end

    test "a missing artifact is :not_found, and a bad URL is rejected" do
      assert {:error, :not_found} =
               ArtifactStore.fetch("file://" <> Path.join(Filesystem.root(), "nope"))

      assert {:error, {:invalid_artifact_url, "invalid://url"}} =
               ArtifactStore.fetch("invalid://url")
    end

    test "a payload whose sidecar is gone is a named error, not gzip bytes in an {:ok, _}" do
      content = String.duplicate("<p>Amesbury</p>\n", 200)
      {:ok, url, _, _} = ArtifactStore.store(Ecto.UUID.generate(), content, "text/html")
      "file://" <> path = url

      assert {:ok, ^content} = ArtifactStore.fetch(url)

      File.rm!(path <> ".meta.json")

      # `compressed` lives ONLY in the sidecar. Degrading its loss to `%{}`
      # yields `compressed: false`, so the wrapper skips the gunzip and hands
      # back the raw gzip stream inside an `{:ok, _}` — the discriminating
      # observable here is the ERROR, because a plain `refute {:ok, ^content}`
      # passes for a corrupt success too.
      assert {:error, :missing_artifact_metadata} = ArtifactStore.fetch(url)

      # The bytes are still on disk to be recovered by hand; refusing to decode
      # them is not the same as losing them.
      assert :zlib.gunzip(File.read!(path)) == content
    end

    test "a put/4 that cannot write its sidecar strands no payload", %{root: root} do
      id = Ecto.UUID.generate()

      # A directory where the sidecar belongs makes `File.write/2` fail
      # `:eisdir` — a real partial write, not a mocked one.
      payload_path = Path.join(root, id)
      File.mkdir_p!(payload_path <> ".meta.json")

      assert {:error, {:artifact_write_failed, :eisdir}} =
               ArtifactStore.store(id, "body", "text/plain")

      # The ordering IS the fix: with the payload written first, this file would
      # exist, `exists?/1` would report it and `fetch/1` would return its
      # undecodable bytes.
      refute File.exists?(payload_path)
      refute ArtifactStore.exists?("file://" <> payload_path)
    end

    test "a traversal-shaped id is encoded into a single segment under the root", %{root: root} do
      # `path_for/1`'s safety rests entirely on `URI.encode_www_form/1` refusing
      # to emit a path separator — a moduledoc sentence about a stdlib function,
      # with nothing pinning it. Swap in a laxer encoder and the traversal opens
      # silently, so observe the property rather than the sentence.
      assert {:ok, "file://" <> path, _, _} =
               ArtifactStore.store("../../etc/passwd", "body", "text/plain")

      assert Path.dirname(path) == root
      assert Path.expand(path) == Path.join(root, Path.basename(path))
      refute String.contains?(Path.basename(path), "/")
      assert {:ok, "body"} = ArtifactStore.fetch("file://" <> path)

      # Exactly two files, both direct children of the root: the payload and its
      # sidecar. Nothing nested, nothing escaped. (`match_dot: true` because
      # this id encodes to a leading `.` — real ids are UUIDs, so `gc/1`'s
      # dot-blind `Path.wildcard` is not affected.)
      assert length(Path.wildcard(Path.join(root, "*"), match_dot: true)) == 2
    end
  end

  describe "the S3 tier is still the wrapper's, and still unimplemented" do
    setup do: use_memory()

    test "an s3:// URL never reaches the configured adapter" do
      assert {:error, :s3_not_implemented} = ArtifactStore.fetch("s3://bucket/key")
      assert {:error, :s3_not_implemented} = ArtifactStore.delete("s3://bucket/key")
      refute ArtifactStore.exists?("s3://bucket/key")
    end

    test "all three read/write arms answer the unbuilt tier with ONE atom" do
      # `delete/1` answered `:not_implemented` through Phase 1 — the only
      # occurrence of that atom in the repo, for the identical condition its
      # two siblings 30 lines away call `:s3_not_implemented`. Asserted as a
      # SET so a fourth `s3://` arm cannot reintroduce a third spelling.
      answers =
        MapSet.new([
          ArtifactStore.fetch("s3://bucket/key"),
          ArtifactStore.delete("s3://bucket/key")
        ])

      assert MapSet.to_list(answers) == [{:error, :s3_not_implemented}]
    end
  end
end
