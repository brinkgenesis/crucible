# Crucible Architecture

A walkthrough of the 12 layers that make up Crucible. Each layer solves one failure mode; the code for each layer lives in a focused set of modules so you can trace "who owns this concern" to a small area of the tree.

## System diagram

```
Browser (kanban, traces, cost dashboards)
    │
    │  LiveView WebSocket
    ▼
┌──────────────────────────────────────────────────────────────┐
│ CrucibleWeb (Phoenix + LiveView)                              │
│ ─ Kanban board, run/trace browser, cost + router UIs,        │
│   control panel, policies, workspaces, settings              │
└──────────────────────────────────────────────────────────────┘
    │
    │  GenServer call / cast
    ▼
┌──────────────────────────────────────────────────────────────┐
│ Crucible core (Elixir OTP)                                    │
│                                                              │
│   Orchestrator  ─── polls pending runs, gates on budget /    │
│                     concurrency, dispatches to RunServer     │
│                                                              │
│   RunSupervisor ─── DynamicSupervisor; one RunServer per run │
│                                                              │
│   RunServer     ─── owns per-run retry / circuit state       │
│                                                              │
│   PhaseRunner   ─── executes each phase; writes sentinels    │
│                                                              │
│   AgentRunner   ─── creates git worktree / branch per run    │
└──────────────────────────────────────────────────────────────┘
    │
    │  Erlang Port (JSON over stdin/stdout)
    ▼
┌──────────────────────────────────────────────────────────────┐
│ Bridge (Node subprocess)                                     │
│ ─ Wraps @anthropic-ai/claude-agent-sdk                       │
│ ─ Emits tool_use / status / result events as JSON lines      │
└──────────────────────────────────────────────────────────────┘
    │
    ▼
Claude / OpenAI / Ollama / … (via the pluggable router)
    │
    ▼
Git worktree ─── `git push` ─── GitHub PR
```

## The 12 layers

Each layer has **one concern** and **one place to go looking** when it misbehaves.

### Layer 1 — Query Loop

**Concern:** Drive agent sessions from "a run is pending" to "all phases complete."

**Owns:** `Crucible.Orchestrator` (the dispatch loop), `Crucible.Orchestrator.RunServer` (per-run GenServer), the inner async loop that pulls events from the bridge.

**Failure mode addressed:** Runs getting stuck waiting on I/O or blocking each other. RunServer is isolated per run, so one stuck run can't stop others from dispatching.

### Layer 2 — Tool Dispatch

**Concern:** Execute tool calls (Read, Edit, Bash, …) on the agent's behalf.

**Owns:** The bridge's PostToolUse / PreToolUse hooks, the sandbox manager (`Crucible.Sandbox.Manager`), workspace permission resolution (`workspace-permissions.ts`).

**Failure mode addressed:** Agents running unsafe commands in the wrong directory. Docker-backed sandboxing and per-workspace permission profiles cap the blast radius.

### Layer 3 — Retries

**Concern:** Recover from transient API failures without cascading into failed runs.

**Owns:** `Crucible.ExternalCircuitBreaker` (per-provider circuit state), `Crucible.Orchestrator.CircuitBreaker` (state machine), retry logic inside `claude_sdk.ex` and the bridge's `api_retry` event handling.

**Failure mode addressed:** A single flaky call killing a whole run. Three-level retry: SDK (5×) → resilience wrapper (3×) → turn-level. Circuit breakers short-circuit when an upstream provider is clearly down.

### Layer 4 — Context Compression

**Concern:** Stay within the model's token budget without truncating important context.

**Owns:** The Anthropic API's `context_management` beta, prompt caching via `cache_control`, the `snipCompact` helper for tool output compaction.

**Failure mode addressed:** Long-running sessions hitting context limits and dropping relevant history.

### Layer 5 — Knowledge Injection

**Concern:** Feed the right context to the model at the right moment.

**Owns:** The prompt builder (`Crucible.PromptBuilder`), system prompt sections assembled from plan notes and workspace metadata, synthetic `tool_result` messages injected from workflow-level hints, handoff notes between phases.

**Failure mode addressed:** Agents lacking information they need (plan, prior decisions, tech context) versus being flooded with irrelevant vault notes.

### Layer 6 — Token Budgeting

**Concern:** Assemble the system prompt to fit within a target token budget when multiple sections are competing.

**Owns:** The `PromptSection` priority system, per-iteration cost tracking in `Crucible.BudgetTracker`.

**Failure mode addressed:** System prompts ballooning past the window and trimming critical instructions.

### Layer 7 — Safety & Permissions

**Concern:** Prevent harmful actions (rm -rf /, leaking secrets, prompt injection).

**Owns:** `Crucible.Safety` (output threat detection — system-prompt leaks, mode-switch acknowledgements), bash AST parsing in the bridge, workspace permission tiers, prompt-injection detection on tool inputs.

**Failure mode addressed:** Jailbreaks, data exfiltration, destructive shell commands. Output scanning flags successful injections; input scanning flags attempted ones.

### Layer 8 — Sandbox

**Concern:** Isolate execution so a run's mistakes don't touch shared infrastructure.

**Owns:** `Crucible.Sandbox.Manager` (pre-warmed Docker container pool), `Crucible.Sandbox.Policy` (strict / standard / permissive presets), workspace-scoped git worktrees.

**Failure mode addressed:** One run's git operations clobbering another's; agent writes escaping the intended workspace.

### Layer 9 — Loop Detection

**Concern:** Stop agents that are stuck in a loop (editing the same file repeatedly, calling the same tool with the same args, waiting on an event that'll never come).

**Owns:** `Crucible.LoopDetector`, `Crucible.StuckTaskDetector`, `Crucible.LoopManager`.

**Failure mode addressed:** Agents burning budget without making progress. Four loop types are detected (edit, semantic, coordination, command) with escalating interventions: warn → course-correct → interrupt → terminate.

### Layer 10 — Multi-Agent Coordination

**Concern:** Let multiple agents collaborate on one run (team lead + coders + reviewer) without stepping on each other.

**Owns:** `Crucible.AgentRunner` (spawns branch per run), `Crucible.Orchestrator.RoleAssignment` (who writes which files), team poll loops inside the bridge's agent definitions.

**Failure mode addressed:** Coders overwriting each other's work, teammates silently dropping tasks, reviewer gating bypassed.

### Layer 11 — Memory / Consolidation

**Concern:** Carry the right knowledge forward between runs — lessons, decisions, preferences — without accumulating noise.

**Owns:** `Crucible.Orchestrator.PhasePersistence` (sentinel files and handoff notes), and in Phase 3, the Obsidian-backed vault with the 6Rs pipeline (reduce / reflect / reweave / tensions / review / reweave). The **three-gate dream trigger** decides when to consolidate: quiet-hour gate, change-volume gate, or explicit request.

**Failure mode addressed:** Memory bloat, stale lessons outvoting current policy, repeated mistakes.

### Layer 12 — Self-Improvement

**Concern:** Learn from each run's outcomes and tune the system automatically — regressions get caught early and wins get reinforced.

**Owns:** `Crucible.SelfImprovement` (periodic KPI snapshots from `trace_events`), policy tuning (`Crucible.Policy`), prompt-hint injection into the next run's phase prompts, regression detection (rising fail rate, timeout spikes, cost overruns).

**Failure mode addressed:** Silent degradation. If a prompt change starts producing worse runs, the loop notices and surfaces it.

## Data flow for a single run

1. **Card created** — user drops a task on the kanban board (`CrucibleWeb.KanbanLive`). The card gets a plan (either pre-supplied or generated by the LLM on first move-to-todo).

2. **Move to `todo`** — `KanbanController.move/2` detects the transition and calls `Orchestrator.submit_run(manifest)`.

3. **Orchestrator dispatch** — the run manifest is persisted to `workflow_runs`, then the Orchestrator's poll loop picks it up (respecting `max_concurrent_runs` and budget limits) and hands it to the `RunSupervisor`.

4. **RunServer spawns** — one GenServer per run, isolated in its own supervision subtree. It manages retries, budget, and phase transitions.

5. **AgentRunner creates a worktree** — `git worktree add` on a fresh `run/<run_id>` branch. The agent will only see that directory.

6. **PhaseRunner executes each phase** — sprint (team of agents), review-gate, pr-shepherd. Each phase writes a `.done` sentinel when complete, so re-dispatches are idempotent.

7. **Bridge streams events** — the SDK bridge emits `tool_use`, `subagent_event`, `status`, `result` as JSON lines. The Elixir `SdkPort` forwards them to:
   - `trace_events` table (durable observability)
   - `.crucible/logs/traces/<run_id>.jsonl` (cold storage)
   - Phoenix PubSub (live dashboards)

8. **PR created** — after the sprint phase finishes, `AgentRunner` pushes the branch and opens a PR via the GitHub API.

9. **PR shepherd** — a final phase watches CI, auto-fixes review comments, and merges when green.

10. **Self-improvement fires** — a Dream gate evaluates whether enough has changed to tune prompts/policies. If yes, KPIs are computed from the run's trace events and hints are written for future phases.

## Concurrency model

- **Per-run isolation via `DynamicSupervisor`** — `one_for_one` strategy, one crashed run does not affect others.
- **Registry-based lookup** — `RunRegistry` maps `run_id → pid` for O(1) cancellation / inspection.
- **Git worktree per run** — no shared workspace state; each run gets its own filesystem slice.
- **Circuit breakers per provider, not per run** — a flaky Anthropic endpoint trips once and all runs avoid it until it recovers.
- **Budget tracking is process-local** — each `BudgetTracker` ETS table is the single source of truth for live spend; persisted to Postgres periodically.

## What lives where

| Concern | Module path |
|---------|-------------|
| Dispatch loop | `lib/crucible/orchestrator.ex` |
| Per-run state | `lib/crucible/orchestrator/run_server.ex` |
| Phase execution | `lib/crucible/phase_runner/` |
| Agent adapter (SDK path) | `lib/crucible/adapter/claude_sdk.ex` |
| Agent adapter (API path) | `lib/crucible/adapter/claude_api.ex` |
| Elixir side of the bridge | `lib/crucible/adapter/sdk_port.ex` |
| Bridge (Node subprocess) | `bridge/src/sdk-port-bridge.ts` |
| Router | `router/src/` (bundled as `@crucible/router`) |
| Budget | `lib/crucible/budget_tracker.ex` |
| Circuit breakers | `lib/crucible/external_circuit_breaker.ex` |
| Traces | `lib/crucible/trace_event_writer.ex`, `trace_reader.ex` |
| Self-improvement | `lib/crucible/self_improvement.ex` |
| Kanban UI | `lib/crucible_web/live/kanban_live.ex` |
| Cost dashboard | `lib/crucible_web/live/cost_live.ex` |
| Control panel | `lib/crucible_web/live/control_live.ex` |
| Workflow YAMLs | `workflows/*.yml` |

### Adapter Registry

Seven files live under `lib/crucible/adapter/`. Below is their status as of 2026-04-17, determined by grepping for module references in `lib/crucible/phase_runner/`, `lib/crucible/application.ex`, and the rest of `lib/crucible/`.

| Adapter | Verdict | Evidence |
|---------|---------|----------|
| `Crucible.Adapter.Behaviour` | ACTIVE | Implemented by all six adapter modules; defines the `execute_phase/4` + `cleanup_artifacts/2` callbacks. |
| `Crucible.Adapter.ClaudePort` | ACTIVE | `PhaseRunner.Executor.adapter_for/1` returns it as the default non-SDK path (`sdk_or_port/0`); also called directly for team-phase fallback (`executor.ex:193`). |
| `Crucible.Adapter.ClaudeApi` | ACTIVE | `PhaseRunner.Executor.adapter_for(:api)` — used for `:api` phase type (`executor.ex:283`). |
| `Crucible.Adapter.ClaudeHook` | ACTIVE | `PhaseRunner.Executor.adapter_for(:preflight)` — used for `:preflight` phase type (`executor.ex:286`). |
| `Crucible.Adapter.ClaudeSdk` | ACTIVE | `PhaseRunner.Executor.sdk_or_port/0` returns it when `FeatureFlags.enabled?(:sdk_port_adapter)` is true (`executor.ex:291`). |
| `Crucible.Adapter.SdkPort` | ACTIVE | Started under `Crucible.SdkPortSupervisor` (a `DynamicSupervisor`) in `application.ex:104`; receives streaming JSON from the Node bridge. |
| `Crucible.Adapter.ElixirSdk` | LEGACY | No call sites in PhaseRunner, AgentRunner, or the application supervisor. The `Crucible.ElixirSdk.*` subsystem is a separate native-Elixir query engine — it does not use this adapter module. Scheduled for removal in Q3 2026. |

**Finding:** `Crucible.Adapter.ElixirSdk` was ported from the TypeScript predecessor but was never wired into the Elixir phase dispatch path. All other adapters are actively referenced. Do not delete any adapter files until the Q3 2026 removal window.

## Design principles

1. **Single writer per resource.** Every file and every ETS table has exactly one GenServer that owns writes; reads go through it too. Eliminates race conditions.
2. **Sentinel files are the source of truth for phase completion.** If the process dies and restarts, the sentinel tells us what's already done. No DB-only state for irreversible side effects.
3. **Trace everything, decide later.** Every tool call, model response, and state transition is a trace event in Postgres. UIs, KPIs, and self-improvement all read from this one source.
4. **Adapter at every external boundary.** Model providers, git operations, filesystem, GitHub — each sits behind a named behaviour so the core logic never imports HTTP clients directly.
5. **Fail the run, not the platform.** Circuit breakers, supervision trees, and per-run isolation mean a single bad run cannot take the whole orchestrator down.
