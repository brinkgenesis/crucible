// @ts-nocheck — TODO: reconcile with @anthropic-ai/claude-agent-sdk types
// and re-home workflow-builder helpers; this file was lifted verbatim from
// the upstream infra repo and still references sibling types that haven't
// been fully ported. Remove this directive once the port is complete.

/**
 * Builds SDK AgentDefinition objects from agent YAML files + file ownership.
 *
 * Transforms the existing .claude/agents/*.yml role definitions into
 * the @anthropic-ai/claude-agent-sdk AgentDefinition format, injecting
 * per-agent file ownership and plan context.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parse as yamlParse } from "yaml";
import type { AgentDefinition } from "@anthropic-ai/claude-agent-sdk";
import {
  assignFilesDeterministically,
  extractPlanFiles,
  type DeterministicCoderRole,
} from "./deterministic-role-assignment.js";
import type { WorkflowRun, PhaseCard } from "./types.js";
import { createLogger } from "./logger.js";

const log = createLogger("sdk:agent-builder");

interface AgentYamlMeta {
  name: string;
  description: string;
  model?: string;
  capabilities?: string[];
  denied_tools?: string[];
}

/** Read agent YAML and split front-matter from system prompt. */
function loadAgentYaml(infraHome: string, role: string): { meta: AgentYamlMeta; systemPrompt: string } | null {
  const yamlPath = join(infraHome, ".claude", "agents", `${role}.yml`);
  if (!existsSync(yamlPath)) {
    log.warn({ role, yamlPath }, "Agent YAML not found");
    return null;
  }
  const raw = readFileSync(yamlPath, "utf-8");
  const parts = raw.split(/^---$/m);
  const meta = yamlParse(parts[0]) as AgentYamlMeta;
  const systemPrompt = parts.slice(1).join("---").trim();
  return { meta, systemPrompt };
}

/** Determine tool set per role. Reviewer gets read + git; coders get full edit. */
function toolsForRole(role: string): string[] {
  if (role === "reviewer") {
    return ["Read", "Glob", "Grep", "Bash"];
  }
  return ["Read", "Write", "Edit", "Glob", "Grep", "Bash"];
}

/** Build SDK AgentDefinition objects for each role in a team phase. */
export function buildAgentDefinitions(
  infraHome: string,
  roles: string[],
  planContext: string,
  run: WorkflowRun,
  phase: PhaseCard,
): Record<string, AgentDefinition> {
  // Use scheduler assignments if available, fall back to deterministic file ownership
  const schedule = run.executionSchedule;
  const coordUnits = run.coordinatorWorkUnits;

  let ownership: Record<string, string[]>;
  if (schedule && coordUnits && coordUnits.length > 0) {
    // Build ownership from scheduler assignments
    ownership = {} as Record<string, string[]>;
    for (const role of roles) ownership[role] = [];
    const unitMap = new Map(coordUnits.map((u) => [u.id, u]));
    for (const a of schedule.assignments) {
      const unit = unitMap.get(a.taskId);
      if (unit && ownership[a.assignedRole]) {
        ownership[a.assignedRole].push(...unit.files);
      }
    }
    log.info({ source: "capability-scheduler" }, "Using scheduler-computed file ownership");
  } else {
    // Fallback: deterministic file ownership from plan text
    const planSources = [run.planSummary ?? "", run.taskDescription, planContext];
    const files = extractPlanFiles(planSources.join("\n"));
    ownership = assignFilesDeterministically(files);
  }

  // Build execution tier info from scheduler
  const tierInfo = schedule?.executionOrder && schedule.executionOrder.length > 1
    ? `\n## Execution Order\n${schedule.executionOrder.map((tier, i) => `Tier ${i + 1}: ${tier.join(", ")}`).join("\n")}\n`
    : "";

  const agents: Record<string, AgentDefinition> = {};
  for (const role of roles) {
    const loaded = loadAgentYaml(infraHome, role);
    if (!loaded) continue;

    const { meta, systemPrompt } = loaded;
    const ownedFiles = ownership[role as DeterministicCoderRole] ?? ownership[role] ?? [];
    const filesSection = ownedFiles.length > 0
      ? `\n## Your Files\nYou own these files — only edit files in this list:\n${ownedFiles.map((f) => `- ${f}`).join("\n")}\n`
      : "";

    // Inject assigned work unit descriptions for richer context
    let workUnitSection = "";
    if (schedule && coordUnits) {
      const myUnits = schedule.assignments
        .filter((a) => a.assignedRole === role)
        .map((a) => coordUnits.find((u) => u.id === a.taskId))
        .filter(Boolean);
      if (myUnits.length > 0) {
        workUnitSection = `\n## Your Work Units\n${myUnits.map((u) =>
          `### ${u!.id}\n${u!.description}\n${u!.acceptanceCriteria.map((c) => `- [ ] ${c}`).join("\n")}`,
        ).join("\n\n")}\n`;
      }
    }

    const phaseContext = `\n## Task\n${run.taskDescription}\n\nWorking directory: ${infraHome}\n`;

    agents[role] = {
      description: meta.description,
      prompt: `${systemPrompt}\n${phaseContext}${filesSection}${workUnitSection}${tierInfo}`,
      model: meta.model ?? "sonnet",
      tools: toolsForRole(role),
      disallowedTools: meta.denied_tools,
      maxTurns: role === "reviewer" ? 20 : 15,
    };

    log.info({ role, model: meta.model, files: ownedFiles.length, workUnits: workUnitSection ? "yes" : "no" }, "Built agent definition");
  }
  return agents;
}

/** Build a simplified orchestrator prompt for SDK-native team phases. */
export function buildSdkTeamOrchestratorPrompt(
  run: WorkflowRun,
  phase: PhaseCard,
  agentDefs: Record<string, AgentDefinition>,
): string {
  const roles = Object.keys(agentDefs);
  const coderRoles = roles.filter((r) => r !== "reviewer");
  const hasReviewer = roles.includes("reviewer");
  const agentList = roles.map((r) => `- **${r}**: ${agentDefs[r].description.slice(0, 80)}`).join("\n");

  const reviewerStep = hasReviewer
    ? `3. After all coders finish, dispatch the **reviewer** agent to:
   - Review all changes: read the diff, check for bugs, verify correctness
   - Run \`tsc --noEmit\` and \`npx vitest run\`
   - Fix any issues found
   - Stage and commit all changes with a descriptive message
4. Report the final result (commit hash, files changed, test status)`
    : `3. Report the final result`;

  return `You are orchestrating phase "${phase.phaseName}" of workflow "${run.workflowName}".

## Task
${run.taskDescription}

## Available Agents
${agentList}

## Instructions
1. Dispatch work to each **coder** agent (${coderRoles.join(", ")}) using the Agent tool
   - Each agent has pre-configured file ownership and system prompt
   - Send each agent a clear description of what to implement
   - Dispatch all coders in parallel (multiple Agent calls in one message)
2. Wait for all coder agents to return their results
${reviewerStep}

## Rules
- Do NOT use TeamCreate or TaskCreate — agents are pre-defined via the SDK
- Do NOT implement code yourself — you are the orchestrator
- Do NOT use Read, Write, Edit, or Glob tools — only Agent tool
- Each agent runs independently with its own tools and context
- If an agent reports an error, note it and continue with the others`;
}
