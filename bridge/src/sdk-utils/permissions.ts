// @ts-nocheck — TODO: reconcile with @anthropic-ai/claude-agent-sdk types
// and re-home workflow-builder helpers; this file was lifted verbatim from
// the upstream infra repo and still references sibling types that haven't
// been fully ported. Remove this directive once the port is complete.

/**
 * SDK permission resolution — shared between sdk-port-bridge and adapters.
 * Extracted from the deprecated claude-agent-sdk adapter.
 */

import type { Options } from "@anthropic-ai/claude-agent-sdk";

interface PhaseStub {
  routingProfile?: string;
}

export function resolvePermissions(phase: PhaseStub): {
  permissionMode: Options["permissionMode"];
  allowedTools?: string[];
  disallowedTools?: string[];
  allowDangerouslySkipPermissions?: boolean;
} {
  const profile = phase.routingProfile ?? "throughput";

  let disallowedTools: string[] = [];
  try {
    const { getPermissions } = require("../../../api-executor/workspace-permissions.js") as typeof import("../../../api-executor/workspace-permissions.js");
    const perms = getPermissions();
    disallowedTools = Array.from(perms.blockedTools);
  } catch {
    // workspace-permissions not available
  }

  if (profile === "scout" || profile === "deep-reasoning") {
    return {
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      disallowedTools: [...new Set([...disallowedTools, "Write", "Edit", "NotebookEdit"])],
    };
  }

  return {
    permissionMode: "bypassPermissions",
    allowDangerouslySkipPermissions: true,
    ...(disallowedTools.length > 0 ? { disallowedTools } : {}),
  };
}
