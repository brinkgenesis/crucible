defmodule Mix.Tasks.Crucible.Doctor do
  use Mix.Task

  @shortdoc "Runs environment diagnostics for Crucible"

  @moduledoc """
  Runs diagnostic checks on the Crucible environment.

  ## Usage

      mix crucible.doctor [--json]

  ## Options

    * `--json` - emit machine-readable JSON output instead of human-readable text

  ## Exit codes

    * 0 - all checks passed
    * 1 - one or more checks failed

  ## Checks

    * `elixir_version`   - Elixir >= 1.15 is required
    * `mix_env`          - Reports the current Mix environment
    * `database_config`  - DATABASE_URL env var is set (or Ecto config is present)
    * `config_validator` - Runs `Crucible.ConfigValidator.validate!()` if available
    * `node_name`        - Erlang node name is configured
  """

  @min_elixir_version "1.15.0"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean])
    json_mode = Keyword.get(opts, :json, false)

    checks = [
      check_elixir_version(),
      check_mix_env(),
      check_database_config(),
      check_config_validator(),
      check_node_name()
    ]

    any_failed? = Enum.any?(checks, fn %{status: s} -> s == :fail end)
    overall = if any_failed?, do: "error", else: "ok"

    if json_mode do
      emit_json(checks, overall)
    else
      emit_text(checks)
    end

    if any_failed? do
      System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Individual checks
  # ---------------------------------------------------------------------------

  defp check_elixir_version do
    version = System.version()

    status =
      case Version.compare(version, @min_elixir_version) do
        :lt -> :fail
        _ -> :pass
      end

    message = "#{version} (>= #{@min_elixir_version} required)"
    %{name: "elixir_version", status: status, message: message}
  end

  defp check_mix_env do
    env = Mix.env() |> to_string()
    %{name: "mix_env", status: :pass, message: env}
  end

  defp check_database_config do
    database_url = System.get_env("DATABASE_URL")

    ecto_config =
      Application.get_env(:crucible, Crucible.Repo)
      |> case do
        nil -> nil
        cfg -> Keyword.get(cfg, :url) || Keyword.get(cfg, :database)
      end

    cond do
      is_binary(database_url) and database_url != "" ->
        %{name: "database_config", status: :pass, message: "DATABASE_URL is set"}

      is_binary(ecto_config) and ecto_config != "" ->
        %{name: "database_config", status: :pass, message: "Ecto config is present"}

      true ->
        %{name: "database_config", status: :fail, message: "DATABASE_URL not set"}
    end
  end

  defp check_config_validator do
    try do
      case Crucible.ConfigValidator.validate!() do
        :ok ->
          %{name: "config_validator", status: :pass, message: "all required config present"}

        other ->
          %{
            name: "config_validator",
            status: :fail,
            message: "unexpected return: #{inspect(other)}"
          }
      end
    rescue
      e in RuntimeError ->
        %{name: "config_validator", status: :fail, message: Exception.message(e)}

      UndefinedFunctionError ->
        %{name: "config_validator", status: :skip, message: "not available in current env"}
    catch
      :exit, reason ->
        %{name: "config_validator", status: :skip, message: "skipped (#{inspect(reason)})"}

      kind, reason ->
        %{
          name: "config_validator",
          status: :skip,
          message: "skipped (#{kind}: #{inspect(reason)})"
        }
    end
  end

  defp check_node_name do
    node = Node.self()

    cond do
      node == :nonode@nohost ->
        %{name: "node_name", status: :fail, message: "node is not named (nonode@nohost)"}

      true ->
        %{name: "node_name", status: :pass, message: to_string(node)}
    end
  end

  # ---------------------------------------------------------------------------
  # Output helpers
  # ---------------------------------------------------------------------------

  defp emit_text(checks) do
    Enum.each(checks, fn %{name: name, status: status, message: message} ->
      label =
        case status do
          :pass -> "[OK]  "
          :fail -> "[FAIL]"
          :skip -> "[SKIP]"
        end

      Mix.shell().info("#{label} #{name}: #{message}")
    end)
  end

  defp emit_json(checks, overall) do
    checks_json =
      Enum.map(checks, fn %{name: name, status: status, message: message} ->
        status_str =
          case status do
            :pass -> "pass"
            :fail -> "fail"
            :skip -> "skip"
          end

        ~s(    {"name": "#{name}", "status": "#{status_str}", "message": "#{escape_json(message)}"})
      end)
      |> Enum.join(",\n")

    json = """
    {
      "status": "#{overall}",
      "checks": [
    #{checks_json}
      ]
    }\
    """

    Mix.shell().info(json)
  end

  # Minimal JSON string escaping for message values
  defp escape_json(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end
