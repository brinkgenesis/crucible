defmodule Crucible.CiLog.Reviewer do
  @moduledoc """
  CI Log Reviewer — analyzes CI failure logs via the model router at complexity 4.

  Port of `lib/ci/log-reviewer.ts` from infra.

  Public API:
    - `review/1` — analyze a `CiLogEvent` using the default router
    - `review/2` — analyze with a custom router function (for testing)
  """

  require Logger

  alias Crucible.Schema.CiLogEvent

  @raw_log_char_limit 3000

  @categories ~w(test_failure build_failure dependency_warning performance_regression flaky_test infra_issue)
  @severities ~w(critical warning info)

  @system_prompt """
  You are a CI/CD log analyst. Analyze the provided CI run log and extract structured insights. \
  Always respond with valid JSON matching the schema exactly. Be concise and actionable.\
  """

  @type analysis :: %{
          category: String.t(),
          severity: String.t(),
          title: String.t(),
          summary: String.t(),
          suggested_fix: String.t(),
          is_recurring: boolean()
        }

  @doc "Analyze a CI log event via the model router at complexity 4."
  @spec review(CiLogEvent.t()) :: {:ok, analysis()}
  def review(%CiLogEvent{} = event) do
    review(event, &default_route/1)
  end

  @doc "Analyze a CI log event using a custom router function."
  @spec review(CiLogEvent.t(), (map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, analysis()}
  def review(%CiLogEvent{} = event, router_fn) when is_function(router_fn, 1) do
    request = %{
      prompt: build_user_prompt(event),
      system_prompt: @system_prompt,
      complexity_hint: 4,
      strategy: :cost,
      max_tokens: 1024
    }

    case router_fn.(request) do
      {:ok, %{text: text}} ->
        case parse_analysis(text) do
          {:ok, analysis} ->
            {:ok, analysis}

          :error ->
            Logger.warning(
              "CI log review: JSON parse failed for event #{event.id}, using fallback"
            )

            {:ok, parse_error_fallback(text)}
        end

      {:error, reason} ->
        Logger.warning("CI log review failed for event #{event.id}: #{inspect(reason)}")
        {:ok, parse_error_fallback(inspect(reason))}
    end
  end

  @doc "Build the user prompt for a CI log event."
  @spec build_user_prompt(CiLogEvent.t()) :: String.t()
  def build_user_prompt(%CiLogEvent{} = event) do
    truncated_log = String.slice(event.raw_log || "", -@raw_log_char_limit..-1//1)

    """
    Analyze this CI run failure and respond with JSON only:

    Workflow: #{event.workflow_name}
    Conclusion: #{event.conclusion}
    Duration: #{event.duration_ms}ms

    Log (last #{@raw_log_char_limit} chars):
    #{truncated_log}

    Response schema:
    {
      "category": "test_failure|build_failure|dependency_warning|performance_regression|flaky_test|infra_issue",
      "severity": "critical|warning|info",
      "title": "Short descriptive title (max 80 chars)",
      "summary": "2-3 sentence root cause analysis",
      "suggestedFix": "Specific actionable fix suggestion",
      "isRecurring": true|false
    }\
    """
  end

  @doc "Parse a JSON analysis response into an analysis map. Returns {:ok, analysis} or :error."
  @spec parse_analysis(String.t()) :: {:ok, analysis()} | :error
  def parse_analysis(text) when is_binary(text) do
    with {:ok, json_str} <- extract_json(text),
         {:ok, parsed} <- Jason.decode(json_str),
         {:ok, analysis} <- validate_fields(parsed) do
      {:ok, analysis}
    else
      _ -> :error
    end
  end

  # --- Private ---

  defp default_route(request), do: Crucible.Router.route(request)

  defp extract_json(text) do
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json | _] -> {:ok, json}
      _ -> :error
    end
  end

  defp validate_fields(parsed) when is_map(parsed) do
    with category when category in @categories <- parsed["category"],
         severity when severity in @severities <- parsed["severity"],
         title when is_binary(title) and title != "" <- parsed["title"],
         summary when is_binary(summary) and summary != "" <- parsed["summary"],
         suggested_fix when is_binary(suggested_fix) and suggested_fix != "" <-
           parsed["suggestedFix"],
         is_recurring when is_boolean(is_recurring) <- parsed["isRecurring"] do
      {:ok,
       %{
         category: category,
         severity: severity,
         title: title,
         summary: summary,
         suggested_fix: suggested_fix,
         is_recurring: is_recurring
       }}
    else
      _ -> :error
    end
  end

  defp validate_fields(_), do: :error

  defp parse_error_fallback(raw_response) when is_binary(raw_response) do
    %{
      category: "infra_issue",
      severity: "warning",
      title: "Parse error",
      summary: String.slice(raw_response, 0, 500),
      suggested_fix: "Manual review needed",
      is_recurring: false
    }
  end
end
