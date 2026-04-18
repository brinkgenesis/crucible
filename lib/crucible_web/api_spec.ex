defmodule CrucibleWeb.ApiSpec do
  @moduledoc "OpenAPI 3.0 spec for the Infra Orchestrator API."
  alias OpenApiSpex.{Info, OpenApi, Paths, Server, SecurityScheme, Components}
  alias CrucibleWeb.{Endpoint, Router}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(Endpoint)],
      info: %Info{
        title: "Infra Orchestrator API",
        version: "1.0.0",
        description: """
        Agentic orchestration control plane — manages workflow runs, traces, \
        teams, budget, kanban, memory vault, and model routing.
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "API key passed as Bearer token in Authorization header"
          },
          "cookieAuth" => %SecurityScheme{
            type: "apiKey",
            in: "cookie",
            name: "_crucible_key"
          }
        }
      },
      security: [%{"bearerAuth" => []}, %{"cookieAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
