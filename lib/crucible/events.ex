defmodule Crucible.Events do
  @moduledoc """
  Central PubSub event bus for orchestrator events.
  Replaces file polling with reactive message passing where possible.

  ## Topics

  - `"team:<team_name>"` — team task status changes, completion
  - `"run:<run_id>"` — run lifecycle events (start, complete, failed, budget_paused)
  - `"phase:<run_id>:<phase_id>"` — phase lifecycle events
  """

  @pubsub Crucible.PubSub

  # --- Team events ---

  @doc "Subscribe to all events for a team."
  @spec subscribe_team(String.t()) :: :ok | {:error, term()}
  def subscribe_team(team_name) do
    Phoenix.PubSub.subscribe(@pubsub, "team:#{team_name}")
  end

  @doc "Broadcast a team task status update."
  @spec broadcast_team_update(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_team_update(team_name, snapshot) do
    Phoenix.PubSub.broadcast(@pubsub, "team:#{team_name}", {:team_update, team_name, snapshot})
  end

  @doc "Broadcast that all team tasks are completed."
  @spec broadcast_team_completed(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_team_completed(team_name, snapshot) do
    Phoenix.PubSub.broadcast(@pubsub, "team:#{team_name}", {:team_completed, team_name, snapshot})
  end

  # --- Run events ---

  @doc "Subscribe to all events for a run."
  @spec subscribe_run(String.t()) :: :ok | {:error, term()}
  def subscribe_run(run_id) do
    Phoenix.PubSub.subscribe(@pubsub, "run:#{run_id}")
  end

  @doc "Broadcast a run lifecycle event."
  @spec broadcast_run_event(String.t(), atom(), map()) :: :ok | {:error, term()}
  def broadcast_run_event(run_id, event_type, data \\ %{}) do
    Phoenix.PubSub.broadcast(@pubsub, "run:#{run_id}", {:run_event, run_id, event_type, data})
  end

  # --- Alert feed ---
  # Centralized topic for alertable events. Since Phoenix PubSub doesn't support
  # wildcards, the Orchestrator/BudgetTracker/CircuitBreaker broadcast here for
  # the AlertManager to consume.

  @doc "Subscribe to the centralized alert feed."
  @spec subscribe_alert_feed() :: :ok | {:error, term()}
  def subscribe_alert_feed do
    Phoenix.PubSub.subscribe(@pubsub, "alerts:feed")
  end

  @doc "Broadcast an alertable event to the alert feed."
  @spec broadcast_alert_event(atom(), map()) :: :ok | {:error, term()}
  def broadcast_alert_event(event_type, data) do
    Phoenix.PubSub.broadcast(@pubsub, "alerts:feed", {:alert_event, event_type, data})
  end

  # --- Log events ---

  @doc "Subscribe to live server log entries."
  @spec subscribe_logs() :: :ok | {:error, term()}
  def subscribe_logs do
    Phoenix.PubSub.subscribe(@pubsub, "logs:server")
  end

  @doc "Broadcast a new log entry to all subscribers."
  @spec broadcast_log_entry(map()) :: :ok | {:error, term()}
  def broadcast_log_entry(entry) do
    Phoenix.PubSub.broadcast(@pubsub, "logs:server", {:log_entry, entry})
  end

  # --- Phase events ---

  @doc "Subscribe to all events for a specific phase."
  @spec subscribe_phase(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe_phase(run_id, phase_id) do
    Phoenix.PubSub.subscribe(@pubsub, "phase:#{run_id}:#{phase_id}")
  end

  @doc "Broadcast a phase lifecycle event."
  @spec broadcast_phase_event(String.t(), String.t(), atom(), map()) :: :ok | {:error, term()}
  def broadcast_phase_event(run_id, phase_id, event_type, data \\ %{}) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "phase:#{run_id}:#{phase_id}",
      {:phase_event, run_id, phase_id, event_type, data}
    )
  end
end
