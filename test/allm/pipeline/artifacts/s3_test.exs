defmodule ALLM.Pipeline.Artifacts.S3Test do
  @moduledoc """
  Live round-trip for `ALLM.Pipeline.Artifacts.S3` against the local MinIO the
  dev/test media stack runs (Phase 7.5).

  Gated by `@moduletag :s3` / `@tag :skip_unless_s3`: the package
  `test_helper.exs` excludes both when `ALLM.Pipeline.Artifacts.S3.reachable?/0`
  says MinIO is not answering, mirroring the `:dynamo` exclusion. Bring it up
  with `docker-compose -f docker-compose.dev.yml up -d minio`.

  **Not `async: true`** — shares the process-global MinIO bucket.
  """

  use ExUnit.Case, async: false

  alias ALLM.Pipeline.ArtifactStore
  alias ALLM.Pipeline.Artifacts
  alias ALLM.Pipeline.Artifacts.S3

  @moduletag :s3

  setup do
    ensure_bucket!()
    # Pin S3 as the wrapper's adapter so `ArtifactStore` round-trips go to it.
    previous = Application.get_env(:amesbury_scraper, Artifacts)
    Application.put_env(:amesbury_scraper, Artifacts, impl: S3)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:amesbury_scraper, Artifacts, previous),
        else: Application.delete_env(:amesbury_scraper, Artifacts)
    end)

    :ok
  end

  describe "the adapter directly" do
    @tag :skip_unless_s3
    test "put → fetch round-trips the bytes and metadata; exists?/delete track it" do
      id = "s3-adapter-#{System.unique_integer([:positive])}"
      content = :crypto.strong_rand_bytes(2048)

      meta = %{size_bytes: byte_size(content), checksum: "deadbeef", compressed: true}

      assert {:ok, url} = S3.put(id, content, "application/octet-stream", meta)
      assert String.starts_with?(url, "s3://")

      assert S3.exists?(url)

      assert {:ok, stored} = S3.fetch(url)
      assert stored.content == content
      assert stored.content_type == "application/octet-stream"
      # The compressed flag round-trips as object metadata — `ArtifactStore`
      # depends on it to decide whether to gunzip.
      assert stored.compressed == true
      assert stored.checksum == "deadbeef"

      assert :ok = S3.delete(url)
      refute S3.exists?(url)
      assert {:error, :not_found} = S3.fetch(url)
    end
  end

  describe "through ArtifactStore (compression boundary)" do
    @tag :skip_unless_s3
    test "store gzips, S3 holds the compressed bytes, fetch gunzips back to the original" do
      id = "s3-wrapped-#{System.unique_integer([:positive])}"
      content = String.duplicate("Amesbury City Council minutes. ", 2_000)

      assert {:ok, url, size, _checksum} = ArtifactStore.store(id, content, "text/plain")
      assert String.starts_with?(url, "s3://")
      assert size == byte_size(content)

      # The adapter is holding the gzipped bytes (smaller than the original), and
      # the wrapper decompresses on the way back out.
      assert {:ok, stored} = S3.fetch(url)
      assert byte_size(stored.content) < byte_size(content)
      assert {:ok, ^content} = ArtifactStore.fetch(url)

      assert :ok = ArtifactStore.delete(url)
      refute ArtifactStore.exists?(url)
    end
  end

  # MinIO does not pre-create the artifacts bucket, so the test does. Only the
  # genuinely-idempotent outcomes collapse to `:ok`; any other error (a real 500,
  # auth failure, connection reset) `flunk`s at its cause rather than being
  # swallowed and re-surfacing later as a confusing put/fetch failure.
  defp ensure_bucket! do
    bucket = S3.bucket()
    request = ExAws.S3.put_bucket(bucket, region())

    case ExAws.request(request, S3.ex_aws_config()) do
      {:ok, _} ->
        :ok

      # Bucket already there — idempotent success (409, or BucketAlreadyOwnedByYou
      # on some MinIO builds).
      {:error, {:http_error, 409, _}} ->
        :ok

      {:error, {:http_error, _status, %{body: body}}} = error ->
        if is_binary(body) and String.contains?(body, "BucketAlreadyOwnedByYou"),
          do: :ok,
          else: flunk("MinIO bucket setup failed: #{inspect(error)}")

      {:error, reason} ->
        flunk("MinIO bucket setup failed: #{inspect(reason)}")
    end
  end

  defp region do
    Application.get_env(:amesbury_scraper, S3, []) |> Keyword.get(:region, "us-east-1")
  end
end
