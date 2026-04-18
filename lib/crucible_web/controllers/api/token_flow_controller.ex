defmodule CrucibleWeb.Api.TokenFlowController do
  @moduledoc """
  API endpoints for Token Flow: pipeline metrics, flywheels, agent identity, attention budget.
  """
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.{TokenValue, Flywheels, AgentIdentity, AttentionBudget}

  tags(["Token Flow"])
  security([%{"cookieAuth" => []}])

  operation(:pipeline,
    summary: "Token value pipeline metrics",
    description: "Returns computed token value metrics derived from vault note analysis.",
    responses: [
      ok: {"Pipeline metrics", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  operation(:flywheels,
    summary: "Trust flywheel state",
    description: "Returns the current trust flywheel state and improvement recommendations.",
    responses: [
      ok: {"Flywheel state", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  operation(:agents,
    summary: "List KYA agent identities",
    description: "Returns all registered agent identity profiles.",
    responses: [
      ok: {"Agent identities", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  operation(:agent,
    summary: "Get agent identity",
    description: "Returns the identity profile for a single agent by name.",
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Agent name"]
    ],
    responses: [
      ok: {"Agent identity", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: {"Not found", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  operation(:recommend,
    summary: "Agent recommendation",
    description: "Returns recommended agents for a given task type.",
    parameters: [
      task_type: [in: :path, type: :string, required: true, description: "Task type"]
    ],
    responses: [
      ok: {"Recommendations", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  operation(:attention,
    summary: "Attention budget summary",
    description: "Returns the global attention budget allocation summary.",
    responses: [
      ok: {"Budget summary", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  operation(:attention_agent,
    summary: "Agent attention status",
    description: "Returns the attention budget status for a specific agent.",
    parameters: [
      agent_id: [in: :path, type: :string, required: true, description: "Agent ID"]
    ],
    responses: [
      ok: {"Agent attention status", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  @doc "GET /api/v1/token-flow/pipeline — token value pipeline metrics"
  def pipeline(conn, _params) do
    notes = scan_vault_notes()
    metrics = TokenValue.pipeline_metrics(notes)
    json(conn, metrics)
  end

  @doc "GET /api/v1/token-flow/flywheels — trust flywheel state"
  def flywheels(conn, _params) do
    state = Flywheels.compute()
    recs = Flywheels.recommendations(state)
    json(conn, Map.put(state, :recommendations, recs))
  end

  @doc "GET /api/v1/token-flow/agents — KYA agent identities"
  def agents(conn, _params) do
    agents = AgentIdentity.list_agents()
    json(conn, %{agents: agents})
  end

  @doc "GET /api/v1/token-flow/agents/:name — single agent identity"
  def agent(conn, %{"name" => name}) do
    case AgentIdentity.get_identity(name) do
      nil -> conn |> put_status(404) |> json(%{error: "agent not found"})
      identity -> json(conn, identity)
    end
  end

  @doc "GET /api/v1/token-flow/agents/:name/recommend/:task_type — agent recommendation"
  def recommend(conn, %{"task_type" => task_type}) do
    recs = AgentIdentity.recommend(task_type)
    json(conn, %{recommendations: recs})
  end

  @doc "GET /api/v1/token-flow/attention — attention budget summary"
  def attention(conn, _params) do
    summary = AttentionBudget.summary()
    json(conn, summary)
  end

  @doc "GET /api/v1/token-flow/attention/agent/:agent_id — agent attention status"
  def attention_agent(conn, %{"agent_id" => agent_id}) do
    status = AttentionBudget.agent_status(agent_id)
    json(conn, status)
  end

  # --- Helpers ---

  defp scan_vault_notes do
    vault_path = Path.join(File.cwd!(), "memory")
    dirs = ["lessons", "observations", "decisions", "handoffs", "preferences", "tensions", "mocs"]

    dirs
    |> Enum.flat_map(fn dir ->
      dir_path = Path.join(vault_path, dir)

      if File.dir?(dir_path) do
        dir_path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.take(200)
        |> Enum.map(fn file ->
          path = Path.join(dir_path, file)
          content = File.read!(path) |> String.slice(0..2000)

          %{
            type: dir |> String.trim_trailing("s"),
            content: content,
            tags: extract_tags(content),
            priority: extract_priority(content)
          }
        end)
      else
        []
      end
    end)
  rescue
    _ -> []
  end

  defp extract_tags(content) do
    case Regex.run(~r/tags:\s*\[([^\]]*)\]/, content) do
      [_, tags_str] ->
        tags_str |> String.split(",") |> Enum.map(&String.trim/1)

      _ ->
        []
    end
  end

  defp extract_priority(content) do
    case Regex.run(~r/priority:\s*(\w+)/, content) do
      [_, priority] -> priority
      _ -> "background"
    end
  end
end
