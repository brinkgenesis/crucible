defmodule Crucible.DreamGate do
  @moduledoc """
  Three-gate trigger for background memory consolidation.

  Port of `lib/cli/self-improvement/dream-gate.ts` from infra.

  Implements the three-gate pattern that prevents both over-dreaming
  (wasting tokens) and under-dreaming (stale memory):

    Gate 1: Time — enough hours since last consolidation
    Gate 2: Sessions — enough sessions with meaningful new knowledge
    Gate 3: Lock — no other consolidation is currently running

  All three must pass simultaneously before consolidation activates.

  State persisted at: `{infra_home}/.claude-flow/learning/dream-state.json`
  Lock file at: `{infra_home}/.claude-flow/learning/dream.lock`
  """

  require Logger

  @default_min_hours 4
  @default_min_sessions 3
  @stale_lock_ms 30 * 60 * 1_000

  @learning_dir ".claude-flow/learning"
  @state_file "dream-state.json"
  @lock_file "dream.lock"

  @type gate_result :: %{
          open: boolean(),
          gates: %{
            time: %{passed: boolean(), hours_since_last: float(), required: number()},
            sessions: %{passed: boolean(), count: non_neg_integer(), required: non_neg_integer()},
            lock: %{passed: boolean(), reason: String.t() | nil}
          }
        }

  @type dream_state :: %{
          last_consolidated_at: String.t() | nil,
          sessions_since_last: non_neg_integer(),
          total_runs: non_neg_integer(),
          total_tokens_spent: non_neg_integer(),
          total_cost_usd: float()
        }

  @empty_state %{
    last_consolidated_at: nil,
    sessions_since_last: 0,
    total_runs: 0,
    total_tokens_spent: 0,
    total_cost_usd: 0.0
  }

  # --- Public API ---

  @doc """
  Check whether all three gates are open for consolidation.

  Pure check — does not acquire the lock or modify state.
  """
  @spec is_gate_open(String.t(), keyword()) :: gate_result()
  def is_gate_open(infra_home, opts \\ []) do
    min_hours = Keyword.get(opts, :min_hours, @default_min_hours)
    min_sessions = Keyword.get(opts, :min_sessions, @default_min_sessions)
    state = read_state(infra_home)

    # Gate 1: Time elapsed
    now_ms = System.system_time(:millisecond)

    last_ms =
      case state.last_consolidated_at do
        nil -> 0
        ts -> parse_timestamp_ms(ts)
      end

    hours_since_last = (now_ms - last_ms) / (1_000 * 60 * 60)
    time_passed = hours_since_last >= min_hours

    # Gate 2: Session count
    sessions_passed = state.sessions_since_last >= min_sessions

    # Gate 3: Lock availability
    {lock_passed, lock_reason} = check_lock(infra_home)

    open = time_passed and sessions_passed and lock_passed

    result = %{
      open: open,
      gates: %{
        time: %{
          passed: time_passed,
          hours_since_last: Float.round(hours_since_last, 1),
          required: min_hours
        },
        sessions: %{
          passed: sessions_passed,
          count: state.sessions_since_last,
          required: min_sessions
        },
        lock: %{passed: lock_passed, reason: lock_reason}
      }
    }

    :telemetry.execute(
      [:crucible, :dream_gate, :check],
      %{
        open: open,
        hours_since_last: Float.round(hours_since_last, 1),
        sessions: state.sessions_since_last
      },
      %{}
    )

    result
  end

  @doc "Acquire the consolidation lock. Returns :ok or {:error, :locked}."
  @spec acquire_lock(String.t()) :: :ok | {:error, :locked}
  def acquire_lock(infra_home) do
    lock_path = lock_path(infra_home)
    ensure_learning_dir(infra_home)

    # Remove stale lock first
    case check_existing_lock(lock_path) do
      :no_lock -> :ok
      :stale -> remove_lock(lock_path)
      :active -> :skip
    end
    |> case do
      :skip ->
        {:error, :locked}

      _ ->
        # Atomic lock via exclusive file creation
        lock_data =
          Jason.encode!(%{
            acquired_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            pid: System.pid()
          })

        case File.open(lock_path, [:write, :exclusive]) do
          {:ok, fd} ->
            IO.write(fd, lock_data)
            File.close(fd)
            :ok

          {:error, :eexist} ->
            {:error, :locked}

          {:error, _reason} ->
            {:error, :locked}
        end
    end
  end

  @doc "Release the consolidation lock."
  @spec release_lock(String.t()) :: :ok
  def release_lock(infra_home) do
    File.rm(lock_path(infra_home))
    :ok
  end

  @doc "Read the current dream state from disk."
  @spec read_state(String.t()) :: dream_state()
  def read_state(infra_home) do
    state_path = state_path(infra_home)

    case File.read(state_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, parsed} -> decode_state(parsed)
          {:error, _} -> @empty_state
        end

      {:error, :enoent} ->
        @empty_state

      {:error, _reason} ->
        Logger.warning("DreamGate: corrupt state file, returning empty state")
        @empty_state
    end
  end

  @doc "Increment the session counter. Call on every session start."
  @spec record_session_start(String.t()) :: :ok
  def record_session_start(infra_home) do
    state = read_state(infra_home)
    write_state(infra_home, %{state | sessions_since_last: state.sessions_since_last + 1})
  end

  @doc "Record a completed consolidation run. Resets session counter."
  @spec record_consolidation_complete(String.t(), non_neg_integer(), float()) :: :ok
  def record_consolidation_complete(infra_home, tokens_spent, cost_usd) do
    state = read_state(infra_home)

    write_state(infra_home, %{
      state
      | last_consolidated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        sessions_since_last: 0,
        total_runs: state.total_runs + 1,
        total_tokens_spent: state.total_tokens_spent + tokens_spent,
        total_cost_usd: state.total_cost_usd + cost_usd
    })
  end

  # --- Private ---

  defp check_lock(infra_home) do
    lock_path = lock_path(infra_home)

    if File.exists?(lock_path) do
      case check_existing_lock(lock_path) do
        :no_lock -> {true, nil}
        :stale -> {true, "stale lock, will override"}
        :active -> {false, "active lock held"}
      end
    else
      {true, nil}
    end
  end

  defp check_existing_lock(lock_path) do
    case File.read(lock_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, parsed} ->
            # Accept both snake_case (Elixir) and camelCase (TS) keys
            ts = parsed["acquired_at"] || parsed["acquiredAt"]

            if ts do
              lock_age = System.system_time(:millisecond) - parse_timestamp_ms(ts)
              if lock_age > @stale_lock_ms, do: :stale, else: :active
            else
              :stale
            end

          _ ->
            :stale
        end

      {:error, :enoent} ->
        :no_lock

      _ ->
        :stale
    end
  end

  defp remove_lock(lock_path) do
    Logger.info("DreamGate: removing stale lock")
    File.rm(lock_path)
    :ok
  end

  defp parse_timestamp_ms(nil), do: 0

  defp parse_timestamp_ms(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> 0
    end
  end

  defp decode_state(parsed) when is_map(parsed) do
    %{
      last_consolidated_at: parsed["last_consolidated_at"] || parsed["lastConsolidatedAt"],
      sessions_since_last: parsed["sessions_since_last"] || parsed["sessionsSinceLast"] || 0,
      total_runs: parsed["total_runs"] || parsed["totalRuns"] || 0,
      total_tokens_spent: parsed["total_tokens_spent"] || parsed["totalTokensSpent"] || 0,
      total_cost_usd: (parsed["total_cost_usd"] || parsed["totalCostUsd"] || 0.0) / 1
    }
  end

  defp state_path(infra_home), do: Path.join([infra_home, @learning_dir, @state_file])
  defp lock_path(infra_home), do: Path.join([infra_home, @learning_dir, @lock_file])

  defp ensure_learning_dir(infra_home) do
    File.mkdir_p!(Path.join(infra_home, @learning_dir))
  end

  defp write_state(infra_home, state) do
    ensure_learning_dir(infra_home)

    encoded =
      Jason.encode!(%{
        last_consolidated_at: state.last_consolidated_at,
        sessions_since_last: state.sessions_since_last,
        total_runs: state.total_runs,
        total_tokens_spent: state.total_tokens_spent,
        total_cost_usd: state.total_cost_usd
      })

    target = state_path(infra_home)
    tmp = target <> ".tmp"
    File.write!(tmp, encoded)
    File.rename!(tmp, target)
    :ok
  end
end
