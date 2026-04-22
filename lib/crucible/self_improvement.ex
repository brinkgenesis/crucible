defmodule Crucible.SelfImprovement do
  @moduledoc """
  GenServer for periodic KPI snapshot and prompt hint generation.
  Runs when triggered by the execution engine and on a timer (every 30 min).
  Reads trace JSONL, builds KPI snapshots, tunes policy, generates prompt hints.
  Integrates with Policy for A/B canary evaluation and Regressions for guardrails.
  """
  use GenServer

  require Logger

  alias Crucible.{BenchmarkAutopilot, HarborEvalIngestor, Policy, Regressions}
  alias Crucible.Telemetry.Spans

  @default_interval_ms 1_800_000
  @lookback_hours 24
  @benchmark_sweep_lookback_hours 168
  @benchmark_sweep_limit 250
  @knowledge_loop_dirs [
    {"lessons", :learn},
    {"observations", :learn},
    {"decisions", :create},
    {"handoffs", :share}
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Triggers self-improvement analysis for a completed run."
  @spec trigger(String.t()) :: :ok
  def trigger(run_id) do
    GenServer.cast(__MODULE__, {:trigger, run_id})
  end

  @doc "Returns the latest KPI snapshot."
  @spec latest_snapshot() :: map() | nil
  def latest_snapshot do
    GenServer.call(__MODULE__, :latest_snapshot)
  end

  @doc "Returns current prompt hints."
  @spec current_hints() :: map()
  def current_hints do
    GenServer.call(__MODULE__, :current_hints)
  end

  @doc "Returns the latest Knowledge Loop metrics."
  @spec knowledge_loop() :: map() | nil
  def knowledge_loop do
    GenServer.call(__MODULE__, :knowledge_loop)
  end

  @doc "Returns prompt hints filtered for a specific workflow and phase type."
  @spec read_prompt_hints_for_phase(String.t() | nil, atom()) :: [String.t()]
  def read_prompt_hints_for_phase(workflow_name, phase_type) do
    hints = current_hints()
    global = Map.get(hints, :global, [])

    workflow_hints = get_in(hints, [:workflows, workflow_name]) || %{}
    all_wf = Map.get(workflow_hints, :all, [])

    scoped =
      case phase_type do
        t when t in [:session, :preflight, :pr_shepherd] ->
          Map.get(workflow_hints, :session, [])

        t when t in [:team, :review_gate] ->
          Map.get(workflow_hints, :team, [])

        _ ->
          []
      end

    global ++ all_wf ++ scoped
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    infra_home = Keyword.get(opts, :infra_home, File.cwd!())

    schedule_periodic(interval)

    Logger.info("SelfImprovement started (interval=#{interval}ms)")

    {:ok,
     %{
       interval_ms: interval,
       infra_home: infra_home,
       latest_snapshot: nil,
       hints: %{global: [], workflows: %{}, evidence: %{}},
       policy_state: nil,
       knowledge_loop: nil
     }}
  end

  @impl true
  def handle_call(:latest_snapshot, _from, state) do
    {:reply, state.latest_snapshot, state}
  end

  def handle_call(:current_hints, _from, state) do
    {:reply, state.hints, state}
  end

  def handle_call(:knowledge_loop, _from, state) do
    {:reply, state.knowledge_loop, state}
  end

  @impl true
  def handle_cast({:trigger, run_id}, state) do
    try do
      Spans.with_span("self_improvement.trigger", %{"run.id" => run_id}, fn ->
        Logger.info("SelfImprovement: triggered for run #{run_id}")

        # Record session for dream-gate (advances the sessions gate)
        Crucible.DreamGate.record_session_start(state.infra_home)

        maybe_process_benchmark_run(run_id, state)
        Crucible.LearnTool.promote_learnings(run_id, infra_home: state.infra_home)

        # Run-triggered cycles run unconditionally (not gated by dream-gate).
        # The gate only applies to periodic background checks to prevent
        # over-dreaming when no new knowledge has accumulated.
        case run_improvement_cycle(state) do
          {:ok, new_state} ->
            {:noreply, new_state}

          {:error, reason} ->
            Logger.warning("SelfImprovement: cycle failed: #{inspect(reason)}")
            {:noreply, state}
        end
      end)
    rescue
      e ->
        Logger.error("SelfImprovement: trigger crashed for #{run_id}: #{Exception.message(e)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:periodic_check, state) do
    state =
      try do
        Spans.with_span("self_improvement.periodic_check", fn ->
          Logger.debug("SelfImprovement: periodic check")

          maybe_sweep_benchmark_runs(state)
          maybe_ingest_research_benchmarks()

          # Dream-gate: only run improvement cycle if all three gates are open
          case Crucible.DreamGate.is_gate_open(state.infra_home) do
            %{open: true, gates: gates} ->
              Logger.info("SelfImprovement: dream gate open #{inspect(gates)}")

              case Crucible.DreamGate.acquire_lock(state.infra_home) do
                :ok ->
                  result =
                    try do
                      run_improvement_cycle(state)
                    after
                      Crucible.DreamGate.release_lock(state.infra_home)
                    end

                  case result do
                    {:ok, new_state} ->
                      {tokens, cost} = estimate_cycle_cost(new_state)

                      Crucible.DreamGate.record_consolidation_complete(
                        state.infra_home,
                        tokens,
                        cost
                      )

                      new_state

                    {:error, _} ->
                      state
                  end

                {:error, :locked} ->
                  Logger.debug("SelfImprovement: dream gate locked, skipping cycle")
                  state
              end

            %{open: false} ->
              Logger.debug("SelfImprovement: dream gate closed, skipping cycle")
              state
          end
        end)
      rescue
        e ->
          Logger.error("SelfImprovement: periodic check crashed: #{Exception.message(e)}")
          state
      end

    schedule_periodic(state.interval_ms)
    {:noreply, state}
  end

  # --- Private: improvement cycle ---

  defp run_improvement_cycle(state) do
    with {:ok, summaries} <- read_recent_summaries(state.infra_home),
         snapshot <- build_kpi_snapshot(summaries),
         kloop <- compute_knowledge_loop(state.infra_home, @lookback_hours),
         snapshot <- Map.put(snapshot, :knowledge_loop, kloop),
         {policy_state, policy_action} <- run_policy_step(state, snapshot),
         hints <- build_prompt_hints(snapshot, summaries),
         hints <- add_knowledge_loop_hints(hints, kloop),
         hints <- enrich_hints_with_vault_lessons(hints, state.infra_home),
         new_regressions <- Regressions.detect_regressions(snapshot, state.infra_home),
         :ok <- save_new_regressions(state.infra_home, new_regressions),
         hints <- Regressions.inject_guardrails(hints, state.infra_home),
         :ok <- write_snapshot(state.infra_home, snapshot),
         :ok <- write_hints(state.infra_home, hints),
         :ok <- save_policy(state.infra_home, policy_state) do
      if policy_action do
        Logger.info("SelfImprovement: policy action: #{inspect(policy_action)}")
      end

      Phoenix.PubSub.broadcast(
        Crucible.PubSub,
        "orchestrator:kpi",
        {:kpi_updated, snapshot}
      )

      {:ok,
       %{
         state
         | latest_snapshot: snapshot,
           hints: hints,
           policy_state: policy_state,
           knowledge_loop: kloop
       }}
    end
  end

  defp run_policy_step(state, snapshot) do
    policy_state = state.policy_state || Policy.load_state(state.infra_home)
    Policy.decide_candidate_action(policy_state, snapshot)
  end

  defp maybe_process_benchmark_run(run_id, state) do
    {:ok, _} = BenchmarkAutopilot.process_completed_run(run_id, infra_home: state.infra_home)
    :ok
  rescue
    e ->
      Logger.debug(
        "SelfImprovement: benchmark autopilot failed #{run_id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp maybe_sweep_benchmark_runs(state) do
    {:ok, _} =
      BenchmarkAutopilot.sweep(
        infra_home: state.infra_home,
        lookback_hours: @benchmark_sweep_lookback_hours,
        limit: @benchmark_sweep_limit
      )

    :ok
  rescue
    e ->
      Logger.debug("SelfImprovement: benchmark sweep failed: #{Exception.message(e)}")
      :ok
  end

  defp maybe_ingest_research_benchmarks do
    {:ok, _} = HarborEvalIngestor.sweep(limit: 100)
    :ok
  rescue
    e ->
      Logger.debug("SelfImprovement: research benchmark ingest failed: #{Exception.message(e)}")
      :ok
  end

  defp save_policy(_infra_home, nil), do: :ok

  defp save_policy(infra_home, policy_state) do
    Policy.save_state(infra_home, policy_state)
  end

  defp save_new_regressions(_infra_home, []), do: :ok

  defp save_new_regressions(infra_home, new_rules) do
    existing = Regressions.load_rules(infra_home)
    existing_ids = MapSet.new(existing, & &1.id)

    to_add = Enum.reject(new_rules, fn r -> MapSet.member?(existing_ids, r.id) end)

    if length(to_add) > 0 do
      Regressions.save_rules(infra_home, existing ++ to_add)
    end

    :ok
  end

  # --- Private: trace reading ---

  defp read_recent_summaries(infra_home) do
    traces_dir = Path.join(infra_home, ".claude-flow/logs/traces")

    if File.dir?(traces_dir) do
      cutoff = DateTime.utc_now() |> DateTime.add(-@lookback_hours * 3600, :second)

      summaries =
        traces_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.flat_map(fn file ->
          Path.join(traces_dir, file)
          |> parse_trace_file(cutoff)
        end)

      {:ok, summaries}
    else
      {:ok, []}
    end
  end

  defp parse_trace_file(path, cutoff) do
    path
    |> File.stream!()
    |> Enum.reduce(%{}, fn line, runs ->
      case Jason.decode(line) do
        {:ok, %{"runId" => run_id, "timestamp" => ts} = event} ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _} when dt >= cutoff ->
              entry = Map.get(runs, run_id, new_run_summary(run_id))
              Map.put(runs, run_id, accumulate_event(entry, event))

            _ ->
              runs
          end

        _ ->
          runs
      end
    end)
    |> Map.values()
  rescue
    _ -> []
  end

  defp new_run_summary(run_id) do
    %{
      run_id: run_id,
      workflow: nil,
      variant: :unknown,
      status: :unknown,
      phases: [],
      phase_outcomes: [],
      fail_cause: nil,
      total_cost: 0.0,
      total_turns: 0,
      retry_count: 0,
      force_completed: false,
      pickup_waits: [],
      agent_events: [],
      started_at: nil,
      completed_at: nil,
      introspection_signals: []
    }
  end

  # --- Private: event accumulation ---

  defp accumulate_event(summary, %{"eventType" => "run_started"} = e) do
    %{
      summary
      | workflow: Map.get(e, "workflowName", summary.workflow),
        started_at: Map.get(e, "timestamp", summary.started_at)
    }
  end

  defp accumulate_event(summary, %{"eventType" => "run_completed"} = e) do
    %{summary | status: :completed, completed_at: Map.get(e, "timestamp")}
  end

  defp accumulate_event(summary, %{"eventType" => "run_failed"} = e) do
    %{
      summary
      | status: :failed,
        fail_cause: get_in(e, ["metadata", "cause"]),
        completed_at: Map.get(e, "timestamp")
    }
  end

  defp accumulate_event(summary, %{"eventType" => "run_policy_applied"} = e) do
    variant =
      case get_in(e, ["metadata", "variant"]) do
        "candidate" -> :candidate
        _ -> :active
      end

    %{summary | variant: variant}
  end

  defp accumulate_event(summary, %{"eventType" => "pickup_trigger_claimed"} = e) do
    wait_ms = get_in(e, ["metadata", "waitMs"]) || 0
    %{summary | pickup_waits: [wait_ms | summary.pickup_waits]}
  end

  defp accumulate_event(summary, %{"eventType" => "phase_completed"} = e) do
    phase = %{
      phase_id: Map.get(e, "phaseId"),
      status: :completed,
      duration_ms: get_in(e, ["metadata", "durationMs"]),
      cost: get_in(e, ["metadata", "cost"])
    }

    cost = phase.cost || 0.0

    %{summary | phases: [phase | summary.phases], total_cost: summary.total_cost + cost}
  end

  defp accumulate_event(summary, %{"eventType" => "phase_timeout"} = e) do
    phase = %{
      phase_id: Map.get(e, "phaseId"),
      status: :timeout,
      duration_ms: get_in(e, ["metadata", "durationMs"])
    }

    %{summary | phases: [phase | summary.phases]}
  end

  defp accumulate_event(summary, %{"eventType" => "phase_end"} = e) do
    outcome = %{
      phase_type: get_in(e, ["metadata", "phaseType"]) || "unknown",
      duration_ms: get_in(e, ["metadata", "durationMs"]),
      status: parse_phase_status(get_in(e, ["metadata", "status"])),
      cost: get_in(e, ["metadata", "cost"])
    }

    %{summary | phase_outcomes: [outcome | summary.phase_outcomes]}
  end

  defp accumulate_event(summary, %{"eventType" => type} = e)
       when type in ["agent_tool_call", "agent_edit"] do
    %{summary | agent_events: [e | summary.agent_events]}
  end

  defp accumulate_event(summary, %{"eventType" => "force_completed"} = e) do
    signal = %{
      type: "force_completed",
      phase_id: Map.get(e, "phaseId"),
      detail: Map.get(e, "detail")
    }

    %{
      summary
      | introspection_signals: [signal | summary.introspection_signals],
        force_completed: true
    }
  end

  defp accumulate_event(summary, %{"eventType" => type} = e)
       when type in ["loop_detected", "review_gate_block"] do
    signal = %{type: type, phase_id: Map.get(e, "phaseId"), detail: Map.get(e, "detail")}
    %{summary | introspection_signals: [signal | summary.introspection_signals]}
  end

  defp accumulate_event(summary, _event), do: summary

  # --- Private: phase status parsing ---

  defp parse_phase_status("completed"), do: :completed
  defp parse_phase_status("timeout"), do: :timeout
  defp parse_phase_status("failed"), do: :failed
  defp parse_phase_status("blocked"), do: :blocked
  defp parse_phase_status(_), do: :unknown

  # --- Private: KPI snapshot ---

  defp build_kpi_snapshot(summaries) do
    totals = summarize_variant(summaries)

    # Split by variant
    {active_runs, candidate_runs} = Enum.split_with(summaries, &(&1.variant != :candidate))

    by_variant = %{
      active: summarize_variant(active_runs),
      candidate: summarize_variant(candidate_runs)
    }

    # By phase type
    by_phase_type = build_phase_type_metrics(summaries)

    # By workflow (expanded)
    by_workflow =
      summaries
      |> Enum.group_by(& &1.workflow)
      |> Enum.map(fn {wf, runs} -> {wf, summarize_variant(runs)} end)
      |> Map.new()

    retry_causes =
      summaries
      |> Enum.filter(&(&1.fail_cause != nil))
      |> Enum.frequencies_by(& &1.fail_cause)
      |> Enum.sort_by(fn {_, count} -> -count end)

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      window_hours: @lookback_hours,
      totals: totals,
      by_variant: by_variant,
      by_phase_type: by_phase_type,
      by_workflow: by_workflow,
      retry_causes: retry_causes
    }
  end

  defp summarize_variant(summaries) do
    runs = length(summaries)
    done = Enum.count(summaries, &(&1.status == :completed))
    failed = Enum.count(summaries, &(&1.status == :failed))
    orphaned = runs - done - failed

    timeout_runs =
      Enum.count(summaries, fn s -> Enum.any?(s.phases, &(&1.status == :timeout)) end)

    force_completed_runs = Enum.count(summaries, & &1.force_completed)

    total_cost = summaries |> Enum.map(& &1.total_cost) |> Enum.sum() |> to_float()

    fail_rate = safe_rate(failed, runs)
    timeout_rate = safe_rate(timeout_runs, runs)
    force_completed_rate = safe_rate(force_completed_runs, runs)

    pickup_waits = summaries |> Enum.flat_map(& &1.pickup_waits)

    avg_retries =
      if runs > 0, do: to_float(Enum.sum(Enum.map(summaries, & &1.retry_count))) / runs, else: 0.0

    agent_metrics = extract_all_agent_metrics(summaries)

    %{
      runs: runs,
      done: done,
      failed: failed,
      orphaned: orphaned,
      timeout_runs: timeout_runs,
      force_completed_runs: force_completed_runs,
      fail_rate: Float.round(fail_rate, 4),
      timeout_rate: Float.round(timeout_rate, 4),
      force_completed_rate: Float.round(force_completed_rate, 4),
      pickup_p95_ms: percentile(pickup_waits, 95),
      avg_retries: Float.round(avg_retries, 2),
      total_cost: Float.round(total_cost, 2),
      avg_tool_calls_before_first_edit:
        avg_agent_metric(agent_metrics, :tool_calls_before_first_edit),
      avg_spawn_to_first_edit_ms: avg_agent_metric(agent_metrics, :spawn_to_first_edit_ms),
      drift_rate: avg_agent_metric(agent_metrics, :drift_rate)
    }
  end

  defp build_phase_type_metrics(summaries) do
    all_outcomes = Enum.flat_map(summaries, & &1.phase_outcomes)

    all_outcomes
    |> Enum.group_by(& &1.phase_type)
    |> Enum.map(fn {phase_type, outcomes} ->
      count = length(outcomes)
      completed = Enum.count(outcomes, &(&1.status == :completed))
      timed_out = Enum.count(outcomes, &(&1.status == :timeout))
      failed = Enum.count(outcomes, &(&1.status == :failed))

      durations = outcomes |> Enum.map(& &1.duration_ms) |> Enum.reject(&is_nil/1)

      avg_dur =
        if length(durations) > 0,
          do: Float.round(Enum.sum(durations) / length(durations), 0),
          else: nil

      p95_dur = percentile(durations, 95)

      block_rate =
        if phase_type == "review_gate" do
          blocks = Enum.count(outcomes, &(&1.status == :blocked))
          safe_rate(blocks, count)
        else
          nil
        end

      {phase_type,
       %{
         count: count,
         completed: completed,
         timed_out: timed_out,
         failed: failed,
         avg_duration_ms: avg_dur,
         p95_duration_ms: p95_dur,
         block_rate: block_rate
       }}
    end)
    |> Map.new()
  end

  # --- Private: statistical helpers ---

  defp percentile([], _n), do: nil

  defp percentile(values, n) do
    sorted = Enum.sort(values)
    k = max(0, ceil(length(sorted) * n / 100) - 1)
    Enum.at(sorted, k)
  end

  defp safe_rate(_num, 0), do: 0.0
  defp safe_rate(num, denom), do: to_float(num) / denom

  # --- Private: agent metrics ---

  defp extract_all_agent_metrics(summaries) do
    summaries
    |> Enum.flat_map(fn s ->
      s.agent_events
      |> Enum.group_by(&Map.get(&1, "agentId", "unknown"))
      |> Enum.map(fn {_agent_id, events} ->
        sorted = Enum.sort_by(events, &Map.get(&1, "timestamp", ""))
        first_edit_idx = Enum.find_index(sorted, &(Map.get(&1, "eventType") == "agent_edit"))
        tool_calls_before = if first_edit_idx, do: first_edit_idx, else: length(sorted)

        first_ts = get_in(List.first(sorted) || %{}, ["timestamp"])

        edit_ts =
          if first_edit_idx, do: get_in(Enum.at(sorted, first_edit_idx), ["timestamp"]), else: nil

        spawn_to_edit =
          if first_ts && edit_ts, do: timestamp_diff_ms(first_ts, edit_ts), else: nil

        files_edited =
          sorted
          |> Enum.filter(&(Map.get(&1, "eventType") == "agent_edit"))
          |> Enum.map(&get_in(&1, ["metadata", "file"]))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        assigned =
          sorted
          |> Enum.find_value(fn e -> get_in(e, ["metadata", "assignedFiles"]) end) ||
            []

        drift =
          if length(files_edited) > 0 && length(assigned) > 0 do
            outside = files_edited -- assigned
            length(outside) / length(files_edited)
          else
            0.0
          end

        %{
          tool_calls_before_first_edit: tool_calls_before,
          spawn_to_first_edit_ms: spawn_to_edit,
          drift_rate: drift
        }
      end)
    end)
  end

  defp avg_agent_metric([], _key), do: nil

  defp avg_agent_metric(metrics, key) do
    values = metrics |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1)
    if length(values) > 0, do: Float.round(Enum.sum(values) / length(values), 2), else: nil
  end

  defp timestamp_diff_ms(ts1, ts2) do
    with {:ok, dt1, _} <- DateTime.from_iso8601(ts1),
         {:ok, dt2, _} <- DateTime.from_iso8601(ts2) do
      DateTime.diff(dt2, dt1, :millisecond)
    else
      _ -> nil
    end
  end

  # --- Private: prompt hints ---

  defp build_prompt_hints(snapshot, summaries) do
    totals = snapshot.totals
    global = []

    # Pickup latency
    global =
      if totals[:pickup_p95_ms] && totals.pickup_p95_ms > 5000,
        do: [
          "Emit completion artifacts (sentinel files, status updates) as early as possible — pickup P95 is #{totals.pickup_p95_ms}ms"
          | global
        ],
        else: global

    # Timeout rate
    global =
      if totals.timeout_rate > 0.10,
        do: [
          "Break long phases into smaller checkpoints to avoid timeouts — timeout rate is #{Float.round(totals.timeout_rate * 100, 1)}%"
          | global
        ],
        else: global

    # Fail rate
    global =
      if totals.fail_rate > 0.08,
        do: [
          "Prefer reversible, incremental changes — fail rate is #{Float.round(totals.fail_rate * 100, 1)}%"
          | global
        ],
        else: global

    # Force completions
    global =
      if totals[:force_completed_rate] && totals.force_completed_rate > 0.10,
        do: [
          "Add explicit completion blocks with SendMessage — force-completion rate is #{Float.round(totals.force_completed_rate * 100, 1)}%"
          | global
        ],
        else: global

    # Agent metrics: tool call overhead
    global =
      if totals[:avg_tool_calls_before_first_edit] && totals.avg_tool_calls_before_first_edit > 8,
        do: [
          "Start editing sooner — agents average #{round(totals.avg_tool_calls_before_first_edit)} tool calls before first edit"
          | global
        ],
        else: global

    # Agent metrics: drift
    global =
      if totals[:drift_rate] && totals.drift_rate > 0.2,
        do: [
          "Respect file assignments — #{Float.round(totals.drift_rate * 100, 0)}% of edits are outside assigned files"
          | global
        ],
        else: global

    # Cost per run (approximate from total)
    avg_cost = if totals.runs > 0, do: totals.total_cost / totals.runs, else: 0.0

    global =
      if avg_cost > 5.0,
        do: [
          "Consider using cheaper models for simple phases — average cost is $#{Float.round(avg_cost, 2)}/run"
          | global
        ],
        else: global

    # Review gate blocks
    block_count =
      summaries
      |> Enum.flat_map(& &1.introspection_signals)
      |> Enum.count(&(&1.type == "review_gate_block"))

    global =
      if block_count > 0,
        do: [
          "#{block_count} review gate blocks — ensure tests pass and code compiles before submitting for review"
          | global
        ],
        else: global

    # Per-workflow hints
    workflows = build_workflow_hints(snapshot)

    # Evidence
    evidence = %{
      pickup_p95_ms: totals[:pickup_p95_ms],
      timeout_rate: totals.timeout_rate,
      fail_rate: totals.fail_rate,
      force_completed_rate: totals[:force_completed_rate] || 0.0,
      avg_cost_per_run: Float.round(avg_cost, 2),
      avg_tool_calls_before_first_edit: totals[:avg_tool_calls_before_first_edit],
      drift_rate: totals[:drift_rate],
      snapshot_at: snapshot.generated_at,
      window_hours: snapshot.window_hours
    }

    %{global: global, workflows: workflows, evidence: evidence}
  end

  defp build_workflow_hints(snapshot) do
    (snapshot.by_workflow || %{})
    |> Enum.map(fn {wf_name, wf_kpi} ->
      hints = []

      hints =
        if wf_kpi.fail_rate > 0.15,
          do: [
            "High fail rate (#{Float.round(wf_kpi.fail_rate * 100, 1)}%) — add more verification steps"
            | hints
          ],
          else: hints

      hints =
        if wf_kpi.timeout_rate > 0.15,
          do: [
            "High timeout rate (#{Float.round(wf_kpi.timeout_rate * 100, 1)}%) — consider splitting phases"
            | hints
          ],
          else: hints

      {wf_name, %{all: hints, session: [], team: [], api: []}}
    end)
    |> Map.new()
  end

  defp enrich_hints_with_vault_lessons(hints, infra_home) do
    lessons_dir = Path.join(infra_home, "memory/lessons")

    if File.dir?(lessons_dir) do
      cutoff = DateTime.utc_now() |> DateTime.add(-7 * 86400, :second)

      lessons =
        lessons_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(fn file ->
          path = Path.join(lessons_dir, file)

          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} when mtime > 0 ->
              mtime_dt = DateTime.from_unix!(mtime)

              if DateTime.compare(mtime_dt, cutoff) == :gt do
                content = File.read!(path)

                if String.contains?(content, "auto-captured") do
                  title = file |> String.trim_trailing(".md") |> String.replace("-", " ")

                  priority =
                    cond do
                      String.contains?(content, "critical") -> 0
                      String.contains?(content, "notable") -> 1
                      true -> 2
                    end

                  [{priority, title}]
                else
                  []
                end
              else
                []
              end

            _ ->
              []
          end
        end)
        |> Enum.sort_by(fn {pri, _} -> pri end)
        |> Enum.take(5)
        |> Enum.map(fn {_, title} -> "[vault] #{title}" end)

      existing = MapSet.new(hints.global, &String.downcase/1)
      new_lessons = Enum.reject(lessons, fn h -> MapSet.member?(existing, String.downcase(h)) end)

      %{hints | global: hints.global ++ new_lessons}
    else
      hints
    end
  rescue
    _ -> hints
  end

  # --- Private: Knowledge Loop ---

  @doc false
  def compute_knowledge_loop(infra_home, lookback_hours) do
    cutoff = DateTime.utc_now() |> DateTime.add(-lookback_hours * 3600, :second)
    vault_path = Path.join(infra_home, "memory")

    counts =
      @knowledge_loop_dirs
      |> Enum.reduce(%{learn: 0, create: 0, share: 0}, fn {dir, type}, acc ->
        dir_path = Path.join(vault_path, dir)

        count =
          if File.dir?(dir_path) do
            dir_path
            |> File.ls!()
            |> Enum.count(fn file ->
              String.ends_with?(file, ".md") &&
                case File.stat(Path.join(dir_path, file), time: :posix) do
                  {:ok, %{mtime: mtime}} ->
                    DateTime.compare(DateTime.from_unix!(mtime), cutoff) == :gt

                  _ ->
                    false
                end
            end)
          else
            0
          end

        Map.update!(acc, type, &(&1 + count))
      end)

    stalled =
      [:learn, :create, :share]
      |> Enum.filter(fn stage -> Map.get(counts, stage, 0) == 0 end)

    completeness = (3 - length(stalled)) / 3

    # Wikilink density: measure knowledge interconnection
    {total_notes, total_wikilinks} = count_wikilink_density(vault_path)

    wikilink_density =
      if total_notes > 0,
        do: Float.round(total_wikilinks / total_notes, 2),
        else: 0.0

    %{
      learn_count: counts.learn,
      create_count: counts.create,
      share_count: counts.share,
      stalled_stages: stalled,
      loop_completeness: Float.round(completeness, 2),
      total_notes: total_notes,
      total_wikilinks: total_wikilinks,
      wikilink_density: wikilink_density
    }
  rescue
    _ ->
      %{
        learn_count: 0,
        create_count: 0,
        share_count: 0,
        stalled_stages: [:learn, :create, :share],
        loop_completeness: 0.0,
        total_notes: 0,
        total_wikilinks: 0,
        wikilink_density: 0.0
      }
  end

  defp count_wikilink_density(vault_path) do
    if File.dir?(vault_path) do
      vault_path
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.reduce({0, 0}, fn file, {notes, links} ->
        case File.read(file) do
          {:ok, content} ->
            wikilinks = Regex.scan(~r/\[\[([^\]]+)\]\]/, content) |> length()
            {notes + 1, links + wikilinks}

          _ ->
            {notes, links}
        end
      end)
    else
      {0, 0}
    end
  rescue
    _ -> {0, 0}
  end

  defp add_knowledge_loop_hints(hints, kloop) do
    global = hints.global

    global =
      if :learn in kloop.stalled_stages && kloop.create_count > 0 do
        [
          "Knowledge loop stalled: decisions are being made but no lessons captured. Store lessons after corrections."
          | global
        ]
      else
        global
      end

    global =
      if :create in kloop.stalled_stages && kloop.learn_count > 0 do
        [
          "Knowledge loop stalled: lessons stored but no decisions reference them. Store decision notes linking to relevant lessons."
          | global
        ]
      else
        global
      end

    global =
      if :share in kloop.stalled_stages && (kloop.learn_count > 0 || kloop.create_count > 0) do
        [
          "Knowledge loop stalled: knowledge captured but not shared. Write structured handoff notes at session end."
          | global
        ]
      else
        global
      end

    global =
      if kloop.loop_completeness == 0.0 do
        [
          "Knowledge loop inactive: no lessons, decisions, or handoffs in the lookback window."
          | global
        ]
      else
        global
      end

    evidence =
      Map.merge(hints[:evidence] || %{}, %{
        knowledge_loop_completeness: kloop.loop_completeness,
        knowledge_loop_stalled: kloop.stalled_stages
      })

    %{hints | global: global, evidence: evidence}
  end

  # --- Private: persistence ---

  defp write_snapshot(infra_home, snapshot) do
    dir = Path.join(infra_home, ".claude-flow/learning")
    File.mkdir_p!(dir)

    # Write latest
    path = Path.join(dir, "workflow-kpi.json")

    case Jason.encode(snapshot, pretty: true) do
      {:ok, json} -> File.write(path, json)
      {:error, reason} -> {:error, reason}
    end

    # Append to history
    history_path = Path.join(dir, "workflow-kpi-history.jsonl")

    case Jason.encode(snapshot) do
      {:ok, line} -> File.write(history_path, line <> "\n", [:append])
      _ -> :ok
    end

    :ok
  end

  defp write_hints(infra_home, hints) do
    dir = Path.join(infra_home, ".claude-flow/learning")
    File.mkdir_p!(dir)
    path = Path.join(dir, "workflow-prompt-hints.json")

    case Jason.encode(hints, pretty: true) do
      {:ok, json} -> File.write(path, json)
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_periodic(interval) do
    Process.send_after(self(), :periodic_check, interval)
  end

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0

  defp estimate_cycle_cost(state) do
    case state.latest_snapshot do
      %{cost_summary: %{total_usd: cost}} when is_number(cost) ->
        # Rough estimate: 1 USD ≈ 100k tokens at Haiku tier
        tokens = round(cost * 100_000)
        {tokens, cost}

      _ ->
        {0, 0.0}
    end
  end
end
