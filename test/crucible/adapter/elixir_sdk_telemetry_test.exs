defmodule Crucible.Adapter.ElixirSdk.TelemetryTest do
  use Crucible.DataCase, async: false

  alias Crucible.Adapter.ElixirSdk.Telemetry
  alias Crucible.Repo
  alias Crucible.Schema.TraceEvent

  import Ecto.Query

  # Telemetry writes go through module GenServers that buffer and flush async.
  # Give them time to drain before asserting.
  @flush_wait_ms 200

  setup do
    tmp_root =
      Path.join(System.tmp_dir!(), "crucible-telemetry-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_root)
    prior = Application.get_env(:crucible, :orchestrator, [])
    Application.put_env(:crucible, :orchestrator, Keyword.put(prior, :repo_root, tmp_root))

    on_exit(fn ->
      Application.put_env(:crucible, :orchestrator, prior)
      File.rm_rf(tmp_root)
    end)

    %{tmp_root: tmp_root}
  end

  test "phase_start + phase_end emit DB trace events with session_id tagged for the run",
       %{tmp_root: tmp_root} do
    run_id = "rt-#{System.unique_integer([:positive])}"
    phase_id = "phase-0"
    session_id = "ses-#{System.unique_integer([:positive])}"
    run = %{id: run_id, client_id: nil, workspace_path: tmp_root}
    phase = %{id: phase_id, name: "sprint", type: :team, agents: [%{role: "coder"}]}

    :ok = Telemetry.phase_start(run, phase, session_id, ["coder"])

    :ok =
      Telemetry.record_tool_call(run, phase, session_id, %{
        name: "Read",
        input: %{"file_path" => "foo.ex"},
        tool_use_id: "tu_1"
      })

    result = %{
      usage: %{input: 1000, output: 200, cache_read: 50},
      turns: 3,
      tool_calls: 1,
      cost: 0.01
    }

    :ok = Telemetry.phase_end(run, phase, session_id, ["coder"], result, "claude-sonnet-4-6")

    :ok = wait_for_flush()

    events =
      Repo.all(
        from(e in TraceEvent,
          where: e.run_id == ^run_id,
          order_by: [asc: e.id]
        )
      )

    event_types = events |> Enum.map(& &1.event_type) |> Enum.sort()

    # phase_start, tool_call, phase_end, token_efficiency
    assert "phase_start" in event_types
    assert "tool_call" in event_types
    assert "phase_end" in event_types
    assert "token_efficiency" in event_types

    # Every event must carry the session_id — this is what makes
    # CostEventReader.sessions_for_run group them as one session row.
    for e <- events do
      assert e.session_id == session_id, "missing session_id on #{e.event_type}"
      assert e.phase_id == phase_id
    end

    # token_efficiency carries the cost/token metadata the Sessions tab reads.
    te = Enum.find(events, &(&1.event_type == "token_efficiency"))
    assert te.metadata["model"] == "claude-sonnet-4-6"
    assert te.metadata["costUsd"] == 0.01
    assert te.metadata["inputTokens"] == 1000
  end

  test "phase_start writes an agent-lifecycle.jsonl line per agent", %{tmp_root: tmp_root} do
    run_id = "rl-#{System.unique_integer([:positive])}"
    session_id = "ses-lifecycle"
    run = %{id: run_id, client_id: nil, workspace_path: tmp_root}
    phase = %{id: "phase-0", name: "sprint", type: :team, agents: []}

    :ok = Telemetry.phase_start(run, phase, session_id, ["coder-backend", "reviewer"])

    path = Path.join([tmp_root, ".claude-flow/logs/agent-lifecycle.jsonl"])
    assert File.exists?(path), "lifecycle file not created"

    entries =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["run_id"] == run_id))

    assert length(entries) == 2
    agent_types = entries |> Enum.map(& &1["agent_type"]) |> Enum.sort()
    assert agent_types == ["coder-backend", "reviewer"]
    assert Enum.all?(entries, &(&1["event"] == "spawned"))
    assert Enum.all?(entries, &(&1["session_id"] == session_id))
  end

  test "session log captures tool calls between phase_start and phase_end", %{tmp_root: tmp_root} do
    run_id = "rs-#{System.unique_integer([:positive])}"
    phase_id = "phase-1"
    session_id = "ses-log"
    run = %{id: run_id, client_id: nil, workspace_path: tmp_root}
    phase = %{id: phase_id, name: "sprint", type: :team, agents: [%{role: "coder"}]}

    Telemetry.phase_start(run, phase, session_id, ["coder"])

    Telemetry.record_tool_call(run, phase, session_id, %{
      name: "Bash",
      input: %{"command" => "ls"},
      tool_use_id: "tu_a"
    })

    Telemetry.record_tool_result(run, phase, %{name: "Bash", output: "file1\nfile2"})
    result = %{usage: %{input: 10, output: 5, cache_read: 0}, turns: 1, tool_calls: 1, cost: 0.0}
    Telemetry.phase_end(run, phase, session_id, ["coder"], result, "claude-sonnet-4-6")

    path = Path.join([tmp_root, ".claude-flow/logs/sessions/#{run_id}-#{phase_id}.log"])
    assert File.exists?(path)
    content = File.read!(path)
    assert content =~ "phase_start #{phase_id}"
    assert content =~ "[tool_call] Bash"
    assert content =~ "[tool_result] Bash"
    assert content =~ "phase_end #{phase_id}"
  end

  defp wait_for_flush do
    # TraceEventWriter batches to DB every 5s, but we also flush on
    # terminate. The simpler path: manually send :flush and poll.
    send(Process.whereis(Crucible.TraceEventWriter), :flush)
    Process.sleep(@flush_wait_ms)
    :ok
  end
end
