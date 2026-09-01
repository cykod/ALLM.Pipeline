defmodule ALLM.Pipeline.Artifacts.Dynamo do
  @moduledoc ~S"""
  DynamoDB client for artifact storage.

  ## Table Schema

  - `pk` (String): Primary key, format `ARTIFACT#<artifact_id>`
  - `sk` (String): Sort key, always `ARTIFACT`
  - `artifact_id` (String): UUID matching step_log.id
  - `content_type` (String): MIME type (text/html, application/json, text/plain)
  - `content` (Binary): Artifact content (optionally gzip compressed)
  - `compressed` (Boolean): Whether content is gzip compressed
  - `checksum` (String): SHA-256 hash of original content
  - `size_bytes` (Number): Original uncompressed size
  - `created_at` (String): ISO8601 timestamp

  ## Two surfaces

  `put/4` / `fetch/1` / `delete/1` / `exists?/1` implement
  `ALLM.Pipeline.Artifacts` and speak in `dynamo://<table>/<id>` URLs — that is
  what `ALLM.Pipeline.ArtifactStore` calls. The `*_artifact/*` and table-admin
  functions beneath them are this module's own DynamoDB API, speaking in bare
  artifact ids; the mix tasks, `DynamoCase` and the eval harness use them
  directly to inspect and manage the table.
  """

  @behaviour ALLM.Pipeline.Artifacts

  require Logger

  alias ALLM.Pipeline.Artifacts

  # DynamoDB's hard per-item limit, and the slice of it the item's non-content
  # attributes need. Those attributes are fully enumerable from `put_artifact/6`
  # below and have no unbounded contributor: `pk` (`ARTIFACT#` + a 36-char UUID)
  # ~45 B, `artifact_id` 36 B, `checksum` (64 hex chars) ~72 B, `created_at`
  # (ISO-8601) ~37 B, `sk`/`content_type`/`compressed`/`size_bytes` and every
  # attribute NAME ~90 B — roughly 300 B in total, measured at ~280 B against a
  # real stored item (2026-08-13). 2 KB is ~7× that; over-reserving costs
  # nothing while under-reserving silently loses an artifact.
  @item_limit 400 * 1024
  @metadata_allowance 2 * 1024
  @max_payload_bytes @item_limit - @metadata_allowance

  # The URL scheme this adapter owns, as `Memory` and `Filesystem` declare
  # theirs. One emit site (`put/4`, an interpolation) and three match heads —
  # the shape where a rename touches three and misses the fourth.
  @scheme "dynamo://"

  @type artifact :: %{
          artifact_id: String.t(),
          content_type: String.t(),
          content: binary(),
          compressed: boolean(),
          checksum: String.t(),
          size_bytes: non_neg_integer(),
          created_at: String.t()
        }

  @doc """
  Get the configured table name.
  """
  @spec table_name() :: String.t()
  def table_name do
    Application.get_env(:allm_pipeline, :dynamo, [])
    |> Keyword.get(:table_name, "allm_pipeline_artifacts")
  end

  @doc """
  How many bytes `content` occupies inside a stored DynamoDB item.

  `put_artifact/6` writes the body **base64-encoded** as a String attribute, so
  the stored form is `4 * ceil(n / 3)` — a third larger than the binary handed in.
  DynamoDB's 400KB ceiling is an item-size limit on what is actually stored, so
  any size gate deciding "does this fit in DynamoDB?" must be applied to this
  number and not to the caller's original (or even its gzipped) byte count. See
  `ALLM.Pipeline.ArtifactStore.store/4`.
  """
  @spec encoded_size(binary()) :: non_neg_integer()
  def encoded_size(content), do: 4 * div(byte_size(content) + 2, 3)

  @doc """
  Whether `content` fits in a DynamoDB item once stored.

  The whole capacity question lives here rather than in the caller: a tier router
  deciding "DynamoDB or S3?" should not have to know DynamoDB's item ceiling, its
  base64 encoding, or how much of the item its own metadata consumes.

  `content` is the body as it will be handed to `put_artifact/6` — i.e. already
  gzipped, if the caller compresses.
  """
  @spec fits_item?(binary()) :: boolean()
  def fits_item?(content), do: encoded_size(content) <= @max_payload_bytes

  @doc """
  The largest **encoded** (post-base64) size `fits_item?/1` admits — i.e. the
  ceiling `encoded_size/1` is compared against, not a raw byte count.

  A raw body of exactly this many bytes is therefore REFUSED; the largest
  admissible raw body is `div(max_payload_bytes(), 4) * 3`. Exposed so a
  boundary test can pin both edges of the metadata allowance without
  re-deriving the arithmetic — see `dynamo_test.exs`'s `fits_item?/1` describe,
  which derives the raw edge exactly that way.
  """
  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  # ── ALLM.Pipeline.Artifacts ────────────────────────────────────────────────

  @doc """
  Store an already-encoded payload and return its `dynamo://<table>/<id>` URL.

  The capacity check lives here rather than in the caller: a tier router
  deciding "DynamoDB or S3?" should not have to know DynamoDB's item ceiling,
  its base64 inflation, or how much of the item its own metadata consumes. An
  oversize payload short-circuits to `{:error, :too_large}` **without**
  contacting the server.
  """
  @impl true
  @spec put(Artifacts.id(), binary(), String.t(), Artifacts.meta()) ::
          {:ok, Artifacts.url()} | {:error, :too_large} | {:error, term()}
  def put(id, content, content_type, %{
        size_bytes: size_bytes,
        checksum: checksum,
        compressed: compressed
      }) do
    if fits_item?(content) do
      case put_artifact(id, content, content_type, size_bytes, checksum, compressed) do
        :ok -> {:ok, @scheme <> "#{table_name()}/#{id}"}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :too_large}
    end
  end

  @doc """
  Fetch the artifact behind a `dynamo://` URL, **as stored** — still gzipped if
  it was stored gzipped. `ALLM.Pipeline.ArtifactStore` owns decompression.
  """
  @impl true
  @spec fetch(Artifacts.url()) :: {:ok, Artifacts.stored()} | {:error, term()}
  def fetch(@scheme <> rest = url) do
    case artifact_id(rest) do
      {:ok, artifact_id} -> get_artifact(artifact_id)
      :error -> {:error, {:invalid_artifact_url, url}}
    end
  end

  def fetch(url), do: {:error, {:invalid_artifact_url, url}}

  @doc "Delete the artifact behind a `dynamo://` URL."
  @impl true
  @spec delete(Artifacts.url()) :: :ok | {:error, term()}
  def delete(@scheme <> rest) do
    case artifact_id(rest) do
      {:ok, artifact_id} -> delete_artifact(artifact_id)
      :error -> {:error, :invalid_url}
    end
  end

  def delete(_url), do: {:error, :invalid_url}

  @doc """
  Whether an artifact exists behind a `dynamo://` URL.

  A *transport* failure (as opposed to a missing item) has no clause and
  raises. That is unchanged pre-existing behaviour, deliberately preserved by
  the extraction: `exists?` has no way to say "I could not tell", and this
  phase changes no behaviour. Widening it to `false` would report a reachable
  artifact as absent whenever DynamoDB blinks. The behaviour's `exists?/1`
  `@callback` doc names this adapter as the exception it allows.

  A malformed URL is a different case and is NOT a raise — see `artifact_id/1`.
  """
  @impl true
  @spec exists?(Artifacts.url()) :: boolean()
  def exists?(@scheme <> rest) do
    case artifact_id(rest) do
      {:ok, artifact_id} ->
        case get_artifact(artifact_id) do
          {:ok, _} -> true
          {:error, :not_found} -> false
        end

      :error ->
        false
    end
  end

  def exists?(_url), do: false

  # `dynamo://<table>/<id>` — the table segment is informational (the configured
  # table is authoritative), so only the id is taken.
  #
  # A `dynamo://` URL with no `/` after the scheme is not one of ours, and
  # answers `:error` rather than raising: the `ALLM.Pipeline.Artifacts`
  # callback docs promise a structured error from `fetch/1` and `delete/1` and
  # `false` from `exists?/1` for a URL the adapter does not recognize, and this
  # is the one shape that used to violate all three (a `MatchError` out of
  # `String.split/3`). No caller can construct such a URL — `step_logs.artifact_url`
  # is only ever written by `put/4` — so nothing observable changed; the
  # contract is now honoured by all three adapters rather than two.
  @spec artifact_id(String.t()) :: {:ok, String.t()} | :error
  defp artifact_id(rest) do
    case String.split(rest, "/", parts: 2) do
      [_table, artifact_id] -> {:ok, artifact_id}
      _ -> :error
    end
  end

  # ── This module's own DynamoDB API ─────────────────────────────────────────

  @doc """
  Store an artifact in DynamoDB.
  """
  @spec put_artifact(
          String.t(),
          binary(),
          String.t(),
          non_neg_integer(),
          String.t(),
          boolean()
        ) :: :ok | {:error, term()}
  def put_artifact(artifact_id, content, content_type, size_bytes, checksum, compressed) do
    # ExAws.Dynamo handles encoding automatically - use simple map format
    item = %{
      pk: "ARTIFACT##{artifact_id}",
      sk: "ARTIFACT",
      artifact_id: artifact_id,
      content_type: content_type,
      content: Base.encode64(content),
      compressed: compressed,
      checksum: checksum,
      size_bytes: size_bytes,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    request = ExAws.Dynamo.put_item(table_name(), item)

    case ExAws.request(request, dynamo_config()) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to store artifact #{artifact_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get an artifact from DynamoDB.
  """
  @spec get_artifact(String.t()) :: {:ok, artifact()} | {:error, term()}
  def get_artifact(artifact_id) do
    key = %{
      pk: "ARTIFACT##{artifact_id}",
      sk: "ARTIFACT"
    }

    request = ExAws.Dynamo.get_item(table_name(), key)

    case ExAws.request(request, dynamo_config()) do
      {:ok, %{"Item" => item}} ->
        {:ok, decode_item(item)}

      {:ok, %{}} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Failed to get artifact #{artifact_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Delete an artifact from DynamoDB.
  """
  @spec delete_artifact(String.t()) :: :ok | {:error, term()}
  def delete_artifact(artifact_id) do
    key = %{
      pk: "ARTIFACT##{artifact_id}",
      sk: "ARTIFACT"
    }

    request = ExAws.Dynamo.delete_item(table_name(), key)

    case ExAws.request(request, dynamo_config()) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clear all artifacts from the table. Use with caution - primarily for testing.
  """
  @spec clear_table() :: :ok | {:error, term()}
  def clear_table do
    scan_and_delete()
  end

  @doc """
  Create the artifacts table in DynamoDB.
  """
  @spec create_table() :: :ok | {:error, term()}
  def create_table do
    request =
      ExAws.Dynamo.create_table(
        table_name(),
        [pk: :hash, sk: :range],
        # Keyword list, not a map: ExAws types `key_definitions` as
        # `[{atom | binary, type}, ...]`. `encode_key_definitions/1` iterates it
        # with `Enum.map(fn {name, type} -> … end)`, identical for either shape,
        # but the map form breaks the `@spec` and dialyzes as `no_return`.
        [pk: :string, sk: :string],
        1,
        1
      )

    case ExAws.request(request, dynamo_config()) do
      {:ok, _} ->
        Logger.info("Created DynamoDB table: #{table_name()}")
        :ok

      {:error, {"ResourceInUseException", _}} ->
        # Table already exists - this is fine
        :ok

      {:error, {"com.amazonaws.dynamodb.v20120810#ResourceInUseException", _}} ->
        # Alternative error format from local DynamoDB
        :ok

      {:error, reason} ->
        # Check if it's a "table exists" error with different format
        if table_exists_error?(reason) do
          :ok
        else
          Logger.error("Failed to create DynamoDB table: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  @doc """
  Delete the artifacts table from DynamoDB.
  """
  @spec delete_table() :: :ok | {:error, term()}
  def delete_table do
    request = ExAws.Dynamo.delete_table(table_name())

    case ExAws.request(request, dynamo_config()) do
      {:ok, _} ->
        Logger.info("Deleted DynamoDB table: #{table_name()}")
        :ok

      {:error, {"ResourceNotFoundException", _}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if the artifacts table exists.
  """
  @spec table_exists?() :: boolean()
  def table_exists? do
    request = ExAws.Dynamo.describe_table(table_name())

    case ExAws.request(request, dynamo_config()) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Is the local DynamoDB stack reachable?

  `table_exists?/0` plus the `rescue` a test harness needs: a stack that is not
  merely missing the table but not listening at all raises out of ExAws rather
  than returning `{:error, _}`.
  """
  @spec available?() :: boolean()
  def available? do
    table_exists?()
  rescue
    _ -> false
  end

  @doc """
  The ExUnit tags to exclude when DynamoDB is unreachable, plus an operator hint.

  **Single source of truth for the tag list.** Each consuming repo's own
  `test_helper.exs` and this repo's own need the same answer, because each
  suite starts ExUnit with its own option set, and they live in DIFFERENT repos.
  Hand-copying the probe was survivable; hand-copying the TAG LIST is the "a
  rule enforced in more than one shape needs a membership guard" defect in its
  data-map form — add a third tag on one side and the
  other tree silently stops honouring it. This module is package `lib/` code,
  so every suite calls the SAME implementation — that shared function is the
  cross-repo drift guard.

  **Why test-harness support sits in `lib/` rather than `test/support/`:** a
  `test/support/` module is visible to exactly one repo's test tree, and this
  answer is needed by two or more — trees that, by design, cannot see each
  other's support code (the package declares no host dependency, and each host
  is a different repo entirely). `lib/` is the only place all can reach. It does
  no I/O beyond the probe and is not referenced by any production path.

  Returns `{[], nil}` when the stack is up (nothing excluded, nothing to print)
  and `{tags, message}` when it is down. The message is the caller's to print;
  this function does no I/O beyond the probe.
  """
  @spec exclusions() :: {[atom()], String.t() | nil}
  def exclusions do
    if available?() do
      {[], nil}
    else
      endpoint =
        Application.get_env(:allm_pipeline, :dynamo, [])
        |> Keyword.get(:endpoint, "the default AWS endpoint")

      {[:dynamo, :skip_unless_dynamo],
       "\n[test_helper] Local DynamoDB is unreachable at #{endpoint} " <>
         "(table #{inspect(table_name())}) — excluding :dynamo / " <>
         ":skip_unless_dynamo tests. Start the local stack — this repo's " <>
         "`docker-compose.yml` serves it: `docker compose up -d`.\n"}
    end
  end

  # Private functions

  defp decode_item(item) do
    # ExAws.Dynamo returns items in DynamoDB wire format with type descriptors
    # Handle both string and atom keys since response format may vary
    %{
      artifact_id: get_string_value(item, "artifact_id"),
      content_type: get_string_value(item, "content_type"),
      content: get_binary_value(item, "content"),
      compressed: get_bool_value(item, "compressed"),
      checksum: get_string_value(item, "checksum"),
      size_bytes: get_number_value(item, "size_bytes"),
      created_at: get_string_value(item, "created_at")
    }
  end

  defp get_string_value(item, key) do
    case item[key] || item[String.to_atom(key)] do
      %{"S" => value} -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp get_binary_value(item, key) do
    case item[key] || item[String.to_atom(key)] do
      # Binary type from DynamoDB
      %{"B" => value} -> Base.decode64!(value)
      # String type (we store base64 as string since ExAws encodes automatically)
      %{"S" => value} -> Base.decode64!(value)
      # Already decoded string (base64)
      value when is_binary(value) -> Base.decode64!(value)
      _ -> nil
    end
  end

  defp get_bool_value(item, key) do
    case item[key] || item[String.to_atom(key)] do
      %{"BOOL" => value} -> value
      value when is_boolean(value) -> value
      _ -> false
    end
  end

  defp get_number_value(item, key) do
    case item[key] || item[String.to_atom(key)] do
      %{"N" => value} -> String.to_integer(value)
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> 0
    end
  end

  defp scan_and_delete do
    scan_request = ExAws.Dynamo.scan(table_name(), projection_expression: "pk, sk")

    case ExAws.request(scan_request, dynamo_config()) do
      {:ok, %{"Items" => items}} ->
        Enum.each(items, fn item ->
          # Extract the actual string values from the typed DynamoDB response
          pk_value = get_string_value(item, "pk")
          sk_value = get_string_value(item, "sk")

          if pk_value && sk_value do
            key = %{pk: pk_value, sk: sk_value}
            delete_request = ExAws.Dynamo.delete_item(table_name(), key)
            ExAws.request(delete_request, dynamo_config())
          end
        end)

        :ok

      {:ok, %{}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dynamo_config do
    config = Application.get_env(:allm_pipeline, :dynamo, [])

    base_config = [
      region: Keyword.get(config, :region, "us-east-1")
    ]

    # Add endpoint override for local DynamoDB
    case Keyword.get(config, :endpoint) do
      nil ->
        base_config

      endpoint ->
        # Parse the endpoint URL to extract scheme, host, and port
        uri = URI.parse(endpoint)

        base_config
        |> Keyword.put(:scheme, uri.scheme || "http")
        |> Keyword.put(:host, uri.host || "localhost")
        |> Keyword.put(:port, uri.port || 8000)
    end
  end

  # Check if an error indicates table already exists (various formats)
  defp table_exists_error?({type, _msg}) when is_binary(type) do
    String.contains?(type, "ResourceInUseException") or
      String.contains?(type, "preexisting")
  end

  defp table_exists_error?(_), do: false
end
