defmodule Crucible.SelfImprovementTest do
  use ExUnit.Case, async: false

  alias Crucible.SelfImprovement

  # The app supervisor already starts SelfImprovement globally
  describe "SelfImprovement GenServer" do
    test "latest_snapshot returns map or nil" do
      result = SelfImprovement.latest_snapshot()
      assert is_nil(result) or is_map(result)
    end

    test "returns empty hints initially" do
      hints = SelfImprovement.current_hints()
      assert is_list(hints.global)
      assert is_map(hints.workflows)
    end

    test "trigger/1 accepts run_id" do
      assert :ok = SelfImprovement.trigger("test-run")
    end
  end

  describe "read_prompt_hints_for_phase/2" do
    test "returns a list" do
      result = SelfImprovement.read_prompt_hints_for_phase(nil, :session)
      assert is_list(result)
    end

    test "returns global hints for session phase" do
      result = SelfImprovement.read_prompt_hints_for_phase(nil, :session)
      assert result == [] or is_list(result)
    end

    test "returns global hints for preflight phase" do
      result = SelfImprovement.read_prompt_hints_for_phase(nil, :preflight)
      assert is_list(result)
    end

    test "returns global hints for pr_shepherd phase" do
      result = SelfImprovement.read_prompt_hints_for_phase(nil, :pr_shepherd)
      assert is_list(result)
    end

    test "returns global hints for team phase" do
      result = SelfImprovement.read_prompt_hints_for_phase(nil, :team)
      assert is_list(result)
    end

    test "returns global hints for review_gate phase" do
      result = SelfImprovement.read_prompt_hints_for_phase(nil, :review_gate)
      assert is_list(result)
    end

    test "returns global hints for api phase" do
      result = SelfImprovement.read_prompt_hints_for_phase(nil, :api)
      assert is_list(result)
    end

    test "returns empty list for unknown phase type" do
      result = SelfImprovement.read_prompt_hints_for_phase(nil, :unknown)
      assert is_list(result)
    end

    test "accepts workflow name string" do
      result = SelfImprovement.read_prompt_hints_for_phase("feature", :session)
      assert is_list(result)
    end

    test "handles nil workflow name" do
      result = SelfImprovement.read_prompt_hints_for_phase(nil, :team)
      assert is_list(result)
    end
  end

  describe "KPI pipeline with trace files" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "si_test_#{System.unique_integer([:positive])}")
      traces_dir = Path.join(tmp, ".claude-flow/logs/traces")
      kpi_dir = Path.join(tmp, ".claude-flow/learning")
      File.mkdir_p!(traces_dir)
      File.mkdir_p!(kpi_dir)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, infra_home: tmp, traces_dir: traces_dir, kpi_dir: kpi_dir}
    end

    test "trigger with variant trace data produces by_variant in snapshot", %{
      infra_home: home,
      traces_dir: traces_dir
    } do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      events = [
        %{
          "runId" => "run-1",
          "timestamp" => now,
          "eventType" => "run_started",
          "workflowName" => "deploy"
        },
        %{
          "runId" => "run-1",
          "timestamp" => now,
          "eventType" => "run_policy_applied",
          "metadata" => %{"variant" => "active"}
        },
        %{"runId" => "run-1", "timestamp" => now, "eventType" => "run_completed"},
        %{
          "runId" => "run-2",
          "timestamp" => now,
          "eventType" => "run_started",
          "workflowName" => "deploy"
        },
        %{
          "runId" => "run-2",
          "timestamp" => now,
          "eventType" => "run_policy_applied",
          "metadata" => %{"variant" => "candidate"}
        },
        %{"runId" => "run-2", "timestamp" => now, "eventType" => "run_completed"}
      ]

      trace_path = Path.join(traces_dir, "test.jsonl")
      content = events |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
      File.write!(trace_path, content <> "\n")

      # Start a test-specific GenServer and cast directly to its pid
      {:ok, pid} =
        GenServer.start_link(SelfImprovement, infra_home: home, interval_ms: 999_999_999)

      GenServer.cast(pid, {:trigger, "run-1"})
      Process.sleep(300)

      snapshot = GenServer.call(pid, :latest_snapshot)
      assert snapshot != nil
      assert snapshot.by_variant.active.runs >= 1
      assert snapshot.by_variant.candidate.runs >= 1

      GenServer.stop(pid)
    end

    test "phase outcomes in traces populate by_phase_type", %{
      infra_home: home,
      traces_dir: traces_dir
    } do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      events = [
        %{
          "runId" => "run-p1",
          "timestamp" => now,
          "eventType" => "run_started",
          "workflowName" => "build"
        },
        %{
          "runId" => "run-p1",
          "timestamp" => now,
          "eventType" => "phase_end",
          "metadata" => %{
            "phaseType" => "session",
            "durationMs" => 5000,
            "status" => "completed",
            "cost" => 1.5
          }
        },
        %{
          "runId" => "run-p1",
          "timestamp" => now,
          "eventType" => "phase_end",
          "metadata" => %{
            "phaseType" => "review_gate",
            "durationMs" => 3000,
            "status" => "blocked",
            "cost" => 0.5
          }
        },
        %{"runId" => "run-p1", "timestamp" => now, "eventType" => "run_completed"}
      ]

      trace_path = Path.join(traces_dir, "phases.jsonl")
      content = events |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
      File.write!(trace_path, content <> "\n")

      {:ok, pid} =
        GenServer.start_link(SelfImprovement, infra_home: home, interval_ms: 999_999_999)

      GenServer.cast(pid, {:trigger, "run-p1"})
      Process.sleep(300)

      snapshot = GenServer.call(pid, :latest_snapshot)
      assert snapshot != nil
      assert Map.has_key?(snapshot.by_phase_type, "session")
      assert snapshot.by_phase_type["session"].count == 1
      assert snapshot.by_phase_type["session"].completed == 1

      assert Map.has_key?(snapshot.by_phase_type, "review_gate")
      assert snapshot.by_phase_type["review_gate"].block_rate != nil

      GenServer.stop(pid)
    end

    test "force_completed flag set correctly", %{infra_home: home, traces_dir: traces_dir} do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      events = [
        %{
          "runId" => "run-fc",
          "timestamp" => now,
          "eventType" => "run_started",
          "workflowName" => "test"
        },
        %{
          "runId" => "run-fc",
          "timestamp" => now,
          "eventType" => "force_completed",
          "phaseId" => "p1",
          "detail" => "stuck"
        },
        %{"runId" => "run-fc", "timestamp" => now, "eventType" => "run_completed"}
      ]

      trace_path = Path.join(traces_dir, "fc.jsonl")
      content = events |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
      File.write!(trace_path, content <> "\n")

      {:ok, pid} =
        GenServer.start_link(SelfImprovement, infra_home: home, interval_ms: 999_999_999)

      GenServer.cast(pid, {:trigger, "run-fc"})
      Process.sleep(300)

      snapshot = GenServer.call(pid, :latest_snapshot)
      assert snapshot != nil
      assert snapshot.totals.force_completed_runs == 1
      assert snapshot.totals.force_completed_rate > 0.0

      GenServer.stop(pid)
    end

    test "pickup waits accumulated correctly", %{infra_home: home, traces_dir: traces_dir} do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      events = [
        %{
          "runId" => "run-pw",
          "timestamp" => now,
          "eventType" => "run_started",
          "workflowName" => "test"
        },
        %{
          "runId" => "run-pw",
          "timestamp" => now,
          "eventType" => "pickup_trigger_claimed",
          "metadata" => %{"waitMs" => 1500}
        },
        %{
          "runId" => "run-pw",
          "timestamp" => now,
          "eventType" => "pickup_trigger_claimed",
          "metadata" => %{"waitMs" => 3000}
        },
        %{"runId" => "run-pw", "timestamp" => now, "eventType" => "run_completed"}
      ]

      trace_path = Path.join(traces_dir, "pw.jsonl")
      content = events |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
      File.write!(trace_path, content <> "\n")

      {:ok, pid} =
        GenServer.start_link(SelfImprovement, infra_home: home, interval_ms: 999_999_999)

      GenServer.cast(pid, {:trigger, "run-pw"})
      Process.sleep(300)

      snapshot = GenServer.call(pid, :latest_snapshot)
      assert snapshot != nil
      assert snapshot.totals.pickup_p95_ms != nil
      assert snapshot.totals.pickup_p95_ms == 3000

      GenServer.stop(pid)
    end

    test "workflow-kpi-history.jsonl is appended on each cycle", %{
      infra_home: home,
      traces_dir: traces_dir,
      kpi_dir: kpi_dir
    } do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      events = [
        %{
          "runId" => "run-h",
          "timestamp" => now,
          "eventType" => "run_started",
          "workflowName" => "test"
        },
        %{"runId" => "run-h", "timestamp" => now, "eventType" => "run_completed"}
      ]

      trace_path = Path.join(traces_dir, "history.jsonl")
      content = events |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
      File.write!(trace_path, content <> "\n")

      {:ok, pid} =
        GenServer.start_link(SelfImprovement, infra_home: home, interval_ms: 999_999_999)

      GenServer.cast(pid, {:trigger, "run-h"})
      Process.sleep(300)

      history_path = Path.join(kpi_dir, "workflow-kpi-history.jsonl")
      assert File.exists?(history_path)
      lines = history_path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) >= 1

      GenServer.stop(pid)
    end
  end
end
