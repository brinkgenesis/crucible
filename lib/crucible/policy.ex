defmodule Crucible.Policy do
  @moduledoc """
  Workflow timing policy with A/B canary evaluation.
  Pure-function module — called from SelfImprovement during improvement cycles.
  """

  require Logger

  @default_timings %{
    phase_poll_ms: 2_000,
    pickup_timeout_ms: 30_000,
    phase_timeout_ms: 600_000
  }

  @canary_defaults %{
    default_rollout_percent: 10,
    min_runs: 12,
    rollback_delta: 0.05,
    promote_delta: 0.02
  }

  @doc "Loads policy state from disk, returning defaults if not found."
  @spec load_state(String.t()) :: map()
  def load_state(infra_home) do
    path = policy_path(infra_home)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> decode_state(data)
          _ -> default_state()
        end

      _ ->
        default_state()
    end
  end

  @doc "Saves policy state to disk atomically."
  @spec save_state(String.t(), map()) :: :ok | {:error, term()}
  def save_state(infra_home, state) do
    dir = Path.join(infra_home, ".claude-flow/learning")
    File.mkdir_p!(dir)
    path = policy_path(infra_home)
    tmp = path <> ".tmp"

    encoded = state |> encode_state() |> Jason.encode!(pretty: true)
    File.write!(tmp, encoded)
    File.rename!(tmp, path)
    :ok
  rescue
    e -> {:error, e}
  end

  @doc """
  Deterministic canary bucketing for a run.
  Returns %{policy_id, variant, canary, timings}.
  """
  @spec resolve_run_policy(map(), String.t()) :: map()
  def resolve_run_policy(state, run_id) do
    case state.candidate do
      %{enabled: true, rollout_percent: pct} = candidate ->
        bucket = hash_bucket(run_id)

        if bucket < pct do
          %{
            policy_id: candidate.policy_id,
            variant: :candidate,
            canary: true,
            timings: candidate.timings
          }
        else
          %{
            policy_id: state.active.policy_id,
            variant: :active,
            canary: false,
            timings: state.active.timings
          }
        end

      _ ->
        %{
          policy_id: state.active.policy_id,
          variant: :active,
          canary: false,
          timings: state.active.timings
        }
    end
  end

  @doc """
  Decides what action to take on the candidate policy based on KPI data.
  Returns {updated_state, action | nil}.
  """
  @spec decide_candidate_action(map(), map()) :: {map(), map() | nil}
  def decide_candidate_action(state, kpi) do
    case state.candidate do
      nil ->
        case create_candidate(state, kpi) do
          nil ->
            {state, nil}

          candidate ->
            now = DateTime.utc_now() |> DateTime.to_iso8601()
            new_state = %{state | candidate: candidate, updated_at: now}

            action = %{
              type: :candidate_created,
              policy_id: candidate.policy_id,
              reason: candidate.reason
            }

            {new_state, action}
        end

      _candidate ->
        evaluate_candidate(state, kpi)
    end
  end

  @doc "Clamps timing values to safe ranges."
  @spec sanitize_timings(map()) :: map()
  def sanitize_timings(timings) do
    %{
      phase_poll_ms: clamp(timings.phase_poll_ms, 100, 60_000),
      pickup_timeout_ms: clamp(timings.pickup_timeout_ms, 5_000, 3_600_000),
      phase_timeout_ms: clamp(timings.phase_timeout_ms, 5_000, 14_400_000)
    }
  end

  # --- Private ---

  defp hash_bucket(run_id) do
    <<first_8_hex::binary-size(8), _rest::binary>> =
      :crypto.hash(:sha256, run_id) |> Base.encode16(case: :lower)

    {n, _} = Integer.parse(first_8_hex, 16)
    rem(n, 100)
  end

  defp create_candidate(state, kpi) do
    totals = kpi.totals
    active = state.active.timings
    changes = []

    # If pickup latency is high, decrease poll interval
    {poll_ms, changes} =
      if totals[:pickup_p95_ms] && totals.pickup_p95_ms > 3000 && active.phase_poll_ms > 250 do
        new_val = round(active.phase_poll_ms * 0.7)
        {new_val, ["decreased phase_poll_ms by 30%" | changes]}
      else
        {active.phase_poll_ms, changes}
      end

    # If timeout rate is high, increase timeouts
    {pickup_ms, phase_ms, changes} =
      if totals.timeout_rate > 0.10 do
        new_pickup = round(active.pickup_timeout_ms * 1.20)
        new_phase = round(active.phase_timeout_ms * 1.25)
        {new_pickup, new_phase, ["increased timeouts (pickup +20%, phase +25%)" | changes]}
      else
        {active.pickup_timeout_ms, active.phase_timeout_ms, changes}
      end

    if changes == [] do
      nil
    else
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      policy_id = "policy-#{System.unique_integer([:positive])}"

      %{
        policy_id: policy_id,
        created_at: now,
        reason: Enum.join(changes, "; "),
        timings:
          sanitize_timings(%{
            phase_poll_ms: poll_ms,
            pickup_timeout_ms: pickup_ms,
            phase_timeout_ms: phase_ms
          }),
        enabled: true,
        rollout_percent: state.canary.default_rollout_percent
      }
    end
  end

  defp evaluate_candidate(state, kpi) do
    canary = state.canary
    active_kpi = kpi.by_variant.active
    candidate_kpi = kpi.by_variant.candidate

    # Need minimum samples
    if active_kpi.runs < canary.min_runs or candidate_kpi.runs < canary.min_runs do
      {state, nil}
    else
      cond do
        should_rollback?(active_kpi, candidate_kpi, canary) ->
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          reason =
            "candidate underperforming: fail_rate=#{candidate_kpi.fail_rate}, timeout_rate=#{candidate_kpi.timeout_rate}"

          new_state = %{
            state
            | candidate: nil,
              updated_at: now,
              last_rollback: %{at: now, policy_id: state.candidate.policy_id, reason: reason}
          }

          {new_state,
           %{type: :candidate_rollback, policy_id: state.candidate.policy_id, reason: reason}}

        should_promote?(active_kpi, candidate_kpi, canary) ->
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          reason =
            "candidate outperforming: timeout_rate improved by #{Float.round((active_kpi.timeout_rate - candidate_kpi.timeout_rate) * 100, 1)}pp"

          new_state = %{
            state
            | active: %{
                policy_id: state.candidate.policy_id,
                created_at: state.candidate.created_at,
                reason: reason,
                timings: state.candidate.timings
              },
              candidate: nil,
              updated_at: now,
              last_promotion: %{at: now, policy_id: state.candidate.policy_id, reason: reason}
          }

          {new_state,
           %{type: :candidate_promoted, policy_id: state.candidate.policy_id, reason: reason}}

        true ->
          {state, nil}
      end
    end
  end

  defp should_rollback?(active, candidate, canary) do
    candidate.fail_rate > active.fail_rate + canary.rollback_delta or
      candidate.timeout_rate > active.timeout_rate + canary.rollback_delta or
      (candidate.pickup_p95_ms != nil and active.pickup_p95_ms != nil and
         candidate.pickup_p95_ms > active.pickup_p95_ms * 1.25 and
         candidate.pickup_p95_ms - active.pickup_p95_ms > 250)
  end

  defp should_promote?(active, candidate, canary) do
    candidate.timeout_rate + canary.promote_delta < active.timeout_rate and
      candidate.fail_rate <= active.fail_rate + 0.01 and
      (candidate.pickup_p95_ms == nil or active.pickup_p95_ms == nil or
         candidate.pickup_p95_ms <= active.pickup_p95_ms * 0.90)
  end

  defp clamp(val, min_val, max_val), do: max(min_val, min(max_val, val))

  defp default_state do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      updated_at: now,
      active: %{
        policy_id: "default",
        created_at: now,
        reason: "initial default policy",
        timings: @default_timings
      },
      candidate: nil,
      canary: @canary_defaults,
      last_rollback: nil,
      last_promotion: nil
    }
  end

  defp policy_path(infra_home) do
    Path.join(infra_home, ".claude-flow/learning/workflow-policy.json")
  end

  defp encode_state(state) do
    %{
      "updatedAt" => state.updated_at,
      "active" => encode_policy_version(state.active),
      "candidate" => if(state.candidate, do: encode_candidate(state.candidate), else: nil),
      "canary" => %{
        "defaultRolloutPercent" => state.canary.default_rollout_percent,
        "minRunsForDecision" => state.canary.min_runs,
        "rollbackDelta" => state.canary.rollback_delta,
        "promoteDelta" => state.canary.promote_delta
      },
      "lastRollback" => encode_nullable_event(state.last_rollback),
      "lastPromotion" => encode_nullable_event(state.last_promotion)
    }
  end

  defp decode_state(data) do
    %{
      updated_at: data["updatedAt"] || DateTime.utc_now() |> DateTime.to_iso8601(),
      active: decode_policy_version(data["active"]),
      candidate: if(data["candidate"], do: decode_candidate(data["candidate"]), else: nil),
      canary: %{
        default_rollout_percent: get_in(data, ["canary", "defaultRolloutPercent"]) || 10,
        min_runs: get_in(data, ["canary", "minRunsForDecision"]) || 12,
        rollback_delta: get_in(data, ["canary", "rollbackDelta"]) || 0.05,
        promote_delta: get_in(data, ["canary", "promoteDelta"]) || 0.02
      },
      last_rollback: decode_nullable_event(data["lastRollback"]),
      last_promotion: decode_nullable_event(data["lastPromotion"])
    }
  end

  defp encode_policy_version(v) do
    %{
      "policyId" => v.policy_id,
      "createdAt" => v.created_at,
      "reason" => v.reason,
      "timings" => %{
        "phasePollMs" => v.timings.phase_poll_ms,
        "pickupTimeoutMs" => v.timings.pickup_timeout_ms,
        "phaseTimeoutMs" => v.timings.phase_timeout_ms
      }
    }
  end

  defp encode_candidate(c) do
    encode_policy_version(c)
    |> Map.merge(%{
      "enabled" => c.enabled,
      "rolloutPercent" => c.rollout_percent
    })
  end

  defp decode_policy_version(nil) do
    %{
      policy_id: "default",
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      reason: "default",
      timings: @default_timings
    }
  end

  defp decode_policy_version(data) do
    timings = data["timings"] || %{}

    %{
      policy_id: data["policyId"] || "default",
      created_at: data["createdAt"],
      reason: data["reason"] || "unknown",
      timings:
        sanitize_timings(%{
          phase_poll_ms: timings["phasePollMs"] || @default_timings.phase_poll_ms,
          pickup_timeout_ms: timings["pickupTimeoutMs"] || @default_timings.pickup_timeout_ms,
          phase_timeout_ms: timings["phaseTimeoutMs"] || @default_timings.phase_timeout_ms
        })
    }
  end

  defp decode_candidate(data) do
    decode_policy_version(data)
    |> Map.merge(%{
      enabled: data["enabled"] != false,
      rollout_percent: data["rolloutPercent"] || 10
    })
  end

  defp encode_nullable_event(nil), do: nil

  defp encode_nullable_event(e),
    do: %{"at" => e.at, "policyId" => e.policy_id, "reason" => e.reason}

  defp decode_nullable_event(nil), do: nil

  defp decode_nullable_event(data),
    do: %{at: data["at"], policy_id: data["policyId"], reason: data["reason"]}
end
