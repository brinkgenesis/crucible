defmodule CrucibleWeb.Schemas.Common do
  @moduledoc "Shared OpenAPI schemas for common response types."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule ErrorResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "Error code"},
        message: %Schema{type: :string, description: "Human-readable message"}
      },
      required: [:error]
    })
  end

  defmodule OkResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OkResponse",
      type: :object,
      properties: %{ok: %Schema{type: :boolean}}
    })
  end

  defmodule HealthCheck do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HealthCheck",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["ok", "error", "degraded"]},
        message: %Schema{type: :string, nullable: true}
      },
      required: [:name, :status]
    })
  end

  defmodule HealthResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HealthResponse",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: ["ok", "degraded"]},
        checks: %Schema{type: :array, items: HealthCheck},
        version: %Schema{type: :string},
        commit: %Schema{type: :string},
        db: %Schema{type: :string},
        budget: %Schema{type: :object, additionalProperties: true},
        memory: %Schema{type: :object, additionalProperties: true},
        savings: %Schema{type: :object, additionalProperties: true},
        router: %Schema{type: :object, additionalProperties: %Schema{type: :boolean}},
        circuits: %Schema{type: :object, additionalProperties: true},
        slo: %Schema{type: :object, additionalProperties: true},
        runs: %Schema{type: :object, additionalProperties: true},
        executor: %Schema{type: :object, additionalProperties: true},
        dataFeeds: %Schema{type: :object, additionalProperties: true},
        monitoring: %Schema{type: :object, additionalProperties: true},
        timestamp: %Schema{type: :string, format: :"date-time"}
      },
      required: [:status]
    })
  end

  defmodule BudgetStatus do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BudgetStatus",
      type: :object,
      properties: %{
        dailySpent: %Schema{type: :number, format: :float, description: "USD spent today"},
        dailyLimit: %Schema{type: :number, format: :float, description: "Daily budget cap"},
        dailyRemaining: %Schema{type: :number, format: :float},
        isOverBudget: %Schema{type: :boolean},
        eventCount: %Schema{type: :integer}
      },
      required: [:dailySpent, :dailyLimit, :dailyRemaining, :isOverBudget, :eventCount]
    })
  end

  defmodule BudgetBreakdownItem do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BudgetBreakdownItem",
      type: :object,
      properties: %{
        model: %Schema{type: :string},
        cost: %Schema{type: :number, format: :float},
        count: %Schema{type: :integer}
      },
      required: [:model, :cost, :count]
    })
  end

  defmodule RunSummary do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RunSummary",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        workflowType: %Schema{type: :string},
        status: %Schema{
          type: :string,
          enum: ["pending", "running", "done", "failed", "cancelled", "orphaned"]
        },
        phaseCount: %Schema{type: :integer},
        budgetUsd: %Schema{type: :number, format: :float}
      },
      required: [:id, :workflowType, :status]
    })
  end

  defmodule RunDetail do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RunDetail",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        workflowType: %Schema{type: :string},
        status: %Schema{type: :string},
        budgetUsd: %Schema{type: :number, format: :float, nullable: true},
        branch: %Schema{type: :string, nullable: true},
        planSummary: %Schema{type: :string, nullable: true},
        phases: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string},
              name: %Schema{type: :string},
              type: %Schema{type: :string},
              status: %Schema{type: :string},
              retryCount: %Schema{type: :integer},
              maxRetries: %Schema{type: :integer},
              dependsOn: %Schema{type: :array, items: %Schema{type: :string}}
            }
          }
        }
      },
      required: [:id, :workflowType, :status]
    })
  end

  defmodule KanbanCard do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "KanbanCard",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        title: %Schema{type: :string},
        column: %Schema{
          type: :string,
          enum: ["ideation", "unassigned", "todo", "in_progress", "review", "done"]
        },
        archived: %Schema{type: :boolean},
        workflow: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        createdAt: %Schema{type: :string, format: :"date-time"},
        updatedAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :title, :column]
    })
  end

  defmodule CreateCardRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CreateCardRequest",
      type: :object,
      properties: %{
        title: %Schema{type: :string, description: "Card title"},
        column: %Schema{type: :string, default: "unassigned"},
        workflow: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      required: [:title]
    })
  end

  defmodule UpdateBudgetRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UpdateBudgetRequest",
      type: :object,
      properties: %{
        dailyLimit: %Schema{type: :number, format: :float, minimum: 0.01, maximum: 100_000},
        agentLimit: %Schema{type: :number, format: :float, minimum: 0.01, maximum: 100_000},
        taskLimit: %Schema{type: :number, format: :float, minimum: 0.01, maximum: 100_000}
      }
    })
  end

  defmodule ConfigResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConfigResponse",
      type: :object,
      properties: %{
        pollIntervalMs: %Schema{type: :integer},
        dailyBudgetUsd: %Schema{type: :number, format: :float},
        agentBudgetUsd: %Schema{type: :number, format: :float},
        taskBudgetUsd: %Schema{type: :number, format: :float},
        maxConcurrentRuns: %Schema{type: :integer},
        repoRoot: %Schema{type: :string}
      }
    })
  end

  defmodule BudgetConfigResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BudgetConfigResponse",
      type: :object,
      properties: %{
        dailyLimit: %Schema{type: :number, format: :float},
        agentLimit: %Schema{type: :number, format: :float},
        taskLimit: %Schema{type: :number, format: :float}
      }
    })
  end
end
