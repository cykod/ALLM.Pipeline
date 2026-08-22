defmodule Mix.Tasks.AllmPipeline.Names do
  @shortdoc "Emits the host registry's pipeline names + browser set as JSON"

  @moduledoc """
  Emits the installed `ALLM.Pipeline.Registry`'s per-pipeline metadata as a
  machine-readable list of names.

      mix allm_pipeline.names [--format json|elixir]

  `--format json` (the default) prints a single-line JSON object on stdout:

      {"pipeline_names":["committee",...],"browser_pipelines":["project","project_refresh","video"]}

  `pipeline_names` are the entries' `name`s rendered as strings, in declaration
  order; `browser_pipelines` are those with `browser: true`, same order. This is
  the committed-artifact source (`scripts/pipeline-names.json`) the shell
  `stage-scraper.sh` reads, and the input the `sst/scraper.ts` / entrypoint
  codegen consumes — a single source of truth for the pipeline-name allowlists
  that would otherwise be hand-mirrored across four runtimes.

  `--format elixir` prints the same two lists as an inspectable term, for a human
  eyeballing the registry.

  ## Host-agnostic registry discovery

  This is a **package** task and the package names no host module (a
  `{:amesbury, in_umbrella: true}` dep is a deliberate compile error — see
  `apps/allm_pipeline/CLAUDE.md` §1). So it finds the registry the same way
  `Mix.Tasks.AllmPipeline.Nilability` finds schema modules: it enumerates every
  loaded module via `Application.loaded_applications/0` + `Application.spec/2` and
  keeps the one exporting the `__allm_pipeline_registry__?/0` marker that
  `use ALLM.Pipeline.Registry` injects. A host must install exactly one registry
  — zero matches or more than one is a `Mix.raise`.

  It reads `name` and `browser` only, never `entry` (whose MFAs name host
  modules), so it stays leaf-clean.
  """

  use Mix.Task

  @requirements ["app.config"]

  @usage "Usage: mix allm_pipeline.names [--format json|elixir]"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    format =
      args
      |> OptionParser.parse(strict: [format: :string])
      |> parse_format!()

    pipelines = registry_module().__registry__(:pipelines)
    Mix.shell().info(render(pipelines, format))
    :ok
  end

  # `strict:` rather than `switches:` so an undeclared flag is reported rather
  # than silently dropped — the discipline `Mix.Tasks.AllmPipeline.Nilability`
  # established for the package's tasks.
  @spec parse_format!({keyword(), [String.t()], [{String.t(), String.t() | nil}]}) ::
          :json | :elixir
  defp parse_format!({_opts, _rest, [{switch, _value} | _]}),
    do: Mix.raise("unrecognised switch #{switch}. #{@usage}")

  defp parse_format!({_opts, [arg | _], []}),
    do: Mix.raise("unexpected argument #{inspect(arg)}. #{@usage}")

  defp parse_format!({opts, [], []}) do
    case Keyword.get(opts, :format, "json") do
      "json" -> :json
      "elixir" -> :elixir
      other -> Mix.raise("unknown --format #{inspect(other)}. #{@usage}")
    end
  end

  @doc """
  Render a validated `pipelines:` list as a `:json` or `:elixir` string.

  Pure — no I/O, no registry discovery — so it is unit-testable against a fixture
  registry's `__registry__(:pipelines)` structure.

  The JSON object's key order is fixed (`pipeline_names` then
  `browser_pipelines`) by assembling the string explicitly: an Elixir map does
  not preserve insertion order, so encoding one would reorder the keys and the
  bash `jq`/grep consumers depend on the order being stable.
  """
  @spec render([map()], :json | :elixir) :: String.t()
  def render(pipelines, :json) do
    names = Enum.map(pipelines, &to_string(&1.name))
    browser = for p <- pipelines, Map.get(p, :browser, false), do: to_string(p.name)

    ~s({"pipeline_names":#{Jason.encode!(names)},"browser_pipelines":#{Jason.encode!(browser)}})
  end

  def render(pipelines, :elixir) do
    names = Enum.map(pipelines, & &1.name)
    browser = for p <- pipelines, Map.get(p, :browser, false), do: p.name

    inspect([pipeline_names: names, browser_pipelines: browser], limit: :infinity)
  end

  @spec registry_module() :: module()
  defp registry_module do
    modules =
      for {app, _description, _vsn} <- Application.loaded_applications(),
          module <- Application.spec(app, :modules) || [],
          Code.ensure_loaded?(module),
          function_exported?(module, :__allm_pipeline_registry__?, 0) do
        module
      end

    case modules do
      [module] ->
        module

      [] ->
        Mix.raise(
          "no ALLM.Pipeline.Registry is installed — a host must `use ALLM.Pipeline.Registry`."
        )

      many ->
        Mix.raise(
          "ambiguous: more than one ALLM.Pipeline.Registry is loaded (#{inspect(many)}) — " <>
            "a host must install exactly one."
        )
    end
  end
end
