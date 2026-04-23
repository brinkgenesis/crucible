// @ts-nocheck — TODO: reconcile with @anthropic-ai/claude-agent-sdk types
// and re-home workflow-builder helpers; this file was lifted verbatim from
// the upstream infra repo and still references sibling types that haven't
// been fully ported. Remove this directive once the port is complete.

/**
 * SDK permission resolution — shared between sdk-port-bridge and adapters.
 * Extracted from the deprecated claude-agent-sdk adapter.
 */

import type { Options } from "@anthropic-ai/claude-agent-sdk";
import { getPermissions, isToolAllowed, type WorkspacePermissions } from "./workspace-permissions.js";

interface PhaseStub {
  routingProfile?: string;
}

const READ_ONLY_ROUTING_PROFILES = new Set(["scout", "deep-reasoning"]);
const READ_ONLY_TOOLS = ["Write", "Edit", "NotebookEdit"];

export function resolvePermissions(phase: PhaseStub): {
  permissionMode: Options["permissionMode"];
  allowedTools?: string[];
  disallowedTools?: string[];
  allowDangerouslySkipPermissions?: boolean;
  canUseTool?: Options["canUseTool"];
} {
  const routingProfile = phase.routingProfile ?? "throughput";
  const workspacePermissions = getPermissions();
  const disallowedTools = buildDisallowedTools(routingProfile, workspacePermissions);

  return {
    permissionMode: "bypassPermissions",
    allowDangerouslySkipPermissions: true,
    ...(disallowedTools.length > 0 ? { disallowedTools } : {}),
    canUseTool: async (toolName, input) => {
      if (disallowedTools.includes(toolName)) {
        return {
          behavior: "deny",
          message: `Tool "${toolName}" is blocked for routing profile "${routingProfile}"`,
        };
      }

      const mapped = mapClaudeTool(toolName, input);
      if (!mapped) return { behavior: "allow" };

      const decision = isToolAllowed(mapped.toolName, mapped.toolInput, workspacePermissions);

      if (decision.allowed) {
        return { behavior: "allow" };
      }

      return {
        behavior: "deny",
        message: decision.reason ?? `Tool "${toolName}" is blocked by workspace permissions`,
      };
    },
  };
}

function buildDisallowedTools(
  routingProfile: string,
  workspacePermissions: WorkspacePermissions,
): string[] {
  const tools = new Set<string>();

  if (READ_ONLY_ROUTING_PROFILES.has(routingProfile)) {
    READ_ONLY_TOOLS.forEach((tool) => tools.add(tool));
  }

  if (workspacePermissions.profile === "strict") {
    tools.add("Bash");
  }

  return Array.from(tools);
}

function mapClaudeTool(
  toolName: string,
  input: Record<string, unknown>,
): { toolName: string; toolInput: Record<string, unknown> } | null {
  switch (toolName) {
    case "Bash":
      return {
        toolName: "run_command",
        toolInput: { command: typeof input.command === "string" ? input.command : "" },
      };

    case "Write":
    case "Edit":
    case "NotebookEdit":
    case "write_file":
    case "edit_file":
      return {
        toolName: "write_file",
        toolInput: { content: extractWriteContent(input) },
      };

    case "git_commit":
      return { toolName: "git_commit", toolInput: {} };

    default:
      return null;
  }
}

function extractWriteContent(input: Record<string, unknown>): string {
  const candidates = [
    input.content,
    input.new_string,
    input.newString,
    input.new_source,
    input.text,
  ];

  const found = candidates.find((value) => typeof value === "string");
  return typeof found === "string" ? found : "";
}
