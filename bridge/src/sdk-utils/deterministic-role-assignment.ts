/**
 * Deterministic file-to-role assignment for parallel coder phases.
 *
 * Guarantees each file maps to exactly one coder role so plans remain
 * conflict-free and repeatable across runs.
 */

export type DeterministicCoderRole = "coder-backend" | "coder-runtime" | "coder-frontend";

export interface CoderRoleProfile {
  roleId: DeterministicCoderRole;
  employeeName: string;
  employeeTitle: string;
}

export const CODER_ROLE_PROFILES: ReadonlyArray<CoderRoleProfile> = [
  { roleId: "coder-backend", employeeName: "Ava Park", employeeTitle: "Backend Engineer" },
  { roleId: "coder-runtime", employeeName: "Marco Ibarra", employeeTitle: "Runtime Reliability Engineer" },
  { roleId: "coder-frontend", employeeName: "Lena Kovacs", employeeTitle: "Frontend + DX Engineer" },
];

/** Non-coder role profiles (reviewer, architect, etc.) used for identity packets. */
export const EXTRA_ROLE_PROFILES: ReadonlyMap<string, { employeeName: string; employeeTitle: string }> = new Map([
  ["reviewer", { employeeName: "Sofia Reyes", employeeTitle: "Principal Reviewer" }],
  ["researcher", { employeeName: "Nora Patel", employeeTitle: "Research Lead" }],
  ["researcher-code", { employeeName: "Jun Watanabe", employeeTitle: "Code Hypothesis Researcher" }],
  ["researcher-infra", { employeeName: "Kai Eriksson", employeeTitle: "Infrastructure Hypothesis Researcher" }],
  ["researcher-data", { employeeName: "Mira Santos", employeeTitle: "Data Flow Hypothesis Researcher" }],
  ["review-architect", { employeeName: "Elias Morgan", employeeTitle: "Architecture Reviewer" }],
  ["review-security", { employeeName: "Nadia Chen", employeeTitle: "Security Reviewer" }],
  ["review-ux", { employeeName: "Tomás Rivera", employeeTitle: "UX & API Design Reviewer" }],
  ["review-pm", { employeeName: "Priya Kapoor", employeeTitle: "Product & Scope Reviewer" }],
  ["sweeper", { employeeName: "Kira Tanaka", employeeTitle: "Codebase Sweep Agent" }],
]);

export const ROLE_PATH_PREFIXES: Record<DeterministicCoderRole, string[]> = {
  "coder-backend": [
    "dashboard/api/",
    "lib/router/",
    "lib/db/",
    "lib/mcp-servers/",
    "lib/memory/",
    "lib/indexer/",
    "lib/compression/",
    "lib/tools/",
    "workflows/",
  ],
  "coder-runtime": [
    ".claude/",
    "hooks/",
    "scripts/",
    "monitoring/",
    "lib/harness/",
    "lib/observability/",
    "lib/cli/workflow-executor",
    "lib/cli/workflow-execution-adapters/",
    "lib/cli/self-improvement/",
    "services/scheduler/",
  ],
  "coder-frontend": [
    "dashboard/web/",
  ],
};

const FILE_CAPTURE_RE =
  /(?:^|\s|`|'|")((?:\.claude|lib|dashboard|tests|workflows|scripts|monitoring|services|agents|hooks)\/[\w./@-]+\.\w+)(?=$|\s|`|'|")/g;

/** Extract likely file paths from markdown/plain-text plan content. */
export function extractPlanFiles(content: string): string[] {
  const found = new Set<string>();
  let match: RegExpExecArray | null;
  FILE_CAPTURE_RE.lastIndex = 0;
  while ((match = FILE_CAPTURE_RE.exec(content)) !== null) {
    const normalized = normalizeFilePath(match[1]);
    if (normalized) found.add(normalized);
  }
  return [...found].sort();
}

/** Normalize user/plan-supplied path tokens to workspace-relative paths. */
export function normalizeFilePath(value: string): string {
  const trimmed = value.trim().replace(/^`|`$/g, "");
  if (!trimmed) return "";
  return trimmed
    .replace(/^\.\/+/, "")
    .replace(/^\/Users\/[^/]+\/infra\//, "")
    .replace(/\\/g, "/");
}

export function classifyFileRole(filePath: string): DeterministicCoderRole {
  const normalized = normalizeFilePath(filePath).toLowerCase();

  // Frontend first to keep web assets isolated.
  if (
    normalized.startsWith("dashboard/web/") ||
    normalized.endsWith(".tsx") ||
    normalized.endsWith(".jsx") ||
    normalized.endsWith(".css")
  ) {
    return "coder-frontend";
  }

  // Runtime reliability + orchestration internals.
  if (
    normalized.startsWith(".claude/") ||
    normalized.startsWith("hooks/") ||
    normalized.startsWith("scripts/") ||
    normalized.startsWith("monitoring/") ||
    normalized.startsWith("lib/harness/") ||
    normalized.startsWith("lib/observability/") ||
    normalized.startsWith("services/scheduler/") ||
    normalized.includes("workflow-executor") ||
    normalized.includes("workflow-execution-adapters") ||
    normalized.includes("workflow-self-improvement")
  ) {
    return "coder-runtime";
  }

  // Default: backend/server/data-plane changes.
  return "coder-backend";
}

/** Deterministically map each file to exactly one coder role (no overlaps). */
export function assignFilesDeterministically(files: string[]): Record<DeterministicCoderRole, string[]> {
  const unique = [...new Set(files.map(normalizeFilePath).filter(Boolean))].sort();
  const assigned: Record<DeterministicCoderRole, string[]> = {
    "coder-backend": [],
    "coder-runtime": [],
    "coder-frontend": [],
  };

  for (const file of unique) {
    assigned[classifyFileRole(file)].push(file);
  }
  return assigned;
}

export function getRoleProfile(roleId: DeterministicCoderRole): CoderRoleProfile {
  const found = CODER_ROLE_PROFILES.find((profile) => profile.roleId === roleId);
  if (!found) {
    throw new Error(`Missing coder role profile: ${roleId}`);
  }
  return found;
}

// ── Work-unit-based assignment ───────────────────────────────────────────────

import type { WorkUnit } from "./types.js";

/**
 * Get the dominant coder role for a set of files (majority vote).
 * Each file is classified via classifyFileRole, and the role with
 * the most votes wins.
 *
 * Test files (tests/*.ts) are excluded from voting so they don't
 * skew the result — tests should follow the source files they test.
 * Ties break alphabetically for determinism.
 */
export function dominantRole(files: string[]): DeterministicCoderRole {
  const votes: Record<DeterministicCoderRole, number> = {
    "coder-backend": 0,
    "coder-runtime": 0,
    "coder-frontend": 0,
  };
  // Separate source files from test files; tests follow the source majority
  const sourceFiles = files.filter((f) => !normalizeFilePath(f).startsWith("tests/"));
  const votingFiles = sourceFiles.length > 0 ? sourceFiles : files;
  for (const file of votingFiles) {
    votes[classifyFileRole(file)]++;
  }
  const roles = Object.keys(votes) as DeterministicCoderRole[];
  roles.sort((a, b) => votes[b] - votes[a] || a.localeCompare(b));
  return roles[0];
}

/**
 * Assign work units to agent roles based on semantic grouping.
 * Each work unit stays atomic — all its files go to one agent.
 * Uses majority-vote classification on each unit's files.
 *
 * When the dominant role for a unit is absent (scaled away by complexity),
 * the unit is assigned to the available role with the fewest units (load balancing).
 */
export function resolveWorkAssignment(
  workUnits: WorkUnit[],
  availableRoles: DeterministicCoderRole[],
): Record<DeterministicCoderRole, WorkUnit[]> {
  const assignment: Record<DeterministicCoderRole, WorkUnit[]> = {
    "coder-backend": [],
    "coder-runtime": [],
    "coder-frontend": [],
  };

  if (availableRoles.length === 0) return assignment;

  // Sort for deterministic load-balancing regardless of input order
  const sortedRoles = [...availableRoles].sort();
  const available = new Set(sortedRoles);
  for (const wu of workUnits) {
    const preferred = dominantRole(wu.files);
    if (available.has(preferred)) {
      assignment[preferred].push(wu);
    } else {
      // Load-balance across available roles (sorted for determinism)
      const target = sortedRoles.reduce((min, role) =>
        assignment[role].length < assignment[min].length ? role : min,
      );
      assignment[target].push(wu);
    }
  }

  return assignment;
}
