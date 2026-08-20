defmodule ALLM.Pipeline.Dsl.Stage do
  @moduledoc """
  One compiled stage of an `ALLM.Pipeline` declaration.

  `__pipeline__(:stages)` returns a list of these — **structs, not bare atoms**,
  so a caller reads the field it means (`& &1.name`, `& &1.concurrency`) rather
  than re-deriving it.

  The struct is built at RUNTIME by the function `@before_compile` generates,
  not stored in a module attribute: every hook field holds a real function, and
  `Module.put_attribute/3` rejects those. The DSL accumulates quoted AST during
  the module body and splices it into that generated function, where a
  `:hook_name` atom becomes a local capture (`&hook_name/2`) — which is why a
  hook may be `defp` (Phase 4 D6).

  ## Fields

  | Field | Meaning |
  |---|---|
  | `name` | the stage's atom name, unique within the pipeline |
  | `kind` | `:stage` (runs once) or `:fan_out` (runs once per item) |
  | `step` | the `ALLM.Pipeline.Step` module, or `nil` for the escape-hatch form |
  | `body` | the escape-hatch / per-item body, arity 2 `(ctx, subject)`, or `nil` |
  | `input` | arity-2 `(ctx, subject)` hook building the Step's input struct |
  | `over` | `fan_out` only: arity-1 `(prev_output)` hook returning the item list |
  | `section` | arity-1 `(item)` hook returning a section title, or `nil` |
  | `gate` | arity-2 `(item, opts)` hook; its result is bound into the item context's `carry` under `:gate` |
  | `skip_when` | `{:opt, key}` / `{:opt, key, default}` / arity-1 `(ctx)` hook, or `nil` |
  | `carry` | field names captured into the context's carry map — **scope differs by kind, see below** |
  | `delay` | `nil`, or `%{ms: ms_spec, when: :processed \\| :always \\| fun}` |
  | `parent` | `:source_stage` (default) or `:per_item` — see the moduledoc of `ALLM.Pipeline` |
  | `concurrency` | `nil` (inherit the pipeline's), a `pos_integer()`, or `{:opt, key, default}` |
  | `catch_item_failures` | sequential `fan_out` only; a concurrent one is always wrapped (D7) |
  | `on_error` | `kind: :stage` **only**: `:fail_run` (default) or `:continue`. It governs a whole-stage failure; a `fan_out` has none (its items fail individually into its output), so declaring it there is a compile error |

  ## `carry:`'s scope differs by kind

  On a **`stage`**, the keys are captured from that stage's **own output** —
  not from its subject, which is the *previous* stage's output — and merged into
  the carry map for **every later stage**. That is what makes a carried value
  survive any number of skipped stages between producer and consumer (D4).

  On a **`fan_out`**, the keys are captured from each **item** into that item's
  own context and nowhere else: they reach that item's `gate:`, `input:` and
  `body:`, and are **not** propagated past the stage. A fan-out has N items and
  one successor, so there is no non-arbitrary value to propagate.

  `Runtime.apply_result/3` is the first half, `Runtime.run_item/6` the second;
  `runtime_test.exs`'s "carry" describe pins both directions.
  """

  @type ms_spec :: non_neg_integer() | {:opt, atom(), non_neg_integer()}
  @type concurrency_spec :: pos_integer() | {:opt, atom(), pos_integer()}
  @type skip_spec ::
          {:opt, atom()}
          | {:opt, atom(), term()}
          | (ALLM.Pipeline.Context.t() -> as_boolean(term()))
  @type delay_spec :: %{
          ms: ms_spec(),
          when: :processed | :always | (term() -> as_boolean(term()))
        }

  @type t :: %__MODULE__{
          name: atom(),
          kind: :stage | :fan_out,
          step: module() | nil,
          body: (ALLM.Pipeline.Context.t(), term() -> term()) | nil,
          input: (ALLM.Pipeline.Context.t(), term() -> struct()) | nil,
          over: (term() -> [term()]) | nil,
          section: (term() -> String.t()) | nil,
          gate: (term(), keyword() -> term()) | nil,
          skip_when: skip_spec() | nil,
          carry: [atom()],
          delay: delay_spec() | nil,
          parent: :source_stage | :per_item,
          concurrency: concurrency_spec() | nil,
          catch_item_failures: boolean(),
          on_error: :fail_run | :continue
        }

  @enforce_keys [:name, :kind]
  defstruct [
    :name,
    :kind,
    :step,
    :body,
    :input,
    :over,
    :section,
    :gate,
    :skip_when,
    :delay,
    :concurrency,
    carry: [],
    parent: :source_stage,
    catch_item_failures: false,
    on_error: :fail_run
  ]
end
