# scripts/stress_e2e.exs
#
# Crucible end-to-end stress test — drives the full chain:
#
#   seed inbox_items → Inbox.Scanner.scan (LLM stub) → cards in unassigned →
#   concurrent DbAdapter.move_card → Orchestrator.submit_run → RunServer →
#   manifest terminal state
#
# Purpose: prove the E2E path is clean before the repo ships as open source.
#
# Modes:
#   default — InstantAdapter + stub router, zero LLM spend.
#             Two phases: (seed 10, run 5) and (seed 10, run 10).
#   REAL=1  — real SDK adapter, stub router for triage (that path is already
#             covered). One phase only, default N=3 to cap spend. Expect
#             ~$0.50-2 total and ~60-90s per card.
#
# Non-destructive: seeded inbox items use far-past ingested_at + max_items=N
# so Scanner only processes our seeds, never touches pre-existing unread items.
#
# Usage:
#   mix run scripts/stress_e2e.exs              # instant, two phases
#   REAL=1 mix run scripts/stress_e2e.exs       # real adapter, N=3, one phase
#   REAL=1 N=5 mix run scripts/stress_e2e.exs   # real adapter, N=5
#
# Exit: 0 when every submitted run reaches terminal state, 1 otherwise.

defmodule StressE2E.InstantAdapter do
  @moduledoc "Zero-cost adapter override for stress testing."
  @behaviour Crucible.Adapter.Behaviour

  @impl true
  def execute_phase(_run, _phase, _prompt, _opts) do
    {:ok,
     %{
       status: :completed,
       output: "stress-e2e-instant",
       exit_status: 0,
       cost_usd: 0.0,
       turns: 1,
       session_id: "stress-e2e-" <> Integer.to_string(:erlang.unique_integer([:positive]))
     }}
  end

  @impl true
  def cleanup_artifacts(_run, _phase), do: :ok
end

defmodule StressE2E do
  alias Crucible.{Inbox, Orchestrator, Repo, WorkflowStore}
  alias Crucible.Inbox.Scanner
  alias Crucible.Kanban.DbAdapter
  alias Crucible.Schema.{Card, InboxItem}

  import Ecto.Query
  require Logger

  @poll_interval_ms 250
  @base_timeout_ms 30_000
  @instant_per_card_ms 2_000
  @real_per_card_ms 120_000
  @workflow "harness-loop"

  # Far-past ingested_at so our seeds sort before any pre-existing unread
  # items and get loaded first when Scanner asks for the oldest N.
  @far_past ~U[1970-01-01 00:00:00Z]

  def run(opts \\ []) do
    real? = Keyword.get(opts, :real, false)
    real_n = Keyword.get(opts, :n, 3)

    IO.puts("\n━━━ Crucible E2E stress test ━━━")

    tag = "stress-#{System.system_time(:millisecond)}"
    IO.puts("  tag=#{tag}")
    IO.puts("  mode=#{if real?, do: "REAL adapter (network + $)", else: "instant adapter"}")
    IO.puts("  adapter_override=#{inspect(Application.get_env(:crucible, :adapter_override))}")
    IO.puts("  pre-existing unread inbox items=#{count_preexisting_unread()}")

    unless workflow_loaded?(@workflow, 5_000) do
      exit_with("Workflow '#{@workflow}' not found in WorkflowStore")
    end

    if real?, do: reset_sdk_circuits()

    phases =
      if real? do
        IO.puts("\n▶ Phase R: seed #{real_n} → scan → run #{real_n} concurrent (REAL)")
        r = e2e_phase(real_n, real_n, tag, "r", real?)
        report_phase(r)
        [{"R (N=#{real_n})", r}]
      else
        IO.puts("\n▶ Phase A: seed 10 → scan (cap 10) → run 5 concurrent")
        a = e2e_phase(10, 5, tag, "a", real?)
        report_phase(a)
        IO.puts("\n▶ Phase B: seed 10 → scan (cap 10) → run 10 concurrent")
        b = e2e_phase(10, 10, tag, "b", real?)
        report_phase(b)
        [{"A (N=5)", a}, {"B (N=10)", b}]
      end

    IO.puts("\n▶ Refinement sanity probe")
    refine = refinement_probe()
    IO.puts("  #{refine}")

    Process.sleep(500)
    cleanup_all(tag)

    pass = Enum.all?(phases, fn {_l, p} -> p.pass? end)

    IO.puts("\n━━━ Summary ━━━")
    Enum.each(phases, fn {label, p} -> IO.puts("  #{label}: #{status_str(p)}") end)
    IO.puts("  refine:   #{refine}")

    if real? do
      total_cost = phases |> Enum.map(fn {_l, p} -> Map.get(p, :cost_usd, 0.0) end) |> Enum.sum()
      IO.puts("  total cost: $#{:erlang.float_to_binary(total_cost * 1.0, decimals: 4)}")
    end

    if pass do
      IO.puts("\n✓ stress test clean")
      :ok
    else
      IO.puts("\n✗ stress test had failures")
      {:error, :failures}
    end
  end

  # ── One E2E phase: seed → scan → submit → poll ────────────────────────

  defp e2e_phase(seed_count, run_count, tag, label, real?) do
    item_ids = seed_inbox(seed_count, tag, label, real?)
    IO.puts("  seeded #{length(item_ids)} inbox items (ingested_at=far-past, status=unread)")

    {:ok, scan_result} =
      Scanner.scan(router_fn: deterministic_router(), max_items: seed_count)

    IO.puts(
      "  scan: evaluated=#{scan_result.evaluated} " <>
        "cards_created=#{scan_result.cards_created} " <>
        "dismissed=#{scan_result.dismissed} " <>
        "for_review=#{scan_result.for_review} " <>
        "errors=#{scan_result.errors}"
    )

    card_ids = card_ids_for_items(item_ids)
    IO.puts("  resolved #{length(card_ids)} cards from our seeded items")

    cards_to_run = Enum.take(card_ids, run_count)
    {:ok, workflow_config} = WorkflowStore.get(@workflow)

    submission_results =
      cards_to_run
      |> Task.async_stream(
        fn id -> submit_card(id, workflow_config) end,
        max_concurrency: run_count,
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
    IO.puts("  submitted #{length(submitted)}/#{run_count} (submit failures: #{submit_failures})")

    per_card = if real?, do: @real_per_card_ms, else: @instant_per_card_ms
    timeout_ms = @base_timeout_ms + per_card * run_count
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    terminal = poll_runs(submitted, deadline)

    completed = Enum.count(terminal, &match?({_id, :completed}, &1))
    failed = Enum.count(terminal, &match?({_id, :failed}, &1))
    stuck = length(submitted) - length(terminal)

    cost_usd = if real?, do: sum_run_costs(submitted), else: 0.0

    %{
      seed: seed_count,
      cards_created: scan_result.cards_created,
      resolved_cards: length(card_ids),
      target: run_count,
      submitted: length(submitted),
      completed: completed,
      failed: failed,
      stuck: stuck,
      cost_usd: cost_usd,
      pass?:
        length(submitted) == run_count and completed == run_count and failed == 0 and stuck == 0
    }
  end

  # ── Inbox seeding ─────────────────────────────────────────────────────

  defp seed_inbox(n, tag, label, real?) do
    for i <- 1..n do
      # Real-adapter titles need a concrete task the model can finish fast.
      title =
        if real? do
          "[#{tag}] Print the number #{i} to stdout and stop."
        else
          "[#{tag}] Stress #{label}-#{i}"
        end

      {:ok, item} =
        Inbox.upsert_from_ingestion(%{
          source: "manual",
          source_id: "#{tag}-#{label}-#{i}",
          status: "unread",
          title: title,
          original_text:
            "Synthetic high-signal task #{i} for stress testing the inbox→card→run path.",
          summary: "Stress test item #{label}-#{i}.",
          ingested_at: @far_past,
          metadata: %{"stress_tag" => tag}
        })

      item.id
    end
  end

  # Deterministic high-score stub — every item auto-promotes. Scanner still
  # applies its own 10-per-scan cap.
  defp deterministic_router do
    payload =
      Jason.encode!(%{
        "dimensions" => [
          %{"criterion" => "actionability", "score" => 9, "note" => "clear"},
          %{"criterion" => "relevance", "score" => 9, "note" => "on-target"},
          %{"criterion" => "specificity", "score" => 9, "note" => "concrete"},
          %{"criterion" => "strategic_value", "score" => 9, "note" => "valuable"}
        ],
        "labels" => ["feature"],
        "feedback" => "Stress-test synthetic item — auto-promote."
      })

    fn _request -> {:ok, %{text: payload}} end
  end

  defp card_ids_for_items([]), do: []

  defp card_ids_for_items(item_ids) do
    from(c in Card,
      where:
        fragment(
          "?->>'inbox_item_id' = ANY(?)",
          c.metadata,
          type(^item_ids, {:array, :string})
        ),
      order_by: [asc: c.created_at],
      select: c.id
    )
    |> Repo.all()
  end

  # ── Run submission (mirrors KanbanLive.maybe_trigger_workflow path) ───

  defp submit_card(card_id, workflow_config) do
    with {:ok, moved} <- DbAdapter.move_card(card_id, "todo"),
         run_id <- gen_run_id(),
         manifest <- build_manifest(run_id, workflow_config, moved),
         :ok <- Orchestrator.submit_run(manifest),
         {:ok, _} <- DbAdapter.update_card(card_id, %{run_id: run_id}) do
      {:ok, run_id}
    else
      err -> {:error, err}
    end
  end

  defp build_manifest(run_id, workflow_config, card) do
    plan_note = get_in(card.metadata || %{}, ["planNote"])
    plan_summary = get_in(card.metadata || %{}, ["planSummary"])
    workflow_name = workflow_config["name"] || workflow_config["workflow_name"]

    workflow_config
    |> Map.put("run_id", run_id)
    |> Map.put("workflow_name", workflow_name)
    |> Map.put("status", "pending")
    |> Map.put("execution_type", "subscription")
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
    "stress-" <>
      (:crypto.strong_rand_bytes(6) |> Base.hex_encode32(case: :lower, padding: false))
  end

  # ── Polling (manifest file = orchestrator ground truth) ───────────────

  defp poll_runs(run_ids, deadline), do: poll_runs(run_ids, deadline, %{})

  defp poll_runs(run_ids, deadline, acc) do
    pending = Enum.reject(run_ids, &Map.has_key?(acc, &1))

    cond do
      pending == [] ->
        Map.to_list(acc)

      System.monotonic_time(:millisecond) > deadline ->
        IO.puts("    ⚠ timeout — #{length(pending)} runs still non-terminal")
        Map.to_list(acc)

      true ->
        new_acc =
          Enum.reduce(pending, acc, fn rid, m ->
            case run_status(rid) do
              {:terminal, s} -> Map.put(m, rid, s)
              :still_running -> m
            end
          end)

        Process.sleep(@poll_interval_ms)
        poll_runs(run_ids, deadline, new_acc)
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

  # ── Refinement sanity probe ───────────────────────────────────────────

  defp refinement_probe do
    case probe_dashboard("http://localhost:4800/api/inbox/counts") do
      :up -> "infra dashboard on :4800 reachable — refinement hop is available"
      :down -> "infra dashboard on :4800 not reachable — refinement skipped (expected if dashboard not running)"
    end
  end

  defp probe_dashboard(url) do
    :inets.start()
    :ssl.start()

    try do
      case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 2_000}], []) do
        {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :up
        _ -> :down
      end
    rescue
      _ -> :down
    catch
      _, _ -> :down
    end
  end

  # ── Workflow-store readiness ──────────────────────────────────────────

  defp workflow_loaded?(name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_loop(name, deadline)
  end

  defp wait_loop(name, deadline) do
    case WorkflowStore.get(name) do
      {:ok, _} ->
        true

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          false
        else
          Process.sleep(200)
          wait_loop(name, deadline)
        end
    end
  end

  # ── Cleanup ───────────────────────────────────────────────────────────

  defp cleanup_all(tag) do
    item_ids =
      from(i in InboxItem,
        where: fragment("?->>'stress_tag' = ?", i.metadata, ^tag),
        select: i.id
      )
      |> Repo.all()

    if item_ids != [] do
      from(c in Card,
        where:
          fragment(
            "?->>'inbox_item_id' = ANY(?)",
            c.metadata,
            type(^item_ids, {:array, :string})
          )
      )
      |> Repo.delete_all()
    end

    from(i in InboxItem, where: fragment("?->>'stress_tag' = ?", i.metadata, ^tag))
    |> Repo.delete_all()

    runs_dir = Path.join(File.cwd!(), ".claude-flow/runs")

    if File.dir?(runs_dir) do
      runs_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "stress-"))
      |> Enum.each(&File.rm(Path.join(runs_dir, &1)))
    end

    :ok
  end

  defp count_preexisting_unread do
    Repo.aggregate(from(i in InboxItem, where: i.status == "unread"), :count)
  end

  # Pre-run: zombie runs from earlier sessions may have tripped circuits.
  # Clear before a real batch so the first card doesn't inherit a cooldown.
  defp reset_sdk_circuits do
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

  # Read cost_usd from each run's manifest after completion.
  defp sum_run_costs(run_ids) do
    Enum.reduce(run_ids, 0.0, fn rid, acc ->
      path = Path.join([File.cwd!(), ".claude-flow/runs", "#{rid}.json"])

      cost =
        case File.read(path) do
          {:ok, body} ->
            case Jason.decode(body) do
              {:ok, manifest} -> extract_cost(manifest)
              _ -> 0.0
            end

          _ ->
            0.0
        end

      acc + cost
    end)
  end

  defp extract_cost(manifest) do
    case manifest do
      %{"cost_usd" => c} when is_number(c) -> c * 1.0
      %{"total_cost_usd" => c} when is_number(c) -> c * 1.0
      %{"phases" => phases} when is_list(phases) ->
        Enum.reduce(phases, 0.0, fn p, acc ->
          acc + (Map.get(p, "cost_usd", 0) * 1.0)
        end)
      _ -> 0.0
    end
  end

  # ── Reporting ─────────────────────────────────────────────────────────

  defp status_str(p) do
    ok = if p.pass?, do: "✓", else: "✗"

    "#{ok} seeded=#{p.seed} cards_created=#{p.cards_created} resolved=#{p.resolved_cards} " <>
      "target=#{p.target} submitted=#{p.submitted} completed=#{p.completed} " <>
      "failed=#{p.failed} stuck=#{p.stuck}"
  end

  defp report_phase(p) do
    IO.puts("  " <> status_str(p))
  end

  defp exit_with(msg) do
    IO.puts("FATAL: #{msg}")
    System.halt(1)
  end
end

# ── Boot ──────────────────────────────────────────────────────────────
real? = System.get_env("REAL") in ["1", "true", "yes"]

unless real? do
  Application.put_env(:crucible, :adapter_override, StressE2E.InstantAdapter)
end

Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:crucible)
Process.sleep(500)

n = System.get_env("N", "3") |> String.to_integer()

case StressE2E.run(real: real?, n: n) do
  :ok -> System.halt(0)
  _ -> System.halt(1)
end
