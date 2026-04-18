/**
 * Mid-phase intelligence: model downshifting + course correction.
 *
 * Shared between the SDK adapter (direct TS path) and the SDK port bridge
 * (Elixir Port path) so both execution paths get the same behavior.
 *
 * Both features have kill switches via environment variables:
 *   WORKFLOW_MODEL_DOWNSHIFT=0  → disable model downshifting
 *   WORKFLOW_COURSE_CORRECTION=0 → disable course correction
 */

/** Module version — used for SDK alignment smoke tests. */
export const VERSION = "0.3.0";

// ---------------------------------------------------------------------------
// Timestamp helpers
// ---------------------------------------------------------------------------

/** Minimum duration floor (ms) — prevents 0-duration phases in DB/logs. */
export const PHASE_TIMER_FLOOR_MS = 1;

/** Returns the current wall-clock time as an ISO-8601 string. */
export function nowIso(): string {
  return new Date().toISOString();
}

/**
 * Parses an ISO-8601 string to epoch milliseconds.
 * Returns NaN for invalid/unparseable input (callers should guard).
 */
export function isoToMs(iso: string): number {
  return Date.parse(iso);
}

/** Parses an ISO-8601 timestamp string to epoch milliseconds. */
export function isoToEpochMs(iso: string): number {
  return new Date(iso).getTime();
}

/**
 * Converts epoch milliseconds to an ISO-8601 string.
 * Inverse of isoToMs() / isoToEpochMs().
 * Returns "Invalid Date" for NaN/Infinity/non-finite input.
 */
export function msToIso(ms: number): string {
  if (!Number.isFinite(ms)) throw new RangeError(`Invalid time value: ${ms}`);
  return new Date(ms).toISOString();
}

/**
 * Computes elapsed milliseconds since a given ISO-8601 timestamp.
 * Applies the same PHASE_TIMER_FLOOR_MS floor guard as PhaseTimer.elapsedMs()
 * so callers never see 0 ms.  Returns NaN if the input is unparseable.
 */
export function elapsedSinceIso(startIso: string, now?: number): number {
  const startMs = Date.parse(startIso);
  if (Number.isNaN(startMs)) return NaN;
  return Math.max(PHASE_TIMER_FLOOR_MS, (now ?? Date.now()) - startMs);
}

/** Threshold (ms) at which formatDuration switches from "Xms" to "X.Ys". */
export const DURATION_MS_THRESHOLD = 1000;
/** Threshold (seconds) at which formatDuration switches from "X.Ys" to "Xm Ys". */
export const DURATION_S_THRESHOLD = 60;
/** Threshold (minutes) at which formatDuration switches from "Xm Ys" to "Xh Ym". */
export const DURATION_M_THRESHOLD = 60;

/**
 * Formats a duration in milliseconds to a human-readable string.
 *
 * - < 1000ms:  "500ms"
 * - < 60s:     "1.5s"
 * - < 60m:     "2m 30s"
 * - ≥ 60m:     "1h 5m"
 *
 * Negative inputs are clamped to 0.
 */
export function formatDuration(ms: number): string {
  if (ms < 0) ms = 0;
  if (ms < DURATION_MS_THRESHOLD) return `${Math.round(ms)}ms`;
  const seconds = ms / 1000;
  if (seconds < DURATION_S_THRESHOLD) return `${seconds.toFixed(1)}s`;
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = Math.round(seconds % 60);
  if (minutes < DURATION_M_THRESHOLD) return remainingSeconds > 0 ? `${minutes}m ${remainingSeconds}s` : `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  return remainingMinutes > 0 ? `${hours}h ${remainingMinutes}m` : `${hours}h`;
}

/** Summary snapshot returned by PhaseTimer.summary(). */
export interface PhaseTimerSummary {
  startedAt: string;
  durationMs: number;
  durationHuman: string;
}

/**
 * Centralises phase timing: ISO timestamps, elapsed duration, and a
 * floor guard so durations are never reported as 0 ms.
 *
 * Used by every execution adapter instead of ad-hoc Date.now() / toISOString().
 */
export class PhaseTimer {
  private readonly startMs: number;

  constructor(now?: number) {
    this.startMs = now ?? Date.now();
  }

  /** ISO-8601 timestamp string (current wall clock). */
  iso(now?: number): string {
    return new Date(now ?? Date.now()).toISOString();
  }

  /** Milliseconds elapsed since construction, minimum PHASE_TIMER_FLOOR_MS. */
  elapsedMs(now?: number): number {
    return Math.max(PHASE_TIMER_FLOOR_MS, (now ?? Date.now()) - this.startMs);
  }

  /** The raw start time (ms since epoch). */
  start(): number {
    return this.startMs;
  }

  /** Convenience: returns `{ timestamp, durationMs }` in one call. */
  snapshot(now?: number): { timestamp: string; durationMs: number } {
    const t = now ?? Date.now();
    return { timestamp: new Date(t).toISOString(), durationMs: Math.max(PHASE_TIMER_FLOOR_MS, t - this.startMs) };
  }

  /** Returns a summary of the timer's current state. */
  summary(now?: number): PhaseTimerSummary {
    const t = now ?? Date.now();
    const durationMs = Math.max(PHASE_TIMER_FLOOR_MS, t - this.startMs);
    return {
      startedAt: new Date(this.startMs).toISOString(),
      durationMs,
      durationHuman: formatDuration(durationMs),
    };
  }
}

// ---------------------------------------------------------------------------
// Model downshifting
// ---------------------------------------------------------------------------

/** Tools that indicate the transition from planning to implementation.
 *  Exported for SDK alignment tests — both ModelDownshiftTracker and
 *  CourseCorrector use this set to classify tool calls. */
export const IMPLEMENTATION_TOOLS = new Set(["Edit", "edit_file", "Write", "write_file"]);
/** Default downshift target model. Override with WORKFLOW_DOWNSHIFT_MODEL. */
export const DOWNSHIFT_MODEL = process.env["WORKFLOW_DOWNSHIFT_MODEL"] ?? "sonnet";
/** Kill switch: set WORKFLOW_MODEL_DOWNSHIFT=0 to disable. */
const MODEL_DOWNSHIFT_ENABLED = process.env["WORKFLOW_MODEL_DOWNSHIFT"] !== "0";
/** Minimum tool calls before downshift. Set high enough that the model has
 *  done meaningful planning (Read/Grep/Glob) before we switch. A hot-fix
 *  phase that starts with an immediate Edit won't trigger at call 3. */
export const DOWNSHIFT_MIN_TOOL_CALLS = 6;
/** Minimum implementation tool calls (Edit/Write) before downshift triggers.
 *  Ensures at least one write-intent tool was used, not just reads. */
export const DOWNSHIFT_MIN_IMPL_CALLS = 1;

/** Summary snapshot returned by ModelDownshiftTracker.summary(). */
export interface ModelDownshiftSummary {
  totalCalls: number;
  implementationCalls: number;
  downshifted: boolean;
  targetModel: string | null;
}

/**
 * Tracks tool usage patterns and triggers model downshift when the phase
 * transitions from planning (Read/Glob/Grep) to implementation (Edit/Write).
 *
 * Heuristic: downshift after seeing DOWNSHIFT_MIN_TOOL_CALLS total calls AND
 * at least one implementation tool call. This avoids premature switching on
 * phases that start with a quick edit before doing heavy reasoning.
 */
export class ModelDownshiftTracker {
  private totalCalls = 0;
  private implementationCalls = 0;
  private downshifted = false;
  private readonly enabled: boolean;

  constructor(phaseType: string) {
    // Only downshift for session (coding) phases — not scout, verification, team
    this.enabled = MODEL_DOWNSHIFT_ENABLED && phaseType === "session";
  }

  /** Call after each tool execution. Returns model name to switch to, or null. */
  onToolCall(toolName: string): string | null {
    if (!this.enabled) return null;
    this.totalCalls++;
    if (IMPLEMENTATION_TOOLS.has(toolName)) this.implementationCalls++;

    if (!this.downshifted && this.totalCalls >= DOWNSHIFT_MIN_TOOL_CALLS && this.implementationCalls >= DOWNSHIFT_MIN_IMPL_CALLS) {
      this.downshifted = true;
      return DOWNSHIFT_MODEL;
    }
    return null;
  }

  /** Resets all internal state so the tracker can be reused for a new phase. */
  reset(): void {
    this.totalCalls = 0;
    this.implementationCalls = 0;
    this.downshifted = false;
  }

  didDownshift(): boolean { return this.downshifted; }

  /** Returns a summary of the downshift tracker's current state. */
  summary(): ModelDownshiftSummary {
    return {
      totalCalls: this.totalCalls,
      implementationCalls: this.implementationCalls,
      downshifted: this.downshifted,
      targetModel: this.downshifted ? DOWNSHIFT_MODEL : null,
    };
  }
}

// ---------------------------------------------------------------------------
// Course correction
// ---------------------------------------------------------------------------

/** Kill switch: set WORKFLOW_COURSE_CORRECTION=0 to disable. */
const COURSE_CORRECTION_ENABLED = process.env["WORKFLOW_COURSE_CORRECTION"] !== "0";
/** Max corrections per phase to avoid infinite intervention loops. */
export const MAX_CORRECTIONS = 2;
/** Per-file edit count before triggering a loop-detection correction. */
export const EDIT_LOOP_THRESHOLD = 5;
/** Repeated command count (by 40-char prefix) before triggering correction. */
export const COMMAND_REPEAT_THRESHOLD = 4;
/** Consecutive error streak count before triggering correction. */
export const ERROR_STREAK_THRESHOLD = 5;
/** Character prefix length for command deduplication (longer commands are
 *  compared by their first N characters to group similar invocations). */
export const COMMAND_PREFIX_LENGTH = 40;

/** Summary snapshot returned by CourseCorrector.summary(). */
export interface CourseCorrectorSummary {
  corrections: number;
  maxCorrections: number;
  capped: boolean;
  trackedFiles: number;
  trackedCommands: number;
}

/**
 * Tracks tool call patterns to detect potential loops or drift.
 * Emits at most MAX_CORRECTIONS correction messages per phase.
 */
export class CourseCorrector {
  private readonly enabled: boolean;
  private corrections = 0;
  /** Per-file edit counts: path → count */
  private editCounts = new Map<string, number>();
  /** Per-command counts: command prefix → count */
  private commandCounts = new Map<string, number>();
  private consecutiveErrors = 0;

  constructor(phaseType: string) {
    // Only for execution phases, not scout/verification
    this.enabled = COURSE_CORRECTION_ENABLED
      && (phaseType === "session" || phaseType === "team");
  }

  /** Call after each tool execution. Returns a correction message or null. */
  onToolCall(
    toolName: string,
    filePath: string | undefined,
    isError: boolean,
    command: string | undefined,
  ): string | null {
    if (!this.enabled || this.corrections >= MAX_CORRECTIONS) return null;

    // Track consecutive errors
    if (isError) {
      this.consecutiveErrors++;
    } else {
      this.consecutiveErrors = 0;
    }

    // Track per-file edits
    if (filePath && IMPLEMENTATION_TOOLS.has(toolName)) {
      const count = (this.editCounts.get(filePath) ?? 0) + 1;
      this.editCounts.set(filePath, count);

      if (count >= EDIT_LOOP_THRESHOLD) {
        this.corrections++;
        this.editCounts.set(filePath, 0); // reset to avoid re-firing
        return `You have edited ${filePath} ${count} times. Step back and reconsider your approach — are you stuck in a loop? If the current strategy isn't working, try a different approach or break the problem into smaller steps.`;
      }
    }

    // Track repeated commands (first 40 chars as key)
    if (toolName === "Bash" && command) {
      const key = command.slice(0, COMMAND_PREFIX_LENGTH);
      const count = (this.commandCounts.get(key) ?? 0) + 1;
      this.commandCounts.set(key, count);

      if (count >= COMMAND_REPEAT_THRESHOLD) {
        this.corrections++;
        this.commandCounts.set(key, 0);
        return `You have run a similar command "${key}..." ${count} times. The command may be failing or producing unexpected results. Read the output carefully and try a different approach.`;
      }
    }

    // Consecutive error streak
    if (this.consecutiveErrors >= ERROR_STREAK_THRESHOLD) {
      this.corrections++;
      const streak = this.consecutiveErrors;
      this.consecutiveErrors = 0;
      return `You have encountered ${streak} consecutive errors. Stop and reassess: read the error messages carefully, check your assumptions, and try a fundamentally different approach rather than retrying the same thing.`;
    }

    return null;
  }

  /** Resets all internal state so the corrector can be reused for a new phase. */
  reset(): void {
    this.corrections = 0;
    this.editCounts.clear();
    this.commandCounts.clear();
    this.consecutiveErrors = 0;
  }

  correctionCount(): number { return this.corrections; }

  /** Returns a summary of the course corrector's current state. */
  summary(): CourseCorrectorSummary {
    return {
      corrections: this.corrections,
      maxCorrections: MAX_CORRECTIONS,
      capped: this.corrections >= MAX_CORRECTIONS,
      trackedFiles: this.editCounts.size,
      trackedCommands: this.commandCounts.size,
    };
  }
}

// ---------------------------------------------------------------------------
// Phase tool counter
// ---------------------------------------------------------------------------

/** Soft warning threshold — phase is getting long but still within budget. */
export const PHASE_TOOL_COUNT_WARN = 50;
/** Hard limit threshold — phase should wrap up. */
export const PHASE_TOOL_COUNT_LIMIT = 200;

/** Status derived from tool count vs thresholds. */
export type PhaseToolCountStatus = "ok" | "warn" | "limit";

/** Summary snapshot returned by PhaseToolCounter.summary(). */
export interface PhaseToolCounterSummary {
  count: number;
  warnThreshold: number;
  limitThreshold: number;
  status: PhaseToolCountStatus;
}

/**
 * Tracks total tool calls within a phase for budget awareness.
 * Provides soft warning at PHASE_TOOL_COUNT_WARN and hard limit at
 * PHASE_TOOL_COUNT_LIMIT so the orchestrator can nudge or halt the agent.
 */
export class PhaseToolCounter {
  private count = 0;

  /** Increment the counter. Returns the new count. */
  onToolCall(): number {
    return ++this.count;
  }

  /** Current tool call count. */
  getCount(): number {
    return this.count;
  }

  /** Derive status from current count vs thresholds. */
  status(): PhaseToolCountStatus {
    if (this.count >= PHASE_TOOL_COUNT_LIMIT) return "limit";
    if (this.count >= PHASE_TOOL_COUNT_WARN) return "warn";
    return "ok";
  }

  /** Resets the counter to zero for phase reuse. */
  reset(): void {
    this.count = 0;
  }

  /** Returns a summary of the tool counter's current state. */
  summary(): PhaseToolCounterSummary {
    return {
      count: this.count,
      warnThreshold: PHASE_TOOL_COUNT_WARN,
      limitThreshold: PHASE_TOOL_COUNT_LIMIT,
      status: this.status(),
    };
  }
}

// ---------------------------------------------------------------------------
// Aggregate phase intelligence summary
// ---------------------------------------------------------------------------

/** Combined summary of all phase intelligence trackers. */
export interface PhaseIntelligenceSummary {
  version: string;
  timer: PhaseTimerSummary;
  downshift: ModelDownshiftSummary;
  courseCorrector: CourseCorrectorSummary;
  toolCount: PhaseToolCounterSummary;
}

/**
 * Produces an aggregate summary from all four phase intelligence trackers.
 * Used at phase completion to emit a single structured event.
 */
export function summarizePhaseIntelligence(
  timer: PhaseTimer,
  downshift: ModelDownshiftTracker,
  courseCorrector: CourseCorrector,
  toolCounter: PhaseToolCounter,
  now?: number,
): PhaseIntelligenceSummary {
  return {
    version: VERSION,
    timer: timer.summary(now),
    downshift: downshift.summary(),
    courseCorrector: courseCorrector.summary(),
    toolCount: toolCounter.summary(),
  };
}
