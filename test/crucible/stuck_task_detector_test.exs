defmodule Crucible.StuckTaskDetectorTest do
  use ExUnit.Case, async: true

  alias Crucible.StuckTaskDetector

  setup do
    tmp = Path.join(System.tmp_dir!(), "stuck_det_#{:rand.uniform(10000)}")
    team_name = "test-team-#{:rand.uniform(10000)}"
    task_dir = Path.expand("~/.claude/tasks/#{team_name}")
    File.mkdir_p!(task_dir)
    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      File.rm_rf!(task_dir)
    end)

    %{home: tmp, team_name: team_name, task_dir: task_dir}
  end

  describe "start_link/1 and stop/1" do
    test "starts and stops cleanly", %{home: home, team_name: team_name} do
      {:ok, pid} =
        StuckTaskDetector.start_link(
          team_name: team_name,
          infra_home: home,
          check_interval_ms: 60_000
        )

      assert Process.alive?(pid)
      StuckTaskDetector.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "detection loop" do
    test "force-completes stuck tasks", %{home: home, team_name: team_name, task_dir: task_dir} do
      # Create a stuck task (updated 15min ago)
      old_time =
        DateTime.utc_now()
        |> DateTime.add(-15 * 60, :second)
        |> DateTime.to_iso8601()

      task = %{
        "id" => "task-1",
        "status" => "in_progress",
        "owner" => "agent-1",
        "subject" => "stuck test task",
        "updatedAt" => old_time
      }

      File.write!(Path.join(task_dir, "task-1.json"), Jason.encode!(task))

      # Start detector with very short check interval
      {:ok, pid} =
        StuckTaskDetector.start_link(
          team_name: team_name,
          infra_home: home,
          stuck_threshold_ms: 1_000,
          check_interval_ms: 100
        )

      # Wait for at least one check cycle
      Process.sleep(300)
      StuckTaskDetector.stop(pid)

      # Verify task was force-completed
      {:ok, content} = File.read(Path.join(task_dir, "task-1.json"))
      {:ok, updated} = Jason.decode(content)
      assert updated["status"] == "completed"
      assert updated["forceCompleted"] == true
    end

    test "leaves fresh tasks alone", %{home: home, team_name: team_name, task_dir: task_dir} do
      task = %{
        "id" => "task-2",
        "status" => "in_progress",
        "owner" => "agent-1",
        "subject" => "fresh task",
        "updatedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.write!(Path.join(task_dir, "task-2.json"), Jason.encode!(task))

      {:ok, pid} =
        StuckTaskDetector.start_link(
          team_name: team_name,
          infra_home: home,
          stuck_threshold_ms: 600_000,
          check_interval_ms: 100
        )

      Process.sleep(300)
      StuckTaskDetector.stop(pid)

      {:ok, content} = File.read(Path.join(task_dir, "task-2.json"))
      {:ok, updated} = Jason.decode(content)
      assert updated["status"] == "in_progress"
    end
  end
end
