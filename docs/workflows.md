# Workflows guide

A **workflow** is a YAML file under `workflows/` that describes a sequence of phases. When a card is dispatched, the executor walks the phases, dispatches agents for each one, and produces a PR.

This guide covers:
- The phase types and when to pick each one
- The stock workflows shipped with Crucible
- How to write your own

## Anatomy of a workflow

```yaml
name: simple-sprint
description: One-coder sprint that produces a PR.

phases:
  - name: sprint
    type: team
    routingProfile: throughput
    parallel: true
    createBranch: true
    agents:
      - role: coder
        model: claude-sonnet-4-6
        description: Solo coder

  - name: pr-shepherd
    type: pr-shepherd
    depends_on: [sprint]
```

Key fields:

| Field | Required? | Meaning |
|---|---|---|
| `name` | yes | The workflow's unique identifier |
| `phases` | yes | Ordered list of phases |
| `phases[].name` | yes | Phase identifier, referenced by `depends_on` |
| `phases[].type` | yes | One of the phase types below |
| `phases[].depends_on` | no | List of phases that must complete first (defaults to "the previous one") |
| `phases[].parallel` | no | If true, the agents within this phase run concurrently instead of sequentially |
| `phases[].createBranch` | no | If true, a git branch is cut off the workspace's default branch for this phase (subsequent phases commit onto the same branch) |
| `phases[].routingProfile` | no | Which router profile to use when selecting a model — `throughput`, `verification`, `exploration`, etc. |
| `phases[].agents[]` | depends on type | Per-agent role + model + description |
| `phases[].maxIterations` | no | For `evaluate` phases — how many times to retry the preceding phase if the evaluator fails |
| `phases[].passingScore` | no | For `evaluate` phases — rubric score threshold |

## Phase types

### `team`
Spawns one or more coder subagents. The agents write code against the shared branch. Subagents are coordinated by a team lead who partitions files and reviews a merged diff before commit.

**Use when:** the work is implementation — writing new code, fixing bugs, refactoring.

### `review-gate`
Spawns reviewer subagents (architect, security, UX, PM) in parallel. Each reviewer reads the plan and produces a written review. The phase passes only if the reviews agree the plan is sound.

**Use when:** you want an upfront sanity check before burning tokens on implementation.

### `preflight`
Single-agent lightweight checklist: does the plan match the workspace's architecture? Are the dependencies available? Is scope sane? Runs fast, cheap model.

**Use when:** you want a quick "is this obviously bad" gate before bigger phases.

### `evaluate`
LLM-as-judge evaluation of the previous phase's output against acceptance criteria. If the rubric average is below `passingScore`, the previous phase re-runs (up to `maxIterations`). If iterations are exhausted, the phase is marked failed and the evaluator's feedback is appended to the trace.

**Use when:** you want the workflow to self-correct on quality dips.

### `pr-shepherd`
The last phase in most workflows. Monitors the PR's CI status, responds to review comments, and fixes CI failures. Runs in a loop until CI is green and all review threads are resolved.

**Use when:** always, as the terminal phase of a workflow that produces a PR.

## Stock workflows

| Workflow | Phases | When to use |
|---|---|---|
| `simple-sprint` | sprint (1 coder) → pr-shepherd | Small tasks. Single-file fixes. E2E testing where multiple coders is overkill. |
| `coding-sprint` | sprint (3 specialist coders) → pr-shepherd | Medium tasks that touch backend, runtime, and frontend concerns. |
| `dual-coder-sprint` | sprint (2 coders) → pr-shepherd | Medium tasks where backend and frontend are the two real axes. |
| `reviewed-sprint` | preflight → design-review → sprint → evaluate → pr-shepherd | Risky or architectural work where you want pre-impl review and post-impl eval. |
| `bug-hunt` | hunt → fix → verify → pr-shepherd | Bug reports where the failure mode isn't obvious. Reproduction first. |
| `bug-hunt-parallel` | Same as bug-hunt but parallel hunters | When you want multiple theories explored concurrently. |
| `code-review` | review-gate only (no code written) | Reviewing an existing PR or module without shipping a change. |
| `design-review` | review-gate only | Evaluating an architecture proposal before any code exists. |
| `repo-optimize` | scan → propose → sprint → pr-shepherd | Cost/perf audits on an unfamiliar repo. |

Pick the lightest workflow that plausibly fits. Crucible charges for model time; `simple-sprint` is often enough.

## Writing a custom workflow

Drop a new YAML file in `workflows/`. No registration step — the executor discovers them at dispatch time.

A minimal workflow:

```yaml
name: smoke-test-only
description: Run the test suite on a branch without making changes.

phases:
  - name: verify
    type: team
    parallel: false
    createBranch: false
    agents:
      - role: coder
        model: claude-haiku-4-5-20251001
        description: Runs tests and reports
```

Tips:

- **Default to parallel** when agents don't share files. Faster and cheaper because agents don't block each other.
- **Use cheap models in gates.** Preflight, design-review, and evaluate phases should use Sonnet (or Haiku for trivial checks), not Opus. Save Opus for phases where reasoning quality is the bottleneck.
- **Keep `depends_on` explicit** for phases you want to run concurrently with others. Without it, the executor falls back to linear order.
- **`createBranch: true` once, never again.** The first sprint phase creates the branch; subsequent phases commit onto the same one. Setting it on a downstream phase resets the branch — rarely what you want.

## Agent roles

The `role` field in `agents[]` controls which Claude Code subagent definition the coder uses. Definitions live in `~/.claude/agents/` (project-level) or are looked up by name. Stock roles shipped with Crucible:

- `coder`, `coder-backend`, `coder-runtime`, `coder-frontend` — implementation specialists
- `reviewer`, `review-architect`, `review-security`, `review-ux`, `review-pm` — review specialists
- `plan`, `explore` — research/plan-only agents

The role drives the system prompt, available tools, and (for Agent Teams) file partitioning rules.

## Model routing

When a phase specifies `routingProfile: throughput` or `verification`, the model field in `agents[]` is a *hint* — the router may downshift to a cheaper model if the task looks simple, or upshift if recent traces show this phase type needs more horsepower.

See `router/` and the [Self-improvement guide](self-improvement.md) for how routing decisions are made and tuned over time.

## Debugging a workflow

- **Live trace:** `http://localhost:4801/runs/<run_id>/traces` streams events as they land.
- **Cold trace:** `traces/<run_id>.jsonl` — one JSON object per event. Easy to grep.
- **Phase status:** the kanban card's phase_cards metadata shows per-phase pass/fail + which agents ran.
- **Why did my phase retry?** Look for `evaluate` events in the trace. The rubric scores and evaluator's feedback are recorded there.
- **Why did my phase skip?** Probably `depends_on` — a prerequisite phase failed and blocked its dependents. Check the upstream phase's trace.

## When to write a new workflow (vs. tweak an existing one)

Write a new YAML when your task category is **genuinely different** from the stock ones — e.g. a "docs-only" workflow that skips compile checks, or a "security audit" workflow that runs only review phases.

For one-off tweaks (use Opus for this specific card, add one more reviewer), prefer setting per-card overrides via the kanban UI rather than forking a workflow YAML. The workflow set is meant to be small and stable.
