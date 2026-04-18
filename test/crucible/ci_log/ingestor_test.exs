defmodule Crucible.CiLog.IngestorTest do
  use Crucible.DataCase, async: true

  alias Crucible.CiLog.Ingestor
  alias Crucible.Schema.CiLogEvent

  describe "build_failure_summary/1" do
    test "extracts error lines from log" do
      log = """
      Starting build...
      Compiling 42 files
      Error: cannot find module 'foo'
      Build failed with exit code 1
      Done in 12s
      """

      summary = Ingestor.build_failure_summary(log)
      assert summary =~ "Error: cannot find module"
      assert summary =~ "Build failed"
    end

    test "returns fallback when no error lines found" do
      log = "Step 1: ok\nStep 2: ok\nStep 3: ok"
      assert Ingestor.build_failure_summary(log) == "No error lines found"
    end

    test "limits to 10 error lines" do
      lines = for i <- 1..20, do: "Error line #{i}"
      log = Enum.join(lines, "\n")
      summary = Ingestor.build_failure_summary(log)
      line_count = summary |> String.split("\n") |> length()
      assert line_count == 10
    end

    test "handles empty string" do
      assert Ingestor.build_failure_summary("") == "No error lines found"
    end
  end

  describe "ingest/2 input validation" do
    test "rejects owner with path traversal" do
      assert {:error, :invalid_owner} = Ingestor.ingest("../../etc", "repo")
    end

    test "rejects repo with path traversal" do
      assert {:error, :invalid_repo} = Ingestor.ingest("owner", "../../orgs/evil")
    end

    test "rejects repo with query-string injection" do
      assert {:error, :invalid_repo} = Ingestor.ingest("owner", "repo?per_page=999")
    end

    test "rejects owner with slash" do
      assert {:error, :invalid_owner} = Ingestor.ingest("foo/bar", "repo")
    end

    test "accepts legitimate GitHub identifiers" do
      # No `gh` CLI available in test — just proves validation passed and we hit fetch_runs.
      result = Ingestor.ingest("Till-CFO", "loom-extractor")
      assert match?({:error, _}, result) or match?({:ok, _}, result)
      refute match?({:error, :invalid_owner}, result)
      refute match?({:error, :invalid_repo}, result)
    end
  end

  describe "already_ingested?/1" do
    test "returns false for unknown run_id" do
      refute Ingestor.already_ingested?("nonexistent-run-99999")
    end

    test "returns true for existing run_id" do
      {:ok, _event} =
        %CiLogEvent{}
        |> CiLogEvent.changeset(%{
          run_id: "already-here-123",
          workflow_name: "CI",
          conclusion: "failure"
        })
        |> Repo.insert()

      assert Ingestor.already_ingested?("already-here-123")
    end
  end

  describe "ingest_runs/3 (direct processing)" do
    test "ingests a valid run" do
      runs = [
        %{
          "id" => 900_001,
          "name" => "Unit Tests",
          "conclusion" => "failure",
          "status" => "completed",
          "createdAt" => "2026-04-13T10:00:00Z",
          "updatedAt" => "2026-04-13T10:05:00Z"
        }
      ]

      result = Ingestor.ingest_runs(runs, "owner", "repo")
      assert result.ingested == 1
      assert result.skipped == 0
      assert result.errors == 0
      assert length(result.events) == 1

      [event] = result.events
      assert event.run_id == "900001"
      assert event.workflow_name == "Unit Tests"
      assert event.conclusion == "failure"
      assert event.duration_ms == 300_000
    end

    test "skips already-ingested runs" do
      {:ok, _} =
        %CiLogEvent{}
        |> CiLogEvent.changeset(%{
          run_id: "900002",
          workflow_name: "CI",
          conclusion: "failure"
        })
        |> Repo.insert()

      runs = [
        %{
          "id" => 900_002,
          "name" => "CI",
          "conclusion" => "failure",
          "status" => "completed",
          "createdAt" => "2026-04-13T10:00:00Z",
          "updatedAt" => "2026-04-13T10:01:00Z"
        }
      ]

      result = Ingestor.ingest_runs(runs, "owner", "repo")
      assert result.ingested == 0
      assert result.skipped == 1
    end

    test "handles multiple runs with mixed outcomes" do
      {:ok, _} =
        %CiLogEvent{}
        |> CiLogEvent.changeset(%{
          run_id: "900010",
          workflow_name: "Old",
          conclusion: "failure"
        })
        |> Repo.insert()

      runs = [
        %{
          "id" => 900_010,
          "name" => "Old",
          "conclusion" => "failure",
          "status" => "completed",
          "createdAt" => "2026-04-13T10:00:00Z",
          "updatedAt" => "2026-04-13T10:01:00Z"
        },
        %{
          "id" => 900_011,
          "name" => "New",
          "conclusion" => "failure",
          "status" => "completed",
          "createdAt" => "2026-04-13T10:00:00Z",
          "updatedAt" => "2026-04-13T10:02:00Z"
        }
      ]

      result = Ingestor.ingest_runs(runs, "owner", "repo")
      assert result.ingested == 1
      assert result.skipped == 1
    end
  end
end
