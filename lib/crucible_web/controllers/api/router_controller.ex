defmodule CrucibleWeb.Api.RouterController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.ModelRegistry
  alias CrucibleWeb.HealthSnapshot

  tags(["Router"])
  security([%{"cookieAuth" => []}])

  operation(:models,
    summary: "List available models",
    description: "Returns the catalogue of supported LLM models with provider and pricing info.",
    responses: [
      ok: {"Model catalogue", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  operation(:health,
    summary: "Router health",
    description: "Returns per-provider health status as seen by the model router.",
    responses: [
      ok: {"Provider health", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  operation(:circuits,
    summary: "Circuit breaker states",
    description:
      "Returns the current open/closed/half-open state of each provider circuit breaker.",
    responses: [
      ok: {"Circuit states", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  operation(:reset_circuit,
    summary: "Reset circuit breaker",
    description: "Forces a provider circuit breaker back to closed state.",
    parameters: [
      provider: [
        in: :path,
        type: :string,
        required: true,
        description: "Provider name (anthropic, google, minimax, openai, groq)"
      ]
    ],
    responses: [
      ok: {"Reset confirmation", "application/json", %OpenApiSpex.Schema{type: :object}},
      bad_request: {"Unknown provider", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  @models %{
    "claude-opus-4" => %{
      displayName: "Claude Opus 4",
      provider: "anthropic",
      inputPerMillion: 15.0,
      outputPerMillion: 75.0
    },
    "claude-sonnet-4" => %{
      displayName: "Claude Sonnet 4",
      provider: "anthropic",
      inputPerMillion: 3.0,
      outputPerMillion: 15.0
    },
    "claude-haiku-3.5" => %{
      displayName: "Claude Haiku 3.5",
      provider: "anthropic",
      inputPerMillion: 0.25,
      outputPerMillion: 1.25
    },
    "gemini-2.0-flash" => %{
      displayName: "Gemini 2.0 Flash",
      provider: "google",
      inputPerMillion: 0.10,
      outputPerMillion: 0.40
    },
    "minimax-m2" => %{
      displayName: "MiniMax M2",
      provider: "minimax",
      inputPerMillion: 1.10,
      outputPerMillion: 4.40
    }
  }

  def models(conn, _params) do
    json(conn, @models)
  end

  def health(conn, _params) do
    providers = HealthSnapshot.router_health()
    json(conn, providers)
  end

  def circuits(conn, _params) do
    status = safe_call(fn -> ModelRegistry.circuit_states() end, %{})
    json(conn, status)
  end

  # Provider circuits (anthropic/google/...) plus internal service circuits
  # tripped by the execution path (SDK adapters, sandbox daemon). All are
  # reachable from the same reset endpoint so ops can recover without a
  # BEAM restart.
  @resettable_services ~w(anthropic google minimax openai groq
                          elixir_sdk claude_sdk model_router
                          api_server docker_daemon)a

  # The path parameter is historically called `provider` but now also accepts
  # internal service names (elixir_sdk, docker_daemon, …). The response field
  # is kept as `provider` for backwards compatibility with existing callers.
  def reset_circuit(conn, %{"provider" => provider}) do
    case safe_service_atom(provider) do
      {:ok, service} ->
        Crucible.ExternalCircuitBreaker.reset(service)
        json(conn, %{status: "ok", provider: provider, state: "closed"})

      :error ->
        conn |> put_status(400) |> json(%{error: "unknown_service", provider: provider})
    end
  end

  defp safe_service_atom(service) when is_binary(service) do
    atom = String.to_existing_atom(service)
    if atom in @resettable_services, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end
end
