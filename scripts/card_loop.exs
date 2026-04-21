# scripts/card_loop.exs
#
# Concurrency harness: drives N cards through the real kanban → orchestrator →
# run-server → phase-runner path in programmatic loops. Uses an InstantAdapter
# override so no LLM API budget is burned — what we're stressing is the
# orchestration layer (slot store, run supervisor, advisory locks, card<->run
# reconciliation), not the model.
#
# Usage:
#   mix run scripts/card_loop.exs                        # instant adapter, 3x10
#   N=25 ITERS=5 mix run scripts/card_loop.exs           # instant adapter, custom
#   REAL=1 mix run scripts/card_loop.exs                 # REAL adapter, 1x3 default
#   REAL=1 N=3 WORKFLOW=harness-loop mix run scripts/card_loop.exs
#
# REAL=1 skips the InstantAdapter override so runs hit the actual SDK/router
# pipeline (network + spend). Defaults to N=3 ITERS=1 to cap cost; set
# WORKFLOW=harness-loop for session-only or WORKFLOW=harness-team for team path.
#
# Exit status: 0 when every iteration reaches 100% card completion; 1 otherwise.

# ── Inline mock adapter (load_test_helpers is test-only) ──────────────
defmodule CardLoop.InstantAdapter do
  @moduledoc "Returns :ok instantly. Used only by the card-loop harness."
  @behaviour Crucible.Adapter.Behaviour

  @impl true
  def execute_phase(_run, _phase, _prompt, _opts) do
    {:ok,
     %{
       status: :completed,
       output: "card-loop-instant",
       exit_status: 0,
       cost_usd: 0.0,
       turns: 1,
       session_id: "card-loop-" <> Integer.to_string(:erlang.unique_integer([:positive]))
     }}
  end

  @impl true
  def cleanup_artifacts(_run, _phase), do: :ok
end

defmodule CardLoop do
  alias Crucible.{Orchestrator, WorkflowStore}
  alias Crucible.Kanban.DbAdapter
  alias Crucible.Repo
  alias Crucible.Schema.Card

  import Ecto.Query

  require Logger

  @poll_interval_ms 250
  # Orchestrator tick = 2s; each run takes ~1-2 ticks to dispatch + run.
  # Real runs are network-bound and take ~45-90s each — scale generously.
  @base_timeout_ms 30_000
  @instant_per_card_ms 2_000
  @real_per_card_ms 90_000

  def run(opts \\ []) do
    n = Keyword.get(opts, :cards, 10)
    iters = Keyword.get(opts, :iters, 3)
    real? = Keyword.get(opts, :real, false)
    workflow_name = Keyword.get(opts, :workflow, "harness-loop")

    IO.puts("\n━━━ Card loop harness ━━━")
    IO.puts("  iterations=#{iters}  cards_per_iter=#{n}  workflow=#{workflow_name}")
    IO.puts("  mode=#{if real?, do: "REAL adapter", else: "instant adapter override"}")
    IO.puts("  adapter_override=#{inspect(Application.get_env(:crucible, :adapter_override))}")
    IO.puts("")

    if real?, do: reset_sdk_circuits()

    # Confirm the workflow is loaded (WorkflowStore polls the filesystem)
    wait_for_workflow(workflow_name, 5_000) ||
      exit_with("Workflow '#{workflow_name}' not found in WorkflowStore")

    results =
      for iter <- 1..iters do
        IO.puts("▶ iter #{iter}/#{iters}")
        {elapsed_us, result} = :timer.tc(fn -> run_iteration(n, iter, workflow_name, real?) end)
        summarize(iter, result, elapsed_us / 1_000_000.0)
        {iter, result}
      end

    failures =
      Enum.count(results, fn {_i, r} -> r.completed != r.total or r.failed > 0 end)

    IO.puts("\n━━━ Summary ━━━")
    Enum.each(results, fn {i, r} ->
      IO.puts(
        "  iter #{i}: #{r.completed}/#{r.total} complete, #{r.failed} failed, #{r.stuck} stuck"
      )
    end)

    # Final sweep — ResultWriter writes result files asynchronously and can
    # land after per-iter cleanup has already run.
    Process.sleep(500)
    final_sweep()

    if failures == 0 do
      IO.puts("\n✓ #{iters}/#{iters} clean iterations")
      :ok
    else
      IO.puts("\n✗ #{failures}/#{iters} iterations had failures")
      {:error, failures}
    end
  end

  defp final_sweep do
    # ResultWriter + sentinel writes are async — re-sweep a few times to catch
    # straggling writes after runs terminate.
    Enum.each(1..5, fn _ ->
      runs_dir = Path.join(File.cwd!(), ".claude-flow/runs")

      if File.dir?(runs_dir) do
        runs_dir
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "loop-"))
        |> Enum.each(&File.rm(Path.join(runs_dir, &1)))
      end

      Process.sleep(200)
    end)

    :ok
  end

  # ── One iteration ─────────────────────────────────────────────────────

  defp run_iteration(n, iter, workflow_name, real?) do
    adapter = DbAdapter

    # 1. Seed N cards in :unassigned. Use a unique tag so we can clean up later.
    tag = "loop-i#{iter}-#{System.system_time(:millisecond)}"

    # Real runs need a concrete task string the model can finish quickly.
    title_of = fn i ->
      if real? do
        "[#{tag}] Print the number #{i} to stdout and stop."
      else
        "[#{tag}] card #{i}"
      end
    end

    card_ids =
      for i <- 1..n do
        {:ok, card} =
          adapter.create_card(%{
            title: title_of.(i),
            column: "unassigned",
            workflow: workflow_name,
            metadata: %{"loopTag" => tag, "loopIter" => iter}
          })

        card.id
      end

    # 2. Batch-move to :todo (same as KanbanLive.execute_selected would do).
    #    Submit run manifests concurrently — this is what the LiveView's
    #    `execute_selected` handler does via maybe_trigger_workflow/3.
    {:ok, workflow_config} = WorkflowStore.get(workflow_name)

    submission_results =
      card_ids
      |> Task.async_stream(
        fn id -> submit_card(adapter, id, workflow_config) end,
        max_concurrency: n,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, r} -> r
        {:exit, reason} -> {:error, {:submit_exit, reason}}
      end)

    submitted =
      Enum.flat_map(submission_results, fn
        {:ok, run_id} -> [run_id]
        _ -> []
      end)

    submit_failures = length(submission_results) - length(submitted)

    IO.puts(
      "  submitted #{length(submitted)}/#{n} (#{submit_failures} submit failures)"
    )

    # 3. Poll until all runs reach terminal state or we hit timeout.
    per_card = if real?, do: @real_per_card_ms, else: @instant_per_card_ms
    timeout_ms = @base_timeout_ms + per_card * n
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    terminal = poll_runs(submitted, deadline)

    # 4. Tally from disk manifests (ground truth for orchestrator) + cards.
    completed = Enum.count(terminal, &match?({_id, :completed}, &1))
    failed = Enum.count(terminal, &match?({_id, :failed}, &1))
    stuck = length(submitted) - length(terminal) + submit_failures

    cleanup(tag)

    %{
      total: n,
      submitted: length(submitted),
      completed: completed,
      failed: failed,
      stuck: stuck
    }
  end

  defp submit_card(adapter, card_id, workflow_config) do
    with {:ok, moved} <- adapter.move_card(card_id, "todo"),
         run_id <- gen_run_id(),
         manifest <- build_manifest(run_id, workflow_config, moved, "subscription"),
         :ok <- Orchestrator.submit_run(manifest),
         {:ok, _} <- adapter.update_card(card_id, %{run_id: run_id}) do
      {:ok, run_id}
    else
      err -> {:error, err}
    end
  end

  defp build_manifest(run_id, workflow_config, card, execution_mode) do
    # Mirror of CrucibleWeb.KanbanLive.build_manifest/4 but without workspace
    # resolution — the harness doesn't bind cards to a workspace.
    plan_note = get_in(card.metadata || %{}, ["planNote"])
    plan_summary = get_in(card.metadata || %{}, ["planSummary"])
    workflow_name = workflow_config["name"] || workflow_config["workflow_name"]

    workflow_config
    |> Map.put("run_id", run_id)
    |> Map.put("workflow_name", workflow_name)
    |> Map.put("status", "pending")
    |> Map.put("execution_type", execution_mode)
    |> Map.put("card_id", card.id)
    |> Map.put("plan_note", plan_note)
    |> Map.put("plan_summary", plan_summary)
    |> Map.put("task_description", card.title)
    |> Map.put("workspace_path", nil)
    |> Map.put("default_branch", "main")
    |> Map.put("workspace_name", nil)
    |> Map.put("tech_context", "")
    |> Map.put("created_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp gen_run_id do
    "loop-" <> (:crypto.strong_rand_bytes(6) |> Base.hex_encode32(case: :lower, padding: false))
  end

  # ── Polling ───────────────────────────────────────────────────────────

  defp poll_runs(run_ids, deadline) do
    poll_runs(run_ids, deadline, %{})
  end

  defp poll_runs(run_ids, deadline, acc) do
    pending = Enum.reject(run_ids, &Map.has_key?(acc, &1))

    cond do
      pending == [] ->
        Map.to_list(acc)

      System.monotonic_time(:millisecond) > deadline ->
        IO.puts("  ⚠ timeout — #{length(pending)} runs still non-terminal")
        Map.to_list(acc)

      true ->
        new_terminal = Enum.reduce(pending, acc, fn rid, m ->
          case run_status(rid) do
            {:terminal, s} -> Map.put(m, rid, s)
            :still_running -> m
          end
        end)

        Process.sleep(@poll_interval_ms)
        poll_runs(run_ids, deadline, new_terminal)
    end
  end

  defp run_status(run_id) do
    case Orchestrator.lookup_run(run_id) do
      {:ok, _pid, _meta} ->
        :still_running

      :not_found ->
        case read_manifest_status(run_id) do
          s when s in ["completed", "done", "succeeded"] -> {:terminal, :completed}
          s when s in ["failed", "errored", "cancelled"] -> {:terminal, :failed}
          "pending" -> :still_running
          "running" -> :still_running
          nil -> :still_running
          _ -> :still_running
        end
    end
  end

  defp read_manifest_status(run_id) do
    path = Path.join([File.cwd!(), ".claude-flow/runs", "#{run_id}.json"])

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"status" => s}} -> s
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ── Workflow-store readiness ──────────────────────────────────────────

  defp wait_for_workflow(name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_workflow_loop(name, deadline)
  end

  defp wait_for_workflow_loop(name, deadline) do
    case WorkflowStore.get(name) do
      {:ok, _} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          nil
        else
          Process.sleep(200)
          wait_for_workflow_loop(name, deadline)
        end
    end
  end

  # ── Cleanup ───────────────────────────────────────────────────────────

  defp cleanup(tag) do
    from(c in Card, where: fragment("?->>'loopTag' = ?", c.metadata, ^tag))
    |> Repo.delete_all()

    # Remove harness manifests + result files so they don't accumulate.
    runs_dir = Path.join(File.cwd!(), ".claude-flow/runs")

    if File.dir?(runs_dir) do
      runs_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "loop-"))
      |> Enum.each(&File.rm(Path.join(runs_dir, &1)))
    end

    :ok
  end

  defp summarize(iter, r, elapsed_s) do
    status = if r.completed == r.total and r.failed == 0, do: "✓", else: "✗"

    IO.puts(
      "  #{status} iter #{iter}: #{r.completed}/#{r.total} done, " <>
        "#{r.failed} failed, #{r.stuck} stuck in #{:erlang.float_to_binary(elapsed_s, decimals: 2)}s"
    )
  end

  defp exit_with(msg) do
    IO.puts("FATAL: #{msg}")
    System.halt(1)
  end

  defp reset_sdk_circuits do
    # Prior probes / zombie runs may have tripped these. Clear before a real
    # batch so the first card doesn't inherit a cooldown from a dead process.
    Enum.each([:elixir_sdk, :claude_sdk, :anthropic, :model_router], fn s ->
      try do
        Crucible.ExternalCircuitBreaker.reset(s)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    IO.puts("  reset SDK/provider circuit breakers")
  end
end

# ── Boot ──────────────────────────────────────────────────────────────
real? = System.get_env("REAL") in ["1", "true", "yes"]

unless real? do
  Application.put_env(:crucible, :adapter_override, CardLoop.InstantAdapter)
end

# Quiet the debug SQL firehose — keep warnings and errors.
Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:crucible)

# Give the orchestrator + workflow store a tick to come up
Process.sleep(500)

# Real batches are network + cost bound; default to a small N/ITERS so the
# harness doesn't accidentally burn $$$.
default_n = if real?, do: "3", else: "10"
default_iters = if real?, do: "1", else: "3"

n = String.to_integer(System.get_env("N", default_n))
iters = String.to_integer(System.get_env("ITERS", default_iters))
workflow = System.get_env("WORKFLOW", "harness-loop")

case CardLoop.run(cards: n, iters: iters, real: real?, workflow: workflow) do
  :ok -> System.halt(0)
  _ -> System.halt(1)
end
