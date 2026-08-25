defmodule ALLM.Pipeline.Artifacts.Memory do
  @moduledoc """
  In-VM `ALLM.Pipeline.Artifacts` adapter — artifacts live in an `Agent` and
  die with it.

  For tests and throwaway experiments: it needs no DynamoDB, no filesystem and
  no configuration, so a suite that only cares *that* an artifact round-trips
  can configure it and stop depending on `docker-compose`.

  URLs are `memory://<id>`.

  ## Lifecycle

  The `Agent` is started on demand and named after this module, matching
  `ALLM.Pipeline.LLMCallLog` — the package declares no supervision tree
  (this repo's `mix.exs` has no `mod:`), so there is nothing to start it
  under. It is process-global, therefore **shared across concurrent tests**:
  ids collide across tests unless each generates its own, and `gc/1` with no
  options purges everything. Call `gc/1` in a `setup` block rather than
  assuming a clean slate.

  There is no size ceiling — `put/4` never returns `{:error, :too_large}` — so
  a payload the DynamoDB adapter would refuse is stored here without comment.
  That is deliberate (an in-memory store has no item limit to enforce), but it
  means this adapter cannot exercise `ArtifactStore`'s oversize routing.
  """

  @behaviour ALLM.Pipeline.Artifacts

  alias ALLM.Pipeline.Artifacts

  @scheme "memory://"

  @impl true
  @spec put(Artifacts.id(), binary(), String.t(), Artifacts.meta()) :: {:ok, Artifacts.url()}
  def put(id, content, content_type, %{
        size_bytes: size_bytes,
        checksum: checksum,
        compressed: compressed
      }) do
    entry = %{
      content: content,
      content_type: content_type,
      compressed: compressed,
      checksum: checksum,
      size_bytes: size_bytes,
      stored_at: DateTime.utc_now()
    }

    Agent.update(agent(), &Map.put(&1, id, entry))

    {:ok, @scheme <> id}
  end

  @impl true
  @spec fetch(Artifacts.url()) :: {:ok, Artifacts.stored()} | {:error, term()}
  def fetch(@scheme <> id) do
    case Agent.get(agent(), &Map.fetch(&1, id)) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_found}
    end
  end

  def fetch(url), do: {:error, {:invalid_artifact_url, url}}

  @impl true
  @spec delete(Artifacts.url()) :: :ok | {:error, term()}
  def delete(@scheme <> id) do
    Agent.update(agent(), &Map.delete(&1, id))
  end

  def delete(_url), do: {:error, :invalid_url}

  @impl true
  @spec exists?(Artifacts.url()) :: boolean()
  def exists?(@scheme <> id), do: Agent.get(agent(), &Map.has_key?(&1, id))
  def exists?(_url), do: false

  @doc """
  Drop everything stored at or before `opts[:older_than]` (default: now), and
  return how many entries went. With no options this empties the store, which
  is what a test `setup` wants.
  """
  @impl true
  @spec gc(keyword()) :: {:ok, non_neg_integer()}
  def gc(opts \\ []) do
    cutoff = Keyword.get(opts, :older_than, DateTime.utc_now())

    Agent.get_and_update(agent(), fn entries ->
      {expired, kept} =
        Map.split_with(entries, fn {_id, %{stored_at: at}} ->
          DateTime.compare(at, cutoff) != :gt
        end)

      {{:ok, map_size(expired)}, kept}
    end)
  end

  # Started on demand (there is no supervision tree to start it under) and
  # named, so every caller in the VM shares one store. The `:already_started`
  # arm is the ordinary case after the first call — and the race between two
  # processes both finding it absent, which the name resolves for us.
  @spec agent() :: pid()
  defp agent do
    case Agent.start(fn -> %{} end, name: __MODULE__) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
