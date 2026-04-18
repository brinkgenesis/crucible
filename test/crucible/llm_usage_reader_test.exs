defmodule Crucible.LLMUsageReaderTest do
  use ExUnit.Case, async: false

  alias Crucible.LLMUsageReader

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "llm_usage_reader_test_#{System.unique_integer([:positive])}")

    projects_root = Path.join(tmp_dir, "projects")
    infra_home = Path.join(tmp_dir, "infra-home")

    File.mkdir_p!(projects_root)
    File.mkdir_p!(Path.join([infra_home, ".claude-flow", "runs"]))
    File.mkdir_p!(Path.join([infra_home, ".claude-flow", "logs"]))

    project_dir = Path.join(projects_root, "-Users-helios-infra")
    other_project_dir = Path.join(projects_root, "-Users-helios-other")
    File.mkdir_p!(Path.join(project_dir, "subagents"))
    File.mkdir_p!(other_project_dir)

    write_transcript!(
      Path.join(project_dir, "lead-session.jsonl"),
      [
        assistant_entry("2026-03-14T16:00:00Z", "claude-sonnet-4-6", 100, 20, 30, 40),
        assistant_entry("2026-03-14T16:05:00Z", "claude-sonnet-4-6", 10, 5, 0, 20)
      ]
    )

    write_transcript!(
      Path.join(project_dir, "subagents/lifecycle-session.jsonl"),
      [
        assistant_entry("2026-03-14T16:10:00Z", "claude-opus-4-6", 50, 10, 5, 15)
      ]
    )

    write_transcript!(
      Path.join(other_project_dir, "other-session.jsonl"),
      [
        assistant_entry("2026-03-13T11:00:00Z", "claude-haiku-4-5", 7, 3, 2, 11)
      ]
    )

    snapshot = %{
      "teamName" => "team-alpha",
      "leadSessionId" => "lead-session",
      "members" => [%{"sessionId" => nil, "memberSessionId" => nil}]
    }

    File.write!(
      Path.join([infra_home, ".claude-flow", "runs", "team-alpha-run-1234abcd-snapshot.json"]),
      Jason.encode!(snapshot)
    )

    lifecycle_line = %{
      "event" => "teammate_idle",
      "team_name" => "team-alpha",
      "session_id" => "lifecycle-session"
    }

    File.write!(
      Path.join([infra_home, ".claude-flow", "logs", "agent-lifecycle.jsonl"]),
      Jason.encode!(lifecycle_line) <> "\n"
    )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{infra_home: infra_home, projects_root: projects_root}
  end

  test "build_summary returns transcript totals with cache separated", ctx do
    summary =
      LLMUsageReader.build_summary(
        infra_home: ctx.infra_home,
        projects_root: ctx.projects_root,
        cache: false,
        min_file_size: 0
      )

    assert summary["totalInputTokens"] == 167
    assert summary["totalOutputTokens"] == 38
    assert summary["totalCacheCreation"] == 37
    assert summary["totalCacheRead"] == 86
    assert summary["totalTokens"] == 242
    assert summary["totalTurns"] == 4
    assert summary["sessionCount"] == 3

    assert summary["byDate"] == %{
             "2026-03-13" => 12,
             "2026-03-14" => 230
           }

    assert summary["byDateModel"] == %{
             "2026-03-13" => %{"claude-haiku-4-5" => 12},
             "2026-03-14" => %{
               "claude-opus-4-6" => 65,
               "claude-sonnet-4-6" => 165
             }
           }

    assert summary["byModel"]["claude-sonnet-4-6"]["inputTokens"] == 110
    assert summary["byModel"]["claude-sonnet-4-6"]["cacheCreation"] == 30
    assert summary["byProject"]["infra"]["sessions"] == 2
    assert summary["sessions"] |> Enum.at(0) |> Map.get("sessionId") == "lifecycle-session"
  end

  test "run-scoped summary supplements snapshot sessions with lifecycle sessions", ctx do
    summary =
      LLMUsageReader.build_summary(
        infra_home: ctx.infra_home,
        projects_root: ctx.projects_root,
        run_id: "1234abcd-full-run-id",
        cache: false,
        min_file_size: 0
      )

    assert summary["sessionCount"] == 2

    assert Enum.map(summary["sessions"], & &1["sessionId"]) |> Enum.sort() == [
             "lead-session",
             "lifecycle-session"
           ]

    assert summary["totalInputTokens"] == 160
    assert summary["totalOutputTokens"] == 35
    assert summary["totalCacheCreation"] == 35
    assert summary["totalCacheRead"] == 75
    assert summary["totalTokens"] == 230
  end

  test "run-scoped summary can be seeded with extra session ids when snapshots are missing",
       ctx do
    summary =
      LLMUsageReader.build_summary(
        infra_home: ctx.infra_home,
        projects_root: ctx.projects_root,
        run_id: "missing-run-id",
        extra_session_ids: ["other-session"],
        cache: false,
        min_file_size: 0
      )

    assert summary["sessionCount"] == 1
    assert Enum.map(summary["sessions"], & &1["sessionId"]) == ["other-session"]
    assert summary["totalInputTokens"] == 7
    assert summary["totalOutputTokens"] == 3
    assert summary["totalTokens"] == 12
  end

  test "include_subscription=false returns an empty transcript summary", ctx do
    summary =
      LLMUsageReader.build_summary(
        infra_home: ctx.infra_home,
        projects_root: ctx.projects_root,
        include_subscription: false,
        cache: false,
        min_file_size: 0
      )

    assert summary["sessionCount"] == 0
    assert summary["sessions"] == []
    assert summary["totalTokens"] == 0
  end

  defp assistant_entry(timestamp, model, input_tokens, output_tokens, cache_creation, cache_read) do
    %{
      "type" => "assistant",
      "timestamp" => timestamp,
      "message" => %{
        "role" => "assistant",
        "model" => model,
        "usage" => %{
          "input_tokens" => input_tokens,
          "output_tokens" => output_tokens,
          "cache_creation_input_tokens" => cache_creation,
          "cache_read_input_tokens" => cache_read
        }
      }
    }
  end

  defp write_transcript!(path, entries) do
    File.write!(path, Enum.map_join(entries, "\n", &Jason.encode!/1) <> "\n")
  end
end
