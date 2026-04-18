/**
 * Per-workspace permission profiles for tool access control.
 *
 * Defines three trust levels (permissive, standard, strict) that gate
 * which tools are available and what bash commands are allowed.
 *
 * Profiles are resolved from workspace config or environment variable.
 * The dispatch layer calls `isToolAllowed()` before executing any tool.
 *
 * @module
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type PermissionProfile = "permissive" | "standard" | "strict";

export interface WorkspacePermissions {
  profile: PermissionProfile;
  /** Tools completely blocked in this profile. */
  blockedTools: Set<string>;
  /** Bash commands blocked by substring match. */
  blockedBashPatterns: string[];
  /** Whether LLM-routed calls (route_llm) are allowed. */
  allowLlmRouting: boolean;
  /** Whether git write operations (commit, push) are allowed. */
  allowGitWrites: boolean;
  /** Maximum file write size in bytes (0 = unlimited). */
  maxWriteBytes: number;
}

// ---------------------------------------------------------------------------
// Profile definitions
// ---------------------------------------------------------------------------

const PROFILES: Record<PermissionProfile, WorkspacePermissions> = {
  permissive: {
    profile: "permissive",
    blockedTools: new Set<string>(),
    blockedBashPatterns: [],
    allowLlmRouting: true,
    allowGitWrites: true,
    maxWriteBytes: 0,
  },
  standard: {
    profile: "standard",
    blockedTools: new Set<string>(),
    blockedBashPatterns: [
      "npm publish",
      "yarn publish",
      "docker push",
      "git push --force",
      "git push -f",
    ],
    allowLlmRouting: true,
    allowGitWrites: true,
    maxWriteBytes: 1024 * 1024, // 1 MB
  },
  strict: {
    profile: "strict",
    blockedTools: new Set(["run_command", "git_commit"]),
    blockedBashPatterns: [
      "npm", "yarn", "pnpm",
      "docker", "podman",
      "curl", "wget",
      "ssh", "scp",
      "git push",
    ],
    allowLlmRouting: false,
    allowGitWrites: false,
    maxWriteBytes: 512 * 1024, // 512 KB
  },
};

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

/**
 * Resolve the permission profile for the current workspace.
 *
 * Priority: WORKSPACE_PERMISSION_PROFILE env var > default "standard".
 */
export function resolveProfile(envOverride?: string): PermissionProfile {
  const raw = envOverride ?? process.env.WORKSPACE_PERMISSION_PROFILE ?? "standard";
  if (raw in PROFILES) return raw as PermissionProfile;
  return "standard";
}

/** Get the full permissions config for a profile. */
export function getPermissions(profile?: PermissionProfile): WorkspacePermissions {
  return PROFILES[profile ?? resolveProfile()];
}

// ---------------------------------------------------------------------------
// Enforcement
// ---------------------------------------------------------------------------

export interface PermissionCheckResult {
  allowed: boolean;
  reason?: string;
}

/**
 * Check whether a tool call is allowed under the current workspace profile.
 */
export function isToolAllowed(
  toolName: string,
  toolInput: Record<string, unknown>,
  permissions?: WorkspacePermissions,
): PermissionCheckResult {
  const perms = permissions ?? getPermissions();

  // Blocked tool check.
  if (perms.blockedTools.has(toolName)) {
    return { allowed: false, reason: `Tool "${toolName}" is blocked in ${perms.profile} profile` };
  }

  // Git write check.
  if (!perms.allowGitWrites && toolName === "git_commit") {
    return { allowed: false, reason: `Git writes blocked in ${perms.profile} profile` };
  }

  // LLM routing check.
  if (!perms.allowLlmRouting && toolName === "route_llm") {
    return { allowed: false, reason: `LLM routing blocked in ${perms.profile} profile` };
  }

  // Bash pattern check for run_command.
  if (toolName === "run_command" && typeof toolInput.command === "string") {
    const cmd = toolInput.command as string;
    const cmdLower = cmd.toLowerCase();

    // Check for indirect execution wrappers that could bypass pattern matching.
    const INDIRECT_EXEC = /\b(xargs|eval|sh\s+-c|bash\s+-c|zsh\s+-c|exec)\b/i;
    if (INDIRECT_EXEC.test(cmd) && perms.profile === "strict") {
      return { allowed: false, reason: `Indirect execution (${cmd.match(INDIRECT_EXEC)![0]}) blocked in strict profile` };
    }

    for (const pattern of perms.blockedBashPatterns) {
      if (cmdLower.includes(pattern.toLowerCase())) {
        return { allowed: false, reason: `Command contains blocked pattern "${pattern}" in ${perms.profile} profile` };
      }
    }
  }

  // File size check for write_file.
  if (toolName === "write_file" && perms.maxWriteBytes > 0) {
    const content = toolInput.content as string | undefined;
    if (content && Buffer.byteLength(content) > perms.maxWriteBytes) {
      return {
        allowed: false,
        reason: `Write exceeds ${perms.maxWriteBytes} byte limit in ${perms.profile} profile`,
      };
    }
  }

  return { allowed: true };
}
