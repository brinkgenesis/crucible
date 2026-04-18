defmodule Crucible.Orchestrator.CircuitBreaker do
  @moduledoc """
  In-memory per-workflow circuit breaker for the GenServer execution path.
  Opens after consecutive failures from DISTINCT runs, enters half_open after cooldown.
  Uses monotonic time (suitable for in-process comparisons, no persistence).

  Key design decisions:
  - Retries of the same run don't count as additional failures (prevents cascade)
  - Circuit-open rejections don't count as failures
  - 5-minute cooldown (not 30min) — fast iteration in dev
  - Manual reset via `reset/0` for operational control
  """

  @default_cooldown_ms 5 * 60_000
  @extended_cooldown_ms 15 * 60_000
  @failure_threshold 3

  @type state :: %{
          state: :closed | :open | :half_open,
          consecutive_failures: non_neg_integer(),
          opened_at: integer() | nil,
          cooldown_ms: pos_integer(),
          last_failed_at: integer() | nil,
          last_failed_run_id: String.t() | nil
        }

  @doc "Returns a new closed circuit breaker."
  @spec new() :: state()
  def new do
    %{
      state: :closed,
      consecutive_failures: 0,
      opened_at: nil,
      cooldown_ms: @default_cooldown_ms,
      last_failed_at: nil,
      last_failed_run_id: nil
    }
  end

  @doc "Manually reset to closed state."
  @spec reset(state()) :: state()
  def reset(_cb), do: new()

  @doc "Checks if the circuit is blocking requests."
  @spec check(state()) :: {:ok, state()} | {:blocked, String.t(), state()}
  def check(%{state: :closed} = cb), do: {:ok, cb}
  def check(%{state: :half_open} = cb), do: {:ok, cb}

  def check(%{state: :open} = cb) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - (cb.opened_at || now)

    if elapsed >= cb.cooldown_ms do
      {:ok, %{cb | state: :half_open}}
    else
      remaining_min = ceil((cb.cooldown_ms - elapsed) / 60_000)
      {:blocked, "Cooldown #{remaining_min}min remaining", cb}
    end
  end

  @doc "Records a success, resets the circuit."
  @spec record_success(state()) :: state()
  def record_success(_cb), do: new()

  @doc """
  Records a failure from a specific run.
  Retries of the same run_id don't increment the failure counter —
  only distinct run failures count toward the threshold.
  """
  @spec record_failure(state(), String.t() | nil) :: state()
  def record_failure(cb, run_id \\ nil)

  def record_failure(%{state: :half_open} = cb, _run_id) do
    # Canary failed — reopen with extended cooldown
    %{
      cb
      | state: :open,
        opened_at: System.monotonic_time(:millisecond),
        cooldown_ms: @extended_cooldown_ms,
        consecutive_failures: cb.consecutive_failures + 1,
        last_failed_at: System.monotonic_time(:millisecond),
        last_failed_run_id: nil
    }
  end

  def record_failure(cb, run_id) do
    # Don't count retries of the same run as additional failures
    if run_id != nil and run_id == cb.last_failed_run_id do
      cb
    else
      failures = cb.consecutive_failures + 1

      if failures >= @failure_threshold do
        %{
          cb
          | state: :open,
            opened_at: System.monotonic_time(:millisecond),
            consecutive_failures: failures,
            last_failed_at: System.monotonic_time(:millisecond),
            last_failed_run_id: run_id
        }
      else
        %{
          cb
          | consecutive_failures: failures,
            last_failed_at: System.monotonic_time(:millisecond),
            last_failed_run_id: run_id
        }
      end
    end
  end
end
