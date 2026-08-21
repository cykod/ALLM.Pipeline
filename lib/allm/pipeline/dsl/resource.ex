defmodule ALLM.Pipeline.Dsl.Resource do
  @moduledoc """
  One declared `resource` — a handle acquired once per run and released before
  the terminal write.

      resource :browser, start: :open_browser, stop: :close_browser

  `start:` is an arity-1 hook `(ctx)` returning the handle; `stop:` is an
  arity-1 hook `(handle)`. Both may be `defp` atoms (Phase 4 D6). The handle
  reaches every step and body as `ALLM.Pipeline.Context.resource(ctx, :browser)`
  — a struct field, never an `opts` key.

  ## Why teardown runs BEFORE the terminal write (Phase 4 D3)

  The ordering is: stages → outcome computed (`summarize`, `metrics`) →
  **teardown** → terminal write. Two properties follow, and both are the reason:

  * Teardown *after* the write could not record a teardown failure anywhere,
    because the run row is already terminal.
  * Teardown that can throw *past* the terminal write re-creates the orphan-run
    defect Phase 4 exists to close.

  So `release/2` wraps every `stop` in `catch kind, reason` covering **all
  three** kinds. `rescue` alone is insufficient: a Playwright or `GenServer`
  teardown surfaces as an **exit**, not an exception.

  **A teardown failure never changes the terminal status.** The run's status is
  about the work; a leaked handle is an operational fault recorded beside it,
  under `metadata["resource_teardown_errors"]`. A wrong implementation either
  marks the run `:failed` or loses the record entirely, and
  `dsl/resource_test.exs` pins both directions.

  ## Acquisition is guarded too, and returns what it managed to acquire

  `acquire/2` folds the declarations in order. If a `start` hook raises, exits
  or throws, the fold halts and returns **the resources acquired so far**
  alongside the failure — so the caller can still release them. Losing that map
  would leak exactly the handles the construct exists to manage, and it is the
  reason `acquire/2` returns a pair rather than raising.

  `release/2` releases in **reverse** declaration order (LIFO), which is what a
  resource declared *after* another and depending on it needs.

  > **No production consumer as of Phase 4.5 — deadlined to Phase 5.** No pipeline
  > declares a `resource` yet; it is wired into a named Phase 5 port that consumes
  > it, or removed (§8.6 Rec 3; `.work/HANDOFF.md`). Kept, tested, and not deleted
  > because Phase 5's browser/session ports are its intended consumers.
  """

  alias ALLM.Pipeline.{Context, Encodable}

  require Logger

  @typedoc "A teardown failure, already jsonb-safe (every value is a string)."
  @type teardown_error :: %{required(String.t()) => String.t()}

  @typedoc "How an acquisition ended. `{:raised, …}` carries the kind, so a caller can re-raise."
  @type acquire_outcome ::
          :ok | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  @type t :: %__MODULE__{
          name: atom(),
          start: (Context.t() -> term()),
          stop: (term() -> term())
        }

  @enforce_keys [:name, :start, :stop]
  defstruct [:name, :start, :stop]

  @doc """
  Acquire every declared resource, in declaration order.

  Returns `{acquired, outcome}` — the map reaches `Context.resources`, and
  `outcome` is `:ok` or a `{:raised, kind, reason, stacktrace}` the caller
  re-raises **after** releasing what `acquired` holds.
  """
  @spec acquire([t()], Context.t()) :: {Context.resources(), acquire_outcome()}
  def acquire([], _ctx), do: {%{}, :ok}

  def acquire(resources, %Context{} = ctx) do
    Enum.reduce_while(resources, {%{}, :ok}, fn %__MODULE__{} = resource, {acquired, :ok} ->
      try do
        {:cont, {Map.put(acquired, resource.name, resource.start.(ctx)), :ok}}
      catch
        # All three kinds, for the same reason `release/2` catches all three:
        # a browser launch that times out arrives as an exit.
        kind, reason ->
          Logger.error(
            "resource :#{resource.name} failed to start with #{kind} " <>
              "#{Encodable.render(reason)}\n" <>
              Exception.format_stacktrace(__STACKTRACE__)
          )

          {:halt, {acquired, {:raised, kind, reason, __STACKTRACE__}}}
      end
    end)
  end

  @doc """
  Release every acquired resource in **reverse** declaration order.

  Never raises. Returns one `t:teardown_error/0` per `stop` that failed, in the
  order they were attempted; `[]` when everything released cleanly (and when
  nothing was acquired, which is every pipeline that declares no `resource`).

  A declaration whose `start` never ran is skipped — `acquire/2` halts on the
  first failure, so the map is the authoritative record of what exists.
  """
  @spec release([t()], Context.resources()) :: [teardown_error()]
  def release([], _acquired), do: []

  def release(resources, acquired) when is_map(acquired) do
    resources
    |> Enum.reverse()
    |> Enum.flat_map(fn %__MODULE__{} = resource ->
      case Map.fetch(acquired, resource.name) do
        :error -> []
        {:ok, handle} -> release_one(resource, handle)
      end
    end)
  end

  @spec release_one(t(), term()) :: [teardown_error()]
  defp release_one(%__MODULE__{} = resource, handle) do
    resource.stop.(handle)
    []
  catch
    kind, reason ->
      Logger.error(
        "resource :#{resource.name} failed to stop with #{kind} #{Encodable.render(reason)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      # `Encodable.render/1`, never bare `inspect/1`. This map is merged into
      # `pipeline_runs.metadata` on BOTH terminal paths, and a `stop` hook's
      # failure reason is precisely the term that can inline a credential — a
      # `GenServer.call` timeout exit carries the call's message term, and this
      # construct's named consumers are a Playwright browser and an OpenGov
      # Auth0 session. `render/1` bounds the content; `Encodable.encode/1` at
      # the writers handles the jsonb-safety half.
      [
        %{
          "resource" => Atom.to_string(resource.name),
          "kind" => Atom.to_string(kind),
          "reason" => Encodable.render(reason)
        }
      ]
  end
end
