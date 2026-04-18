defmodule Crucible.Regressions do
  @moduledoc """
  KPI regression detection and guardrail injection.
  Compares current KPI snapshot against historical baseline,
  detects trend regressions, and injects guardrail hints.
  """

  require Logger

  @baseline_window 10
  @threshold_pp 0.05
  @retry_threshold 0.5
  @max_guardrails 5
  @stale_days 30

  @doc "Detects regressions by comparing current KPI against historical baseline."
  @spec detect_regressions(map(), String.t()) :: [map()]
  def detect_regressions(current_kpi, infra_home) do
    history = load_kpi_history(infra_home)

    if length(history) < 2 do
      []
    else
      baseline = compute_baseline(history)
      totals = current_kpi.totals
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      rules = []

      rules =
        if totals.fail_rate - (baseline[:fail_rate] || 0.0) > @threshold_pp do
          [
            %{
              id: "fail-rate-spike",
              rule:
                "Fail rate spiked to #{Float.round(totals.fail_rate * 100, 1)}% (baseline: #{Float.round((baseline[:fail_rate] || 0.0) * 100, 1)}%) — prefer reversible changes and verify before committing",
              source: :kpi,
              created_at: now,
              hit_count: 0,
              resolved: false,
              context:
                "Current: #{Float.round(totals.fail_rate * 100, 1)}%, Baseline: #{Float.round((baseline[:fail_rate] || 0.0) * 100, 1)}%"
            }
            | rules
          ]
        else
          rules
        end

      rules =
        if totals.timeout_rate - (baseline[:timeout_rate] || 0.0) > @threshold_pp do
          [
            %{
              id: "timeout-rate-spike",
              rule:
                "Timeout rate spiked to #{Float.round(totals.timeout_rate * 100, 1)}% — break phases into smaller checkpoints",
              source: :kpi,
              created_at: now,
              hit_count: 0,
              resolved: false,
              context:
                "Current: #{Float.round(totals.timeout_rate * 100, 1)}%, Baseline: #{Float.round((baseline[:timeout_rate] || 0.0) * 100, 1)}%"
            }
            | rules
          ]
        else
          rules
        end

      fc_rate = totals[:force_completed_rate] || 0.0

      rules =
        if fc_rate - (baseline[:force_completed_rate] || 0.0) > @threshold_pp do
          [
            %{
              id: "force-completion-spike",
              rule:
                "Force-completion rate spiked to #{Float.round(fc_rate * 100, 1)}% — add explicit completion signals",
              source: :kpi,
              created_at: now,
              hit_count: 0,
              resolved: false,
              context:
                "Current: #{Float.round(fc_rate * 100, 1)}%, Baseline: #{Float.round((baseline[:force_completed_rate] || 0.0) * 100, 1)}%"
            }
            | rules
          ]
        else
          rules
        end

      avg_retries = totals[:avg_retries] || 0.0

      rules =
        if avg_retries - (baseline[:avg_retries] || 0.0) > @retry_threshold do
          [
            %{
              id: "avg-retries-spike",
              rule:
                "Average retries increased to #{Float.round(avg_retries, 1)} — investigate root causes of failures",
              source: :kpi,
              created_at: now,
              hit_count: 0,
              resolved: false,
              context:
                "Current: #{Float.round(avg_retries, 1)}, Baseline: #{Float.round(baseline[:avg_retries] || 0.0, 1)}"
            }
            | rules
          ]
        else
          rules
        end

      rules
    end
  end

  @doc "Injects top guardrail rules as hints, returns updated hints map."
  @spec inject_guardrails(map(), String.t()) :: map()
  def inject_guardrails(hints, infra_home) do
    rules = load_rules(infra_home)

    active =
      rules
      |> Enum.reject(& &1.resolved)
      |> Enum.sort_by(fn r -> {-r.hit_count, r.created_at} end)
      |> Enum.take(@max_guardrails)

    existing = MapSet.new(hints.global, &String.downcase/1)

    new_hints =
      active
      |> Enum.map(fn r -> "[guardrail] #{r.rule}" end)
      |> Enum.reject(fn h -> MapSet.member?(existing, String.downcase(h)) end)

    # Increment hit counts
    active_ids = MapSet.new(active, & &1.id)

    updated_rules =
      Enum.map(rules, fn r ->
        if MapSet.member?(active_ids, r.id), do: %{r | hit_count: r.hit_count + 1}, else: r
      end)

    save_rules(infra_home, updated_rules)

    %{hints | global: hints.global ++ new_hints}
  end

  @doc "Marks rules as resolved if not triggered in stale_days."
  @spec prune_stale(String.t()) :: non_neg_integer()
  def prune_stale(infra_home) do
    rules = load_rules(infra_home)
    cutoff = DateTime.utc_now() |> DateTime.add(-@stale_days * 86400, :second)

    {pruned, kept} =
      Enum.split_with(rules, fn r ->
        !r.resolved and stale?(r, cutoff)
      end)

    if length(pruned) > 0 do
      updated = kept ++ Enum.map(pruned, &%{&1 | resolved: true})
      save_rules(infra_home, updated)
    end

    length(pruned)
  end

  @doc "Loads regression rules from JSONL file."
  @spec load_rules(String.t()) :: [map()]
  def load_rules(infra_home) do
    path = rules_path(infra_home)

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, data} -> [decode_rule(data)]
          _ -> []
        end
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Saves regression rules to JSONL file."
  @spec save_rules(String.t(), [map()]) :: :ok
  def save_rules(infra_home, rules) do
    dir = Path.join(infra_home, ".claude-flow/learning")
    File.mkdir_p!(dir)
    path = rules_path(infra_home)

    content =
      rules
      |> Enum.map(fn r -> Jason.encode!(encode_rule(r)) end)
      |> Enum.join("\n")

    File.write!(path, content <> "\n")
    :ok
  rescue
    e ->
      Logger.warning("Regressions: failed to save rules: #{inspect(e)}")
      :ok
  end

  # --- Private ---

  defp rules_path(infra_home) do
    Path.join(infra_home, ".claude-flow/learning/workflow-regressions.jsonl")
  end

  defp load_kpi_history(infra_home) do
    path = Path.join(infra_home, ".claude-flow/learning/workflow-kpi-history.jsonl")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"totals" => totals}} -> [normalize_totals(totals)]
          _ -> []
        end
      end)
      |> Enum.take(-@baseline_window)
    else
      []
    end
  rescue
    _ -> []
  end

  defp compute_baseline(history) do
    n = length(history)

    if n == 0 do
      %{}
    else
      %{
        fail_rate: avg_field(history, :fail_rate),
        timeout_rate: avg_field(history, :timeout_rate),
        force_completed_rate: avg_field(history, :force_completed_rate),
        avg_retries: avg_field(history, :avg_retries)
      }
    end
  end

  defp avg_field(entries, field) do
    values = entries |> Enum.map(&Map.get(&1, field, 0.0)) |> Enum.reject(&is_nil/1)
    if length(values) > 0, do: Enum.sum(values) / length(values), else: 0.0
  end

  defp normalize_totals(totals) do
    %{
      fail_rate: to_f(totals["fail_rate"] || totals["failRate"]),
      timeout_rate: to_f(totals["timeout_rate"] || totals["timeoutRate"]),
      force_completed_rate: to_f(totals["force_completed_rate"] || totals["forceCompletedRate"]),
      avg_retries: to_f(totals["avg_retries"] || totals["avgRetries"])
    }
  end

  defp to_f(nil), do: 0.0
  defp to_f(n) when is_float(n), do: n
  defp to_f(n) when is_integer(n), do: n * 1.0

  defp stale?(rule, cutoff) do
    ts = rule[:last_triggered_at] || rule.created_at

    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.compare(dt, cutoff) == :lt
      _ -> true
    end
  end

  defp encode_rule(r) do
    %{
      "id" => r.id,
      "rule" => r.rule,
      "source" => to_string(r.source),
      "createdAt" => r.created_at,
      "lastTriggeredAt" => r[:last_triggered_at],
      "hitCount" => r.hit_count,
      "resolved" => r.resolved,
      "context" => r[:context]
    }
  end

  defp decode_rule(data) do
    %{
      id: data["id"],
      rule: data["rule"],
      source: safe_source_atom(data["source"]),
      created_at: data["createdAt"],
      last_triggered_at: data["lastTriggeredAt"],
      hit_count: data["hitCount"] || 0,
      resolved: data["resolved"] || false,
      context: data["context"]
    }
  end

  @source_map %{
    "kpi" => :kpi,
    "policy" => :policy,
    "manual" => :manual,
    "session" => :session
  }

  defp safe_source_atom(nil), do: :kpi
  defp safe_source_atom(s) when is_binary(s), do: Map.get(@source_map, s, :kpi)
  defp safe_source_atom(_), do: :kpi
end
