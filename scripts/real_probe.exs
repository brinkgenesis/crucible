# scripts/real_probe.exs
#
# Single-card probe against the REAL adapter. Captures the actual failure mode
# that's tripping the per-service circuit breaker on every live run.
#
# Usage: DATABASE_URL="postgresql://localhost:5432/crucible_dev" mix run scripts/real_probe.exs

defmodule RealProbe do
  alias Crucible.{Orchestrator, WorkflowStore, ExternalCircuitBreaker, Repo}
  alias Crucible.Kanban.DbAdapter
  alias Crucible.Schema.Card

  import Ecto.Query
  require Logger

  @workflow System.get_env("WORKFLOW", "harness-loop")

  def run do
    ExternalCircuitBreaker.reset(:elixir_sdk)
    IO.puts("→ reset :elixir_sdk circuit breaker")

    {:ok, wf} = WorkflowStore.get(@workflow)

    tag = "probe-#{System.system_time(:millisecond)}"

    {:ok, card} =
      DbAdapter.create_card(%{
        title: "[#{tag}] Print hello to stdout, nothing else.",
        column: "unassigned",
        workflow: @workflow,
        metadata: %{"probeTag" => tag}
      })

    {:ok, moved} = DbAdapter.move_card(card.id, "todo")
    run_id = "probe-" <> (:crypto.strong_rand_bytes(6) |> Base.hex_encode32(case: :lower, padding: false))

    manifest =
      wf
      |> Map.put("run_id", run_id)
      |> Map.put("workflow_name", wf["name"])
      |> Map.put("status", "pending")
      |> Map.put("execution_type", "subscription")
      |> Map.put("card_id", moved.id)
      |> Map.put("plan_note", nil)
      |> Map.put("plan_summary", "Print hello.")
      |> Map.put("task_description", "Print 'hello world' to stdout and stop.")
      |> Map.put("workspace_path", nil)
      |> Map.put("default_branch", "main")
      |> Map.put("workspace_name", nil)
      |> Map.put("tech_context", "")
      |> Map.put("created_at", DateTime.utc_now() |> DateTime.to_iso8601())

    :ok = Orchestrator.submit_run(manifest)
    {:ok, _} = DbAdapter.update_card(card.id, %{run_id: run_id})

    IO.puts("→ submitted run_id=#{run_id}, waiting for RunServer to start...")

    # Wait for Orchestrator to discover + spawn the RunServer. Poll tick is 2s.
    wait_for_registry(run_id, System.monotonic_time(:millisecond) + 15_000)

    IO.puts("→ polling for terminal state (max 5min)...")
    result_path = Path.join([File.cwd!(), ".claude-flow/runs", "#{run_id}.result.json"])
    wait_for_result(result_path, System.monotonic_time(:millisecond) + 300_000)

    case File.read(result_path) do
      {:ok, body} ->
        IO.puts("\n━━━ result ━━━")
        IO.puts(body)
      _ ->
        IO.puts("\n(no result file after 5min)")
    end

    IO.puts("\n━━━ circuit breaker state ━━━")
    IO.inspect(ExternalCircuitBreaker.status(), pretty: true)

    Repo.delete_all(from(c in Card, where: fragment("?->>'probeTag' = ?", c.metadata, ^tag)))
    IO.puts("\n(cleanup: removed probe cards)")
  end

  defp wait_for_registry(run_id, deadline) do
    case Orchestrator.lookup_run(run_id) do
      {:ok, _pid, _meta} ->
        IO.puts("  ✓ RunServer started for #{run_id}")
        :ok

      :not_found ->
        if System.monotonic_time(:millisecond) > deadline do
          IO.puts("\n  ⚠ RunServer never started within 15s — orchestrator may be down")
          :timeout
        else
          Process.sleep(500)
          IO.write(".")
          wait_for_registry(run_id, deadline)
        end
    end
  end

  defp wait_for_result(path, deadline) do
    cond do
      File.exists?(path) ->
        IO.puts("  ✓ result file written")
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        IO.puts("  ⚠ deadline reached")
        :timeout

      true ->
        Process.sleep(2_000)
        IO.write(".")
        wait_for_result(path, deadline)
    end
  end
end

Logger.configure(level: :info)
{:ok, _} = Application.ensure_all_started(:crucible)
Process.sleep(500)

RealProbe.run()
System.halt(0)
