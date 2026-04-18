defmodule Crucible.AlertManager do
  @moduledoc """
  Subscribes to the PubSub alert feed, evaluates rules, deduplicates via cooldown,
  and dispatches webhook notifications.

  Disabled by default — set `ALERTING_ENABLED=true` to activate.
  """
  use GenServer
  require Logger

  alias Crucible.AlertManager.{Rules, Webhook}
  alias Crucible.Events

  @max_history 200

  # Explicit call timeouts — reads are fast (in-memory), webhook test hits the network.
  @call_timeout_read 5_000
  @call_timeout_external 30_000

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns list of currently active (unresolved) alert history."
  @spec alert_history(GenServer.server(), non_neg_integer()) :: [map()]
  def alert_history(server \\ __MODULE__, limit \\ 50) do
    GenServer.call(server, {:history, limit}, @call_timeout_read)
  end

  @doc "Send a test notification to the configured webhook."
  @spec test_webhook(GenServer.server()) :: :ok | {:error, term()}
  def test_webhook(server \\ __MODULE__) do
    GenServer.call(server, :test_webhook, @call_timeout_external)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    config = alerting_config()

    if config[:enabled] do
      Events.subscribe_alert_feed()
      Logger.info("AlertManager: started, webhook=#{config[:webhook_url] || "none"}")
    else
      Logger.info("AlertManager: disabled (set ALERTING_ENABLED=true to enable)")
    end

    rules = Keyword.get(opts, :rules, Rules.default_rules())

    {:ok,
     %{
       enabled: config[:enabled] || false,
       webhook_url: config[:webhook_url],
       webhook_format: config[:webhook_format] || :generic,
       default_cooldown_ms: config[:cooldown_ms] || 300_000,
       rules: rules,
       cooldowns: %{},
       history: []
     }}
  end

  @impl true
  def handle_info({:alert_event, event_type, data}, state) do
    if state.enabled do
      {:noreply, evaluate_and_dispatch(event_type, data, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:history, limit}, _from, state) do
    {:reply, Enum.take(state.history, limit), state}
  end

  def handle_call(:test_webhook, _from, state) do
    alert = %{
      severity: :info,
      rule: :test,
      message: "AlertManager test notification",
      timestamp: DateTime.utc_now(),
      data: %{}
    }

    result =
      if state.webhook_url do
        Webhook.send(alert, state.webhook_url, state.webhook_format)
      else
        {:error, :no_webhook_url}
      end

    {:reply, result, state}
  end

  # --- Private ---

  defp evaluate_and_dispatch(event_type, data, state) do
    matching_rules =
      Enum.filter(state.rules, fn rule -> rule.event_type == event_type end)

    Enum.reduce(matching_rules, state, fn rule, acc ->
      dispatch_if_not_cooled(rule, data, acc)
    end)
  end

  defp dispatch_if_not_cooled(rule, data, state) do
    cooldown_ms = rule[:cooldown_ms] || state.default_cooldown_ms
    now = System.monotonic_time(:millisecond)

    last_fired = Map.get(state.cooldowns, rule.name)

    if last_fired != nil and now - last_fired < cooldown_ms do
      state
    else
      alert = build_alert(rule, data)
      dispatch_alert(alert, state)

      state
      |> put_in([:cooldowns, Access.key(rule.name)], now)
      |> update_in([:history], fn h ->
        [alert | h] |> Enum.take(@max_history)
      end)
    end
  end

  defp build_alert(rule, data) do
    string_data = Map.new(data, fn {k, v} -> {to_string(k), v} end)

    %{
      severity: rule.severity,
      rule: rule.name,
      message: Rules.render_message(rule.message, string_data),
      timestamp: DateTime.utc_now(),
      data: data
    }
  end

  defp dispatch_alert(alert, state) do
    :telemetry.execute(
      [:crucible, :alert, :dispatched],
      %{count: 1},
      %{severity: alert.severity, rule: alert.rule}
    )

    if state.webhook_url do
      # Fire-and-forget via supervised task — failures are logged, not silent
      Task.Supervisor.start_child(Crucible.TaskSupervisor, fn ->
        case Webhook.send(alert, state.webhook_url, state.webhook_format) do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("AlertManager: webhook delivery failed: #{inspect(reason)}")
        end
      end)
    end
  end

  defp alerting_config do
    Application.get_env(:crucible, :alerting, [])
  end
end
