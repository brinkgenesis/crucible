defmodule Crucible.CircuitBreaker do
  @moduledoc """
  File-persisted per-workflow circuit breaker for the Oban/WorkflowJob execution path.
  Prevents runaway retries by tracking consecutive failures per workflow name.
  Uses system time for cross-restart persistence at `.claude-flow/learning/circuit-breakers.json`.

  See also `Crucible.Orchestrator.CircuitBreaker` for the in-memory variant
  used by the GenServer poll/dispatch path (uses monotonic time, no persistence).

  State machine:
    closed  → open       (after `threshold` consecutive failures)
    open    → half_open   (after cooldown expires)
    half_open → closed    (canary success)
    half_open → open      (canary failure, extended cooldown)
  """

  require Logger

  @threshold 3
  @initial_cooldown_ms 30 * 60_000
  @extended_cooldown_ms 60 * 60_000

  @type state :: :closed | :open | :half_open

  @type breaker :: %{
          consecutive_failures: non_neg_integer(),
          state: state(),
          opened_at: integer() | nil,
          cooldown_ms: pos_integer(),
          last_failed_at: integer() | nil
        }

  @type store :: %{optional(String.t()) => breaker()}

  @doc "Check if the circuit is open for a workflow. Returns `{:ok, :allowed}` or `{:blocked, reason}`."
  @spec check(String.t(), String.t()) :: {:ok, :allowed} | {:blocked, String.t()}
  def check(infra_home, workflow_name) do
    store = load(infra_home)
    cb = Map.get(store, workflow_name)

    cond do
      is_nil(cb) or cb.state == :closed ->
        {:ok, :allowed}

      cb.state == :open ->
        elapsed = now_ms() - (cb.opened_at || 0)

        if elapsed >= cb.cooldown_ms do
          # Transition to half_open — allow canary
          updated = %{cb | state: :half_open}
          save(infra_home, Map.put(store, workflow_name, updated))
          {:ok, :allowed}
        else
          remaining_min = ceil((cb.cooldown_ms - elapsed) / 60_000)

          {:blocked,
           "Circuit open for \"#{workflow_name}\" — #{remaining_min}min cooldown remaining"}
        end

      cb.state == :half_open ->
        {:ok, :allowed}
    end
  end

  @doc """
  Record the outcome of a workflow run. Updates the circuit breaker state.

  Options:
    - `:category` — `:workflow` (default) or `:infrastructure`.
      Infrastructure failures (branch contention, tmux errors, git failures)
      are logged but do NOT increment consecutive_failures or trip the breaker.
  """
  @spec record(String.t(), String.t(), boolean(), keyword()) :: :ok
  def record(infra_home, workflow_name, success?, opts \\ []) do
    category = Keyword.get(opts, :category, :workflow)

    # Infrastructure failures are logged but don't count toward the threshold
    if not success? and category == :infrastructure do
      Logger.warning(
        "CircuitBreaker: infrastructure failure for \"#{workflow_name}\" (not counted toward threshold)"
      )
    else
      do_record(infra_home, workflow_name, success?)
    end

    :ok
  end

  @doc "Reset circuit breaker for a specific workflow (manual override)."
  @spec reset(String.t(), String.t()) :: :ok
  def reset(infra_home, workflow_name) do
    store = load(infra_home)
    save(infra_home, Map.delete(store, workflow_name))
    :ok
  end

  @doc "Get the current state of a circuit breaker."
  @spec get_state(String.t(), String.t()) :: breaker() | nil
  def get_state(infra_home, workflow_name) do
    store = load(infra_home)
    Map.get(store, workflow_name)
  end

  # --- Private ---

  defp do_record(infra_home, workflow_name, success?) do
    store = load(infra_home)

    cb =
      Map.get(store, workflow_name, %{
        consecutive_failures: 0,
        state: :closed,
        opened_at: nil,
        cooldown_ms: @initial_cooldown_ms,
        last_failed_at: nil
      })

    updated =
      if success? do
        %{cb | consecutive_failures: 0, state: :closed, cooldown_ms: @initial_cooldown_ms}
      else
        cb = %{cb | consecutive_failures: cb.consecutive_failures + 1, last_failed_at: now_ms()}

        cond do
          cb.state == :half_open ->
            Logger.warning(
              "CircuitBreaker: canary failed for \"#{workflow_name}\", extending cooldown to #{@extended_cooldown_ms}ms"
            )

            %{
              cb
              | state: :open,
                opened_at: now_ms(),
                cooldown_ms: @extended_cooldown_ms
            }

          cb.consecutive_failures >= @threshold ->
            Logger.warning(
              "CircuitBreaker: opening for \"#{workflow_name}\" after #{cb.consecutive_failures} failures"
            )

            %{cb | state: :open, opened_at: now_ms()}

          true ->
            cb
        end
      end

    save(infra_home, Map.put(store, workflow_name, updated))
    :ok
  end

  # --- Persistence ---

  @spec load(String.t()) :: store()
  defp load(infra_home) do
    path = store_path(infra_home)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, raw} -> deserialize(raw)
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @spec save(String.t(), store()) :: :ok
  defp save(infra_home, store) do
    path = store_path(infra_home)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(serialize(store), pretty: true))
    :ok
  end

  defp store_path(infra_home) do
    Path.join([infra_home, ".claude-flow", "learning", "circuit-breakers.json"])
  end

  defp serialize(store) do
    Map.new(store, fn {name, cb} ->
      {name,
       %{
         "consecutiveFailures" => cb.consecutive_failures,
         "state" => to_string(cb.state),
         "openedAt" => cb.opened_at,
         "cooldownMs" => cb.cooldown_ms,
         "lastFailedAt" => cb.last_failed_at
       }}
    end)
  end

  defp deserialize(raw) do
    Map.new(raw, fn {name, data} ->
      {name,
       %{
         consecutive_failures: Map.get(data, "consecutiveFailures", 0),
         state: parse_state(Map.get(data, "state", "closed")),
         opened_at: Map.get(data, "openedAt"),
         cooldown_ms: Map.get(data, "cooldownMs", @initial_cooldown_ms),
         last_failed_at: Map.get(data, "lastFailedAt")
       }}
    end)
  end

  defp parse_state("open"), do: :open
  defp parse_state("half_open"), do: :half_open
  defp parse_state(_), do: :closed

  defp now_ms, do: System.system_time(:millisecond)
end
