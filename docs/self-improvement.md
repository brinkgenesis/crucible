# Self-improvement guide

Crucible runs a continuous loop that reads the output of its own runs and tunes its behaviour. This document covers what that loop actually does, what it learns, where it stores its state, and how to intervene when it makes a bad call.

## What the loop does

Every 30 minutes (and also immediately after any completed run), `Crucible.SelfImprovement` does the following:

1. **Reads traces** from the last 24 hours (`traces/*.jsonl`).
2. **Builds a KPI snapshot** — per-workflow pass rate, cost, timing percentiles, retry counts, tool-call diversity, circuit-breaker trips, loop-detector interventions.
3. **Runs `Policy.decide_candidate_action/2`** — an A/B canary framework that can propose a policy change (e.g. "switch `design-review` to Haiku for throughput profile") and evaluate it against the control.
4. **Generates prompt hints** — short bullet strings injected into future phase prompts. Global hints apply everywhere; workflow-scoped and phase-scoped hints apply selectively.
5. **Detects regressions** via `Crucible.Regressions.detect_regressions/2`. A regression is a statistically significant dip on a KPI vs. a rolling baseline.
6. **Injects guardrails** — when a regression is detected, safety-oriented hints are added to prompts for the affected phase type.
7. **Writes the snapshot** to `.crucible/kpi/` and broadcasts it over PubSub for the dashboard.
8. **Tracks Knowledge Loop progress** — lesson promotions, decisions logged, handoffs produced.

The flow is best thought of as a low-frequency control loop: traces in, prompt hints + policy state out.

## What it actually learns

- **Which model is right for a phase type.** If `design-review` runs with Sonnet produce the same outcomes as runs with Opus at a third of the cost, the policy proposes Sonnet as the new default.
- **Which hints help.** A hint is retained only if KPIs stay stable or improve after it's added. Hints that coincide with regressions get rolled back.
- **When to preempt.** If a workflow consistently times out at phase 3, the loop can emit a hint like *"phase 3 historically blows the 10-min budget on repos larger than 100k LOC — plan accordingly"*. That hint then shows up in future phase-3 prompts.
- **What rooms for routing.** Cost vs. quality tradeoffs at the router layer are re-derived from observed rather than declared model capabilities.

It does **not** learn:

- Which git workflow to use (you pick the workflow YAML).
- Which workspace a card belongs to.
- Anything about your code (it's a meta-system, not a code-understanding system).
- Task-specific context across runs — each run is its own scope.

## Where state lives

| Path | What | Format |
|---|---|---|
| `.crucible/kpi/latest.json` | Most recent KPI snapshot | JSON |
| `.crucible/kpi/history/` | Rolling history of snapshots | JSON per-snapshot |
| `.crucible/policy/state.json` | Current policy (model/prompt defaults) + candidate A/B state | JSON |
| `.crucible/policy/regressions.json` | Active regression rules + their guardrails | JSON |
| `.crucible/policy/hints.json` | Current prompt hints, global + scoped | JSON |
| `traces/<run_id>.jsonl` | Raw trace events, input to the loop | JSONL |

All of these are plain text. You can (and should) grep and inspect them.

## Observing the loop

**Dashboard pages:**

- **Cost** — per-day spend, per-model mix. Good for spotting policy drift.
- **Runs** — per-run pass/fail, dwell time, token counts.
- **Policies** (if enabled) — active policy state, candidate actions in flight.

**IEx introspection:**

```elixir
# Latest KPI snapshot
Crucible.SelfImprovement.latest_snapshot()

# Current hints, all scopes
Crucible.SelfImprovement.current_hints()

# What hints will a given workflow + phase type see?
Crucible.SelfImprovement.read_prompt_hints_for_phase("coding-sprint", :team)

# Knowledge Loop counters
Crucible.SelfImprovement.knowledge_loop()

# Policy state
Crucible.Policy.load_state(File.cwd!())

# Active regression rules
Crucible.Regressions.load_rules(File.cwd!())
```

**Forcing a refresh:**

```elixir
# Analyse a specific run immediately (normally batched into the next tick)
Crucible.SelfImprovement.trigger("<run_id>")
```

## Intervening when it's wrong

The loop is deliberately conservative — most changes are A/B tested before promotion, and every change is reversible. That said, sometimes you'll want to override it.

**Pause the loop:**

```elixir
# In IEx — stop the GenServer
Supervisor.terminate_child(Crucible.Supervisor, Crucible.SelfImprovement)

# Restart when ready
Supervisor.restart_child(Crucible.Supervisor, Crucible.SelfImprovement)
```

**Wipe policy state** (useful after a bad policy change has stuck):

```bash
rm .crucible/policy/state.json
# On next tick, the loop rebuilds from defaults.
```

**Remove a specific prompt hint:**

Edit `.crucible/policy/hints.json` directly — it's a JSON map keyed by scope. Delete the offending entry. The loop will re-derive on the next tick; if conditions that produced the bad hint still hold, it may come back. In that case either (a) fix the KPI signal the hint is responding to, or (b) add it to the Regressions guardrail list so the loop knows not to generate it.

**Disable regression guardrails:**

```bash
echo '{"rules": []}' > .crucible/policy/regressions.json
```

Use sparingly — guardrails exist because a specific behaviour caused a measurable regression. Disabling them trades safety for exploration.

## Tuning the loop itself

Relevant env vars / config:

| Setting | Default | What it does |
|---|---|---|
| `SelfImprovement` `interval_ms` | `1_800_000` (30 min) | How often the loop runs on its timer |
| `@lookback_hours` | 24 | Trace window the loop considers on each tick |
| `@benchmark_sweep_lookback_hours` | 168 | How far back the benchmark autopilot looks |
| `SELF_IMPROVE_ENABLED` env var | `true` | Hard kill switch — set `false` to disable entirely |

Longer lookback = smoother signal but slower response. Shorter lookback = faster response but noisier decisions. 24h is a reasonable default for most setups; if your repo fires >100 runs/day, try 6h.

## Anti-patterns

- **Don't read the latest snapshot in a hot path.** The dashboard uses PubSub; backend code should use `latest_snapshot/0` sparingly — it's a GenServer call and serializes.
- **Don't bypass the loop for one-off "fixes".** Ad-hoc policy edits that contradict the loop's model will get reverted within an hour. If you truly need a permanent override, add a Regressions rule — that's the abstraction for "this is globally bad, never do it".
- **Don't treat KPI snapshots as historical truth.** They're derived from traces and will change if traces are deleted or corrupted. For audits, read the trace files directly.

## Further reading

- [ARCHITECTURE.md § Layer 12 — Self-Improvement](../ARCHITECTURE.md#layer-12--self-improvement) — the supervision tree placement and message flow.
- `lib/crucible/self_improvement.ex` — the full implementation is ~750 lines and readable end-to-end.
- `lib/crucible/policy.ex` / `lib/crucible/regressions.ex` — policy and regression logic.
- `lib/crucible/prompt_builder.ex` — where hints are actually injected into prompts.
