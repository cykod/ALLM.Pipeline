defmodule ALLM.Pipeline.TestSupport.LazyLLMAdapter do
  @moduledoc """
  An LLM adapter with a `.beam` on disk, so `llm_test.exs` can purge it and
  prove the seam's dispatch loads a not-yet-loaded adapter before asking
  `function_exported?/3` (which answers `false` for an unloaded module).

  A module defined inside an `.exs` file cannot serve: once deleted,
  `Code.ensure_loaded/1` returns `{:error, :nofile}` for it.

  Deliberately declares NO `@behaviour ALLM.Pipeline.LLM`: dispatch needs only
  the exports, and `behaviours_test.exs` requires every in-package module
  declaring a seam behaviour to be a listed seam implementation — a scan that
  includes `test/support`.
  """

  @spec resolve_engine(atom()) :: {:legacy, atom()}
  def resolve_engine(name), do: {:legacy, name}

  @spec resolve_engine(atom(), ALLM.Pipeline.Context.t()) ::
          {:context, atom(), ALLM.Pipeline.Context.t()}
  def resolve_engine(name, context), do: {:context, name, context}
end
