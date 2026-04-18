defmodule Crucible.RegressionsTest do
  use ExUnit.Case, async: true

  alias Crucible.Regressions

  setup do
    tmp = Path.join(System.tmp_dir!(), "regression_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    kpi_dir = Path.join(tmp, ".claude-flow/learning")
    File.mkdir_p!(kpi_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, infra_home: tmp}
  end

  describe "detect_regressions" do
    test "returns empty when no history", %{infra_home: home} do
      kpi = %{
        totals: %{
          fail_rate: 0.20,
          timeout_rate: 0.15,
          force_completed_rate: 0.12,
          avg_retries: 1.5
        }
      }

      assert Regressions.detect_regressions(kpi, home) == []
    end

    test "detects fail rate spike above baseline", %{infra_home: home} do
      # Write history with low fail rates
      history_path = Path.join(home, ".claude-flow/learning/workflow-kpi-history.jsonl")

      entries =
        Enum.map(1..5, fn _ ->
          Jason.encode!(%{
            "totals" => %{
              "fail_rate" => 0.02,
              "timeout_rate" => 0.02,
              "force_completed_rate" => 0.01,
              "avg_retries" => 0.5
            }
          })
        end)

      File.write!(history_path, Enum.join(entries, "\n") <> "\n")

      kpi = %{
        totals: %{
          fail_rate: 0.15,
          timeout_rate: 0.02,
          force_completed_rate: 0.01,
          avg_retries: 0.5
        }
      }

      rules = Regressions.detect_regressions(kpi, home)
      assert length(rules) == 1
      assert hd(rules).id == "fail-rate-spike"
    end

    test "detects multiple regressions", %{infra_home: home} do
      history_path = Path.join(home, ".claude-flow/learning/workflow-kpi-history.jsonl")

      entries =
        Enum.map(1..5, fn _ ->
          Jason.encode!(%{
            "totals" => %{
              "fail_rate" => 0.02,
              "timeout_rate" => 0.02,
              "force_completed_rate" => 0.01,
              "avg_retries" => 0.3
            }
          })
        end)

      File.write!(history_path, Enum.join(entries, "\n") <> "\n")

      kpi = %{
        totals: %{
          fail_rate: 0.15,
          timeout_rate: 0.15,
          force_completed_rate: 0.12,
          avg_retries: 1.5
        }
      }

      rules = Regressions.detect_regressions(kpi, home)
      ids = Enum.map(rules, & &1.id)
      assert "fail-rate-spike" in ids
      assert "timeout-rate-spike" in ids
      assert "force-completion-spike" in ids
      assert "avg-retries-spike" in ids
    end
  end

  describe "inject_guardrails" do
    test "returns hints unchanged when no rules", %{infra_home: home} do
      hints = %{global: ["existing hint"], workflows: %{}, evidence: %{}}
      result = Regressions.inject_guardrails(hints, home)
      assert result.global == ["existing hint"]
    end

    test "injects top rules as guardrail hints", %{infra_home: home} do
      rules = [
        %{
          id: "r1",
          rule: "Fix fail rate",
          source: :kpi,
          created_at: "2026-01-01T00:00:00Z",
          hit_count: 5,
          resolved: false
        },
        %{
          id: "r2",
          rule: "Fix timeouts",
          source: :kpi,
          created_at: "2026-01-01T00:00:00Z",
          hit_count: 3,
          resolved: false
        }
      ]

      Regressions.save_rules(home, rules)

      hints = %{global: [], workflows: %{}, evidence: %{}}
      result = Regressions.inject_guardrails(hints, home)
      assert length(result.global) == 2
      assert Enum.any?(result.global, &String.contains?(&1, "[guardrail]"))
    end

    test "skips resolved rules", %{infra_home: home} do
      rules = [
        %{
          id: "r1",
          rule: "Old fix",
          source: :kpi,
          created_at: "2026-01-01T00:00:00Z",
          hit_count: 10,
          resolved: true
        },
        %{
          id: "r2",
          rule: "Active fix",
          source: :kpi,
          created_at: "2026-01-01T00:00:00Z",
          hit_count: 2,
          resolved: false
        }
      ]

      Regressions.save_rules(home, rules)

      hints = %{global: [], workflows: %{}, evidence: %{}}
      result = Regressions.inject_guardrails(hints, home)
      assert length(result.global) == 1
      assert hd(result.global) =~ "Active fix"
    end

    test "limits to max 5 guardrails", %{infra_home: home} do
      rules =
        Enum.map(1..10, fn i ->
          %{
            id: "r#{i}",
            rule: "Rule #{i}",
            source: :kpi,
            created_at: "2026-01-01T00:00:00Z",
            hit_count: 10 - i,
            resolved: false
          }
        end)

      Regressions.save_rules(home, rules)

      hints = %{global: [], workflows: %{}, evidence: %{}}
      result = Regressions.inject_guardrails(hints, home)
      assert length(result.global) == 5
    end
  end

  describe "load_rules and save_rules" do
    test "round-trips rules", %{infra_home: home} do
      rules = [
        %{
          id: "test-1",
          rule: "Do X",
          source: :kpi,
          created_at: "2026-01-01T00:00:00Z",
          hit_count: 3,
          resolved: false,
          context: "test"
        },
        %{
          id: "test-2",
          rule: "Do Y",
          source: :session,
          created_at: "2026-01-02T00:00:00Z",
          hit_count: 0,
          resolved: true
        }
      ]

      Regressions.save_rules(home, rules)
      loaded = Regressions.load_rules(home)
      assert length(loaded) == 2
      assert hd(loaded).id == "test-1"
      assert hd(loaded).hit_count == 3
    end

    test "returns empty list when no file", %{infra_home: home} do
      assert Regressions.load_rules(home) == []
    end
  end

  describe "prune_stale" do
    test "marks old unresolved rules as resolved", %{infra_home: home} do
      old_date = DateTime.utc_now() |> DateTime.add(-60 * 86400, :second) |> DateTime.to_iso8601()

      rules = [
        %{
          id: "old",
          rule: "Stale rule",
          source: :kpi,
          created_at: old_date,
          hit_count: 1,
          resolved: false
        },
        %{
          id: "new",
          rule: "Fresh rule",
          source: :kpi,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          hit_count: 1,
          resolved: false
        }
      ]

      Regressions.save_rules(home, rules)

      pruned = Regressions.prune_stale(home)
      assert pruned == 1

      loaded = Regressions.load_rules(home)
      old_rule = Enum.find(loaded, &(&1.id == "old"))
      new_rule = Enum.find(loaded, &(&1.id == "new"))
      assert old_rule.resolved == true
      assert new_rule.resolved == false
    end
  end
end
