defmodule ALLM.Pipeline.ArtifactStoreTest do
  @moduledoc """
  Pins `ALLM.Pipeline.ArtifactStore` against the real local DynamoDB.

  ## Why there is no `DynamoCase` here

  Moved from `apps/amesbury_scraper/test/` in batch 1.D, where it was
  `use AmesburyScraper.DynamoCase`. **That template did not move with it**: six
  other host test files (in the Amesbury umbrella repo) still `use` it —

      # Anchored to the DECLARATION form, not the bare name: a substring grep now
      # also matches this moduledoc, §5.5, the host `test_helper.exs`'s prose and
      # any gitignored `erl_crash.dump` (root CLAUDE.md — "anchor every grep-count
      # criterion to a structural form, never a bare substring"). Re-derived
      # 2026-08-14 by 1.D's fix pass, which deleted `dynamo_available?/0` and so
      # removed `test_helper.exs` from the old eight-path list.
      $ grep -rlan "^ *use AmesburyScraper.DynamoCase" apps/*/test --include='*.exs'
      apps/amesbury_scraper/test/amesbury_scraper/motion_relink_reconciler_test.exs
      apps/amesbury_scraper/test/amesbury_scraper/pipeline/executor_llm_artifact_test.exs
      apps/amesbury_scraper/test/amesbury_scraper/pipelines/video_pipeline_test.exs
      apps/amesbury_scraper/test/amesbury_scraper/pipelines/weekly_digest_pipeline_test.exs
      apps/amesbury_scraper/test/integration/committee_pipeline_test.exs
      apps/amesbury_scraper/test/integration/ordinance_pipeline_test.exs

  — so moving it would have broken six files, and *copying* it would create a
  hand-mirrored case template with no shared source of truth. This file needs
  only two of its three jobs (create the table, clear it) and **none** of the
  Ecto sandbox: nothing here touches Postgres. So the setup is inlined below.

  The `:dynamo` / `:skip_unless_dynamo` exclusion those tags rely on is computed
  by this package's own `test/test_helper.exs` — from
  `ALLM.Pipeline.Artifacts.Dynamo.exclusions/0`, which the HOST's `test_helper.exs`
  calls too, so the probe, the message and the tag list have one implementation
  rather than two (`DynamoCase.dynamo_available?/0`, whose only caller that was,
  is gone).
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.ArtifactStore
  alias ALLM.Pipeline.Artifacts
  alias ALLM.Pipeline.Artifacts.Dynamo

  @moduletag :dynamo

  setup do
    # Pin the DynamoDB adapter directly. The boot default is now
    # `Artifacts.Tiered` (Phase 7.5), which routes oversize payloads to S3
    # instead of refusing them — but this file tests the wrapper against
    # DynamoDB specifically, where an oversize payload's honest answer is
    # `{:error, :too_large}` (no large tier). `Tiered`'s size routing has its own
    # test (`artifacts/tiered_test.exs`).
    previous = Application.get_env(:allm_pipeline, Artifacts)
    Application.put_env(:allm_pipeline, Artifacts, impl: Dynamo)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:allm_pipeline, Artifacts, previous),
        else: Application.delete_env(:allm_pipeline, Artifacts)
    end)

    case Dynamo.create_table() do
      :ok -> :ok
      {:error, {"ResourceInUseException", _}} -> :ok
    end

    Dynamo.clear_table()
    :ok
  end

  describe "store/4" do
    @tag :skip_unless_dynamo
    test "stores text artifact in DynamoDB and returns URL" do
      step_id = Ecto.UUID.generate()
      content = "<html><body>Test content</body></html>"

      result = ArtifactStore.store(step_id, content, "text/html")

      assert {:ok, url, size, checksum} = result
      assert String.starts_with?(url, "dynamo://")
      assert size == byte_size(content)
      assert String.length(checksum) == 64
    end

    @tag :skip_unless_dynamo
    test "stores JSON artifact in DynamoDB and returns URL" do
      step_id = Ecto.UUID.generate()
      content = Jason.encode!(%{name: "Test", value: 123})

      result = ArtifactStore.store(step_id, content, "application/json")

      assert {:ok, url, _size, _checksum} = result
      assert String.contains?(url, step_id)
    end

    @tag :skip_unless_dynamo
    test "compresses artifact content with gzip by default" do
      step_id = Ecto.UUID.generate()
      content = String.duplicate("Hello World! ", 1000)

      {:ok, _url, _size, _checksum} = ArtifactStore.store(step_id, content, "text/plain")

      # Verify the stored content is compressed
      {:ok, artifact} = Dynamo.get_artifact(step_id)
      assert artifact.compressed == true

      # The stored content should be smaller than original due to compression
      assert byte_size(artifact.content) < byte_size(content)
    end

    @tag :skip_unless_dynamo
    test "can store without compression" do
      step_id = Ecto.UUID.generate()
      content = "Small content"

      {:ok, _url, _size, _checksum} =
        ArtifactStore.store(step_id, content, "text/plain", compress: false)

      {:ok, artifact} = Dynamo.get_artifact(step_id)
      assert artifact.compressed == false
      assert artifact.content == content
    end

    @tag :skip_unless_dynamo
    test "computes SHA-256 checksum" do
      step_id = Ecto.UUID.generate()
      content = "Test content for checksum"

      expected_checksum =
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)

      {:ok, _url, _size, checksum} = ArtifactStore.store(step_id, content, "text/plain")

      assert checksum == expected_checksum
    end

    @tag :skip_unless_dynamo
    test "returns size_bytes of original content" do
      step_id = Ecto.UUID.generate()
      content = String.duplicate("X", 5000)

      {:ok, _url, size, _checksum} = ArtifactStore.store(step_id, content, "text/plain")

      assert size == 5000
    end
  end

  # The gate used to branch on the caller's ORIGINAL byte count, so a large but
  # highly-compressible artifact — which is what an HTML scrape or an extracted
  # PDF text body is — was routed to the unimplemented S3 path and discarded.
  # DynamoDB's 400KB is an item-size limit on the bytes actually stored, which is
  # the gzipped body after `Dynamo.put_artifact/6` base64-encodes it.
  describe "store/4 — the DynamoDB size gate is measured on the stored bytes" do
    @tag :skip_unless_dynamo
    test "a 600KB artifact that gzips small is stored in DynamoDB, not discarded" do
      step_id = Ecto.UUID.generate()
      content = String.duplicate("<div>Amesbury City Council</div>", 20_000)

      assert byte_size(content) > 600 * 1024

      assert {:ok, url, size, _checksum} = ArtifactStore.store(step_id, content, "text/html")
      assert String.starts_with?(url, "dynamo://")
      # `size_bytes` still reports the ORIGINAL size; only the routing changed.
      assert size == byte_size(content)

      # And it round-trips — the artifact is genuinely retrievable, not just
      # reported stored.
      assert {:ok, ^content} = ArtifactStore.fetch(url)
    end

    test "an incompressible artifact whose stored payload exceeds the item limit is refused by Dynamo" do
      step_id = Ecto.UUID.generate()
      # Random bytes do not gzip, and base64 then inflates them by a third, so
      # 400KB of noise cannot fit a DynamoDB item however it is encoded. With the
      # Dynamo adapter alone there is no large tier, so it refuses honestly (under
      # `Tiered` this same payload routes to S3 — see `tiered_test.exs`).
      content = :crypto.strong_rand_bytes(400 * 1024)

      assert {:error, :too_large} =
               ArtifactStore.store(step_id, content, "application/octet-stream")
    end

    test "an uncompressed store is gated on the base64-inflated payload" do
      step_id = Ecto.UUID.generate()
      # 320KB raw is under the 400KB item limit, but base64 inflates it past it —
      # so with `compress: false` it does NOT fit.
      content = String.duplicate("Z", 320 * 1024)

      assert {:error, :too_large} =
               ArtifactStore.store(step_id, content, "text/plain", compress: false)
    end

    # The three cases above are all far from the boundary, and the 2KB metadata
    # allowance is the one number in the gate that was chosen rather than derived
    # — so pin it against the real server. If the allowance were ever too small,
    # DynamoDB would reject the put, `Runner.maybe_store_artifact/3` would log a
    # warning and return `%{}`, and the artifact would be silently gone under a
    # `:success` step — the exact failure mode this gate exists to close.
    @tag :skip_unless_dynamo
    test "a payload at the gate's exact ceiling is accepted by the real server and round-trips" do
      step_id = Ecto.UUID.generate()
      largest_raw = div(Dynamo.max_payload_bytes(), 4) * 3
      content = String.duplicate("Z", largest_raw)

      assert Dynamo.encoded_size(content) == Dynamo.max_payload_bytes()

      assert {:ok, url, size, _checksum} =
               ArtifactStore.store(step_id, content, "text/plain", compress: false)

      assert String.starts_with?(url, "dynamo://")
      assert size == largest_raw
      assert {:ok, ^content} = ArtifactStore.fetch(url)
    end

    test "one byte past the ceiling is refused by Dynamo" do
      step_id = Ecto.UUID.generate()
      content = String.duplicate("Z", div(Dynamo.max_payload_bytes(), 4) * 3 + 1)

      assert {:error, :too_large} =
               ArtifactStore.store(step_id, content, "text/plain", compress: false)
    end
  end

  describe "fetch/1" do
    @tag :skip_unless_dynamo
    test "retrieves artifact by URL" do
      step_id = Ecto.UUID.generate()
      original_content = "<html>Original content</html>"

      {:ok, url, _size, _checksum} = ArtifactStore.store(step_id, original_content, "text/html")

      {:ok, retrieved} = ArtifactStore.fetch(url)

      assert retrieved == original_content
    end

    @tag :skip_unless_dynamo
    test "decompresses gzip content automatically" do
      step_id = Ecto.UUID.generate()
      original_content = String.duplicate("Repeated content. ", 500)

      {:ok, url, _size, _checksum} = ArtifactStore.store(step_id, original_content, "text/plain")

      {:ok, retrieved} = ArtifactStore.fetch(url)

      assert retrieved == original_content
    end

    test "returns error for invalid URL format" do
      result = ArtifactStore.fetch("invalid://url")

      assert {:error, {:invalid_artifact_url, "invalid://url"}} = result
    end

    @tag :skip_unless_dynamo
    test "returns error for non-existent artifact" do
      non_existent_url = "dynamo://#{Dynamo.table_name()}/#{Ecto.UUID.generate()}"

      result = ArtifactStore.fetch(non_existent_url)

      assert {:error, :not_found} = result
    end
  end

  describe "delete/1" do
    @tag :skip_unless_dynamo
    test "deletes artifact" do
      step_id = Ecto.UUID.generate()
      content = "Content to delete"

      {:ok, url, _size, _checksum} = ArtifactStore.store(step_id, content, "text/plain")

      assert :ok = ArtifactStore.delete(url)

      # Verify it's deleted
      assert {:error, :not_found} = ArtifactStore.fetch(url)
    end
  end

  describe "exists?/1" do
    @tag :skip_unless_dynamo
    test "returns true for existing artifact" do
      step_id = Ecto.UUID.generate()
      {:ok, url, _size, _checksum} = ArtifactStore.store(step_id, "test", "text/plain")

      assert ArtifactStore.exists?(url)
    end

    @tag :skip_unless_dynamo
    test "returns false for non-existent artifact" do
      url = "dynamo://#{Dynamo.table_name()}/#{Ecto.UUID.generate()}"

      refute ArtifactStore.exists?(url)
    end

    test "returns false for invalid URL" do
      refute ArtifactStore.exists?("invalid://url")
    end
  end
end
