# Exclude docker integration tests by default. Run with: mix test --include docker
ExUnit.start(exclude: [:docker])
Ecto.Adapters.SQL.Sandbox.mode(Crucible.Repo, :manual)

# Create isolated test directories so ResultWriter/Orchestrator don't pollute
# the real .claude-flow/runs/ directory with thousands of test artifacts.
orchestrator_cfg = Application.get_env(:crucible, :orchestrator, [])
test_root = Keyword.get(orchestrator_cfg, :repo_root, File.cwd!())
runs_dir = Keyword.get(orchestrator_cfg, :runs_dir, Path.join(test_root, ".claude-flow/runs"))
logs_dir = Path.join(test_root, ".claude-flow/logs")
File.mkdir_p!(runs_dir)
File.mkdir_p!(logs_dir)

# Ensure PubSub is running for pipeline tests
case Phoenix.PubSub.Supervisor.start_link(name: Crucible.PubSub) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end
