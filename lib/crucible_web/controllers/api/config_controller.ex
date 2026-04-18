defmodule CrucibleWeb.Api.ConfigController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias CrucibleWeb.Schemas.Common.{
    ConfigResponse,
    BudgetConfigResponse,
    UpdateBudgetRequest,
    OkResponse,
    ErrorResponse
  }

  tags(["Config"])
  security([%{"cookieAuth" => []}])

  operation(:index,
    summary: "Get orchestrator configuration",
    responses: [ok: {"Config", "application/json", ConfigResponse}]
  )

  def index(conn, _params) do
    config = Application.get_env(:crucible, :orchestrator, [])

    safe_config = %{
      pollIntervalMs: Keyword.get(config, :poll_interval_ms, 2000),
      dailyBudgetUsd: Keyword.get(config, :daily_budget_usd, 100.0),
      agentBudgetUsd: Keyword.get(config, :agent_budget_usd, 10.0),
      taskBudgetUsd: Keyword.get(config, :task_budget_usd, 50.0),
      maxConcurrentRuns: Keyword.get(config, :max_concurrent_runs, 3),
      repoRoot: Keyword.get(config, :repo_root, File.cwd!())
    }

    json(conn, safe_config)
  end

  operation(:claude_flow,
    summary: "Get claude-flow config YAML",
    responses: [
      ok:
        {"Config content", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             content: %OpenApiSpex.Schema{type: :string, nullable: true},
             path: %OpenApiSpex.Schema{type: :string}
           }
         }}
    ]
  )

  def claude_flow(conn, _params) do
    repo_root =
      Application.get_env(:crucible, :orchestrator, [])
      |> Keyword.get(:repo_root, File.cwd!())

    path = Path.join([repo_root, ".claude-flow", "config.yaml"])

    if File.exists?(path) do
      json(conn, %{content: File.read!(path), path: path})
    else
      json(conn, %{content: nil, path: path})
    end
  end

  operation(:update_claude_flow,
    summary: "Update claude-flow config YAML",
    request_body:
      {"Config content", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{content: %OpenApiSpex.Schema{type: :string}},
         required: [:content]
       }},
    responses: [
      ok: {"Success", "application/json", OkResponse},
      internal_server_error: {"Write failed", "application/json", ErrorResponse}
    ]
  )

  def update_claude_flow(conn, %{"content" => content}) when is_binary(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, _parsed} ->
        repo_root =
          Application.get_env(:crucible, :orchestrator, [])
          |> Keyword.get(:repo_root, File.cwd!())

        path = Path.join([repo_root, ".claude-flow", "config.yaml"])

        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        json(conn, %{ok: true})

      {:error, %YamlElixir.ParsingError{} = err} ->
        conn
        |> put_status(422)
        |> json(%{error: "invalid_yaml", message: Exception.message(err)})
    end
  rescue
    e ->
      require Logger
      Logger.error("ConfigController: update_claude_flow failed: #{Exception.message(e)}")
      conn |> put_status(500) |> json(%{error: "write_failed"})
  end

  def update_claude_flow(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing_content"})
  end

  operation(:env,
    summary: "Get environment variables (redacted)",
    responses: [
      ok:
        {"Env vars", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           additionalProperties: %OpenApiSpex.Schema{type: :string, nullable: true}
         }}
    ]
  )

  def env(conn, _params) do
    # Return a redacted set of env vars
    keys =
      ~w(PORT DATABASE_URL PHX_HOST DASHBOARD_AUTH GOOGLE_OAUTH_CLIENT_ID CORS_ALLOWED_ORIGINS CLUSTER_STRATEGY ALERTING_ENABLED)

    vars =
      Enum.map(keys, fn key ->
        val = System.get_env(key)
        {key, if(val, do: redact(key, val), else: nil)}
      end)
      |> Enum.into(%{})

    json(conn, vars)
  end

  operation(:budget_config,
    summary: "Get budget limits",
    responses: [ok: {"Budget config", "application/json", BudgetConfigResponse}]
  )

  def budget_config(conn, _params) do
    limits = Application.get_env(:crucible, :budget, [])

    json(conn, %{
      dailyLimit: Keyword.get(limits, :daily_limit, 100),
      agentLimit: Keyword.get(limits, :agent_limit, 10),
      taskLimit: Keyword.get(limits, :task_limit, 50)
    })
  end

  @budget_fields ~w(dailyLimit agentLimit taskLimit)
  @budget_min 0.01
  @budget_max 100_000.0

  operation(:update_budget,
    summary: "Update budget limits",
    description:
      "Updates runtime budget limits. Values must be numbers between 0.01 and 100,000. Not persisted across restarts.",
    request_body: {"Budget limits", "application/json", UpdateBudgetRequest},
    responses: [
      ok: {"Success", "application/json", OkResponse},
      unprocessable_entity: {"Validation error", "application/json", ErrorResponse}
    ]
  )

  def update_budget(conn, params) do
    require Logger

    with {:ok, changes} <- validate_budget_params(params) do
      current = Application.get_env(:crucible, :budget, [])
      previous = Keyword.take(current, [:daily_limit, :agent_limit, :task_limit])

      updated =
        current
        |> maybe_put(changes, "dailyLimit", :daily_limit)
        |> maybe_put(changes, "agentLimit", :agent_limit)
        |> maybe_put(changes, "taskLimit", :task_limit)

      Application.put_env(:crucible, :budget, updated)

      # Audit trail
      Logger.info(
        "Budget config updated: #{inspect(previous)} -> #{inspect(Keyword.take(updated, [:daily_limit, :agent_limit, :task_limit]))}"
      )

      :telemetry.execute(
        [:crucible, :config, :budget_updated],
        %{count: 1},
        %{changes: changes, previous: Map.new(previous)}
      )

      json(conn, %{ok: true})
    else
      {:error, message} ->
        conn |> put_status(422) |> json(%{error: "validation_error", message: message})
    end
  end

  defp validate_budget_params(params) do
    errors =
      @budget_fields
      |> Enum.filter(&Map.has_key?(params, &1))
      |> Enum.flat_map(fn field ->
        case params[field] do
          val when is_number(val) and val >= @budget_min and val <= @budget_max ->
            []

          val when is_number(val) ->
            ["#{field} must be between #{@budget_min} and #{@budget_max}, got #{val}"]

          val ->
            ["#{field} must be a number, got #{inspect(val) |> String.slice(0, 30)}"]
        end
      end)

    case errors do
      [] -> {:ok, Map.take(params, @budget_fields)}
      errs -> {:error, Enum.join(errs, "; ")}
    end
  end

  defp maybe_put(kw, changes, json_key, atom_key) do
    if Map.has_key?(changes, json_key) do
      Keyword.put(kw, atom_key, changes[json_key])
    else
      kw
    end
  end

  defp redact(key, val) do
    if String.contains?(key, ~w(SECRET KEY PASSWORD TOKEN)) do
      "***"
    else
      val
    end
  end
end
