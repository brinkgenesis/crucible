defmodule CrucibleWeb.Api.TokensController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.{LLMUsageReader, SavingsReader}

  operation(:llm,
    summary: "LLM token usage summary",
    description: "Returns aggregated LLM token usage across sessions, models, and projects.",
    tags: ["Tokens"],
    parameters: [
      runId: [in: :query, type: :string, required: false, description: "Filter to a specific run ID"],
      includeSubscription: [in: :query, type: :string, required: false, description: "Include subscription sessions (default true)"]
    ],
    responses: [ok: {"LLM usage summary", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )
  def llm(conn, params) do
    summary =
      safe_call(
        fn ->
          LLMUsageReader.build_summary(
            run_id: blank_to_nil(Map.get(params, "runId")),
            include_subscription: include_subscription?(params)
          )
        end,
        empty_usage_summary(include_subscription?(params))
      )

    json(conn, summary)
  end

  operation(:savings,
    summary: "Token savings summary",
    description: "Returns global token savings from prompt compaction across all projects.",
    tags: ["Tokens"],
    responses: [ok: {"Token savings summary", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )
  def savings(conn, _params) do
    summary =
      safe_call(fn -> SavingsReader.build_global_savings() end, %{
        "totalEvents" => 0,
        "totalCompactTokens" => 0,
        "totalNaiveTokens" => 0,
        "totalSavedTokens" => 0,
        "totalSavedRatio" => 0.0,
        "byProject" => %{},
        "recentEvents" => []
      })

    json(conn, summary)
  end

  operation(:daily,
    summary: "Daily token usage",
    description: "Returns token usage aggregated by date for the past N days.",
    tags: ["Tokens"],
    parameters: [
      days: [in: :query, type: :integer, required: false, description: "Number of past days to include (default 14)"]
    ],
    responses: [ok: {"Daily token usage", "application/json", %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}]
  )
  def daily(conn, params) do
    days = parse_days(params, 14)

    summary =
      safe_call(fn -> LLMUsageReader.build_summary() end, empty_usage_summary(true))

    cutoff =
      Date.utc_today()
      |> Date.add(-days)
      |> Date.to_iso8601()

    result =
      summary["byDate"]
      |> Enum.filter(fn {date, _tokens} -> date >= cutoff end)
      |> Enum.sort_by(fn {date, _tokens} -> date end)
      |> Enum.map(fn {date, tokens} -> %{date: date, tokens: tokens} end)

    json(conn, result)
  end

  operation(:by_model,
    summary: "Token usage by model",
    description: "Returns token usage aggregated by model for the past N days.",
    tags: ["Tokens"],
    parameters: [
      days: [in: :query, type: :integer, required: false, description: "Number of past days to include (default 1)"]
    ],
    responses: [ok: {"Token usage by model", "application/json", %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}]
  )
  def by_model(conn, params) do
    days = parse_days(params, 1)

    summary =
      safe_call(fn -> LLMUsageReader.build_summary() end, empty_usage_summary(true))

    cutoff =
      Date.utc_today()
      |> Date.add(-days)
      |> Date.to_iso8601()

    result =
      summary["byDateModel"]
      |> Enum.reduce(%{}, fn {date, model_map}, acc ->
        if date < cutoff do
          acc
        else
          Enum.reduce(model_map, acc, fn {model, tokens}, inner ->
            Map.update(inner, model, tokens, &(&1 + tokens))
          end)
        end
      end)
      |> Enum.map(fn {model, tokens} -> %{model: model, tokens: tokens} end)
      |> Enum.filter(&(&1.tokens > 0))
      |> Enum.sort_by(& &1.tokens, :desc)

    json(conn, result)
  end

  defp include_subscription?(params),
    do: Map.get(params, "includeSubscription", "true") != "false"

  defp parse_days(params, default) do
    case Map.get(params, "days") do
      nil ->
        default

      days when is_integer(days) and days > 0 ->
        days

      days when is_binary(days) ->
        case Integer.parse(days) do
          {n, ""} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  defp empty_usage_summary(include_subscription) do
    %{
      "totalInputTokens" => 0,
      "totalOutputTokens" => 0,
      "totalCacheCreation" => 0,
      "totalCacheRead" => 0,
      "totalTokens" => 0,
      "totalTurns" => 0,
      "sessionCount" => 0,
      "includesSubscription" => include_subscription,
      "sessions" => [],
      "byModel" => %{},
      "byProject" => %{},
      "byDate" => %{},
      "byDateModel" => %{}
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
