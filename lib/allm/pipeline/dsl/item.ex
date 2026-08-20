defmodule ALLM.Pipeline.Dsl.Item do
  @moduledoc """
  One item's outcome from a `fan_out`, and the carrier for per-item lineage.

  A `fan_out` stage's OUTPUT is a `[t()]` — one entry per element `over:`
  produced, in declaration order. The next stage's `over:` hook receives that
  list, which is why `committee`'s `ok_details/1` and `ok_transforms/1` are
  ordinary filters over these.

  ## Why the step log rides on the item

  `parent: :per_item` means "each item's steps parent to **its own** producing
  step log" — `committee` chains each transform to *its* detail step and each
  load to *its* transform step. The producing log is per element, so it can
  only travel with the element. Under `parent: :per_item` the elements a
  downstream `over:` hook returns must therefore still be `t()` structs (filter
  them; do not unwrap them), and `ALLM.Pipeline.Dsl.Runtime` reads
  `input_step_id` off `item.step_log`. Under the default `:source_stage` the
  DSL never looks inside an item and `over:` may return anything.

  `step_log` is `nil` for an item produced by a `body:` that returned the
  lineage-transparent `{:ok, value}` — the two-element form nominates no new
  parent (Phase 4 D2).

  ## `input` and `result` are opposite ends of the item

  | Field | What it holds |
  |---|---|
  | `input` | the element `over:` produced — what went IN |
  | `result` | what the body or Step made of it — what came OUT |
  | `step_log` | the row that produced `result`, or `nil` |

  `ok_values/1` returns the payload out of `result`, i.e. the **outputs**;
  `Enum.map(items, & &1.input)` returns the inputs. The field was named `value`
  through 4.1's implementation, which made `& &1.value` read like the successful
  payload and silently feed the previous stage's inputs forward.
  """

  alias ALLM.Pipeline.StepLog

  @typedoc """
  The per-item outcome, exactly as the body or Step produced it. `{:ok, v, log}`
  is normalized away: its log moves to `step_log` and `result` keeps `{:ok, v}`.
  """
  @type result :: {:ok, term()} | {:skipped, term()} | {:error, term()}

  @type t :: %__MODULE__{
          input: term(),
          result: result(),
          step_log: StepLog.t() | nil
        }

  @enforce_keys [:input, :result]
  defstruct [:input, :result, :step_log]

  @doc """
  The successful items' **outputs**, in order — the common `over:` filter.

  This is `result`'s payload, not `input`. To get the inputs back, map over
  `& &1.input`.
  """
  @spec ok_values([t()]) :: [term()]
  def ok_values(items) do
    for %__MODULE__{result: {:ok, value}} <- items, do: value
  end

  @doc """
  The successful items themselves, in order.

  This is the filter a `parent: :per_item` fan-out needs: it keeps the `t()`
  wrapper, and therefore the producing step log, which `ok_values/1` discards.
  """
  @spec ok_items([t()]) :: [t()]
  def ok_items(items) do
    for %__MODULE__{result: {:ok, _}} = item <- items, do: item
  end
end
