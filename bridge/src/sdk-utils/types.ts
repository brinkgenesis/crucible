// Minimal workflow-run shape the bridge needs from Elixir.
// Wider shapes live in the Crucible core; this file intentionally captures
// only the fields the bridge actually reads.

export interface WorkflowRun {
  runId: string;
  workflowName: string;
  cardId?: string | null;
  clientId?: string | null;
  planNote?: string | null;
  planSummary?: string | null;
  branch?: string | null;
  taskDescription?: string | null;
  executionType?: "subscription" | "api" | "sdk";
}

export interface PhaseCard {
  id: string;
  phaseName: string;
  type: string;
  phaseIndex: number;
  routingProfile?: string | null;
  agents?: string[];
  timeoutMs?: number;
}

/** Scheduler work unit (decomposed sub-task). */
export interface WorkUnit {
  id: string;
  goal: string;
  files?: string[];
  keywords?: string[];
  dependsOn?: string[];
}

// Extended fields emitted by the coordinator/scheduler (optional).
declare module "./types.js" {
  interface WorkflowRun {
    executionSchedule?: {
      tiers: Array<{ units: Array<{ id: string; files?: string[] }> }>;
    };
    coordinatorWorkUnits?: WorkUnit[];
  }
}
