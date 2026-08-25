defmodule ALLM.Pipeline.TestSupport.Registry do
  @moduledoc """
  The standalone suite's registry declaration — the role `Amesbury.Pipelines`
  plays in the umbrella host, minus the host-only keys:

    * **no `llm:`** — the seam is optional and its only implementation is a
      host module. `ALLM.Pipeline.LLM.impl/0` raising when unwired is the
      designed behaviour, and no package test may depend on a wired LLM
      (`CLAUDE.md` §5's env-ownership rule).
    * **no `alert_on_empty:` / `lock_keys:` / `pipelines:`** — host domain data.

  `test/test_helper.exs` calls `install/0` immediately before its
  `Sandbox.mode/2` line. Note `__install__/1`'s `put_new` semantics for seam
  keys (`CLAUDE.md` §6): a config-file `impl:` override still wins.
  """

  use ALLM.Pipeline.Registry,
    repo: ALLM.Pipeline.TestRepo,
    store: ALLM.Pipeline.Store.Ecto,
    artifacts:
      {ALLM.Pipeline.Artifacts.Tiered,
       small: ALLM.Pipeline.Artifacts.Dynamo, large: ALLM.Pipeline.Artifacts.S3},
    lock: ALLM.Pipeline.Lock.Noop
end
