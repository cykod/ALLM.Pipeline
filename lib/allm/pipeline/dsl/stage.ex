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
  | `kind` | `:stage` (runs once), `:fan_out` (runs once per item) or `:child_pipeline` (invokes another pipeline's entry point) |
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
  | `retry` | `nil`, or `%{max:, backoff:, base_ms:, on:}` — re-invokes the target, one step log per attempt (Phase 4 D11) |
  | `child` | `kind: :child_pipeline` only: `%{module:, fun:, args:}` |
  | `on_error` | `kind: :stage` and `:child_pipeline`: `:fail_run` (default) or `:continue`. It governs a whole-stage failure; a `fan_out` has none (its items fail individually into its output), so declaring it there is a compile error |

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

  ## A key the subject does not have

  `carry:` is validated at compile time only as a literal list of atoms
  (`Dsl.validate_carry!/3`) — whether a key is a *field* of whatever the stage
  produces is knowable only at run time. A key that is not is **dropped**: the
  carry map is unchanged and every later `Context.carried(ctx, key)` returns its
  default. `Runtime.capture/3` logs a `Logger.warning` naming the key, the stage
  and the subject's struct when that happens (user decision, 2026-08-21 — warn
  rather than raise, since raising would change framework behaviour nothing
  gates). It is a detector, not a gate: the run still succeeds, so a new
  `carry:` is verified by asserting the value ARRIVES in the consuming stage,
  never by the declaration compiling. `runtime_test.exs`'s "a carry: key the
  subject does not have is dropped LOUDLY" pins the message.

  The commonest way to hit it is a `fan_out` under `parent: :per_item`, whose
  items are `%ALLM.Pipeline.Dsl.Item{}` wrappers with fields `input` / `result`
  / `step_log` and no domain fields at all.
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

  @typedoc """
  A validated `retry:` declaration. `on: :any` retries every `{:error, _}`; a
  list retries only when the reason — or, for a tagged tuple, its first
  element — is a member. Phase 4 D11: this re-invokes the target and produces
  one step log per attempt; it does NOT accumulate a cumulative `retry_count`.
  """
  @type retry_spec :: %{
          max: pos_integer(),
          backoff: :none | :linear | :exponential,
          base_ms: non_neg_integer(),
          on: :any | [atom()]
        }

  @typedoc "A `child_pipeline` target: `Module.fun(args)` with `parent_run_id:` injected."
  @type child_spec :: %{
          module: module(),
          fun: atom(),
          args: (ALLM.Pipeline.Context.t(), term() -> [term()])
        }

  @type t :: %__MODULE__{
          name: atom(),
          kind: :stage | :fan_out | :child_pipeline,
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
          on_error: :fail_run | :continue,
          retry: retry_spec() | nil,
          child: child_spec() | nil
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
    :retry,
    :child,
    carry: [],
    parent: :source_stage,
    catch_item_failures: false,
    on_error: :fail_run
  ]
end
