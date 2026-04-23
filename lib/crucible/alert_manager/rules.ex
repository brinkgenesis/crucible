defmodule Crucible.AlertManager.Rules do
  @moduledoc """
  Built-in alert rule definitions.

  Each rule has:
  - `:name` — unique atom identifier
  - `:event_type` — the alert feed event type that triggers evaluation
  - `:severity` — `:critical | :warning | :info`
  - `:cooldown_ms` — minimum interval between repeated alerts of this type
  - `:message` — template string with `{key}` placeholders
  """

  @type event_name ::
          :run_failed
          | :run_exhausted
          | :budget_exceeded
          | :budget_paused
          | :circuit_breaker_open
          | :sandbox_pool_exhausted

  @type severity :: :critical | :warning

  @type rule :: %{
          name: event_name(),
          event_type: event_name(),
          severity: severity(),
          cooldown_ms: pos_integer(),
          message: String.t()
        }

  @spec default_rules() :: [rule()]
  def default_rules do
    [
      %{
        name: :run_failed,
        event_type: :run_failed,
        severity: :warning,
        cooldown_ms: 60_000,
        message: "Run {run_id} failed: {reason}"
      },
      %{
        name: :run_exhausted,
        event_type: :run_exhausted,
        severity: :warning,
        cooldown_ms: 60_000,
        message: "Run {run_id} exhausted all retries"
      },
      %{
        name: :budget_exceeded,
        event_type: :budget_exceeded,
        severity: :critical,
        cooldown_ms: 300_000,
        message: "Daily budget exceeded: ${spent} of ${limit}"
      },
      %{
        name: :budget_paused,
        event_type: :budget_paused,
        severity: :warning,
        cooldown_ms: 300_000,
        message: "Run {run_id} paused due to budget limits"
      },
      %{
        name: :circuit_breaker_open,
        event_type: :circuit_breaker_open,
        severity: :warning,
        cooldown_ms: 300_000,
        message: "Circuit breaker opened for {service}: {failures} consecutive failures"
      },
      %{
        name: :sandbox_pool_exhausted,
        event_type: :sandbox_pool_exhausted,
        severity: :warning,
        cooldown_ms: 60_000,
        message: "Sandbox pool exhausted: {active} active containers, pool target {pool_target}"
      }
    ]
  end

  @doc "Render a rule's message template with data placeholders."
  @spec render_message(String.t(), map()) :: String.t()
  def render_message(template, data) do
    Enum.reduce(data, template, fn {key, value}, acc ->
      String.replace(acc, "{#{key}}", to_string(value))
    end)
  end
end
