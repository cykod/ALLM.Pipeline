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

  # MinIO does not pre-create the artifacts bucket, so the test does. Idempotent:
  # a 409 (bucket already there) is fine.
  defp ensure_bucket! do
    bucket = S3.bucket()
    request = ExAws.S3.put_bucket(bucket, region())

    case ExAws.request(request, ex_aws_config()) do
      {:ok, _} ->
        :ok

      {:error, {:http_error, 409, _}} ->
        :ok

      # BucketAlreadyOwnedByYou / already exists on some MinIO builds.
      {:error, {:http_error, _status, %{body: body}}} ->
        if is_binary(body) and String.contains?(body, "BucketAlreadyOwnedByYou"),
          do: :ok,
          else: :ok

      _ ->
        :ok
    end
  end

  # Same construction as the adapter's private `ex_aws_config/0`, reading the
  # same config key — a test may not call a private helper.
  defp ex_aws_config do
    config = Application.get_env(:amesbury_scraper, S3, [])
    base = if region = Keyword.get(config, :region), do: [region: region], else: []

    case Keyword.get(config, :endpoint) do
      nil ->
        base

      endpoint ->
        uri = URI.parse(endpoint)

        base
        |> Keyword.put(:host, uri.host)
        |> Keyword.put(:port, uri.port)
        |> Keyword.put(:scheme, "#{uri.scheme}://")
    end
  end

  defp region do
    Application.get_env(:amesbury_scraper, S3, []) |> Keyword.get(:region, "us-east-1")
  end
end
