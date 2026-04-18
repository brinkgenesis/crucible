/**
 * Structured Audit Logger — JSONL event log for all tool calls.
 *
 * Records: timestamp, agent, tool, args (redacted), result status,
 * duration, and any safety warnings.
 */

import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { appendJsonlRotated } from "../utils/log-rotation.js";
import { createLogger } from "../utils/logger.js";
import { extractErrorMessage } from "../utils/error.js";

const logger = createLogger("audit-logger");

// --- Types ---

export interface AuditEvent {
  timestamp: string;
  project: string;
  agent: string | null;
  tool: string;
  args: Record<string, unknown>;
  status: "success" | "error" | "denied";
  durationMs: number;
  error?: string;
  safetyWarnings?: string[];
}

export interface AuditLoggerOptions {
  /** Directory for audit log files (default: .claude-flow/logs/) */
  logDir: string;
  /** Filename (default: audit.jsonl) */
  filename: string;
  /** Project name for attribution (default: from INFRA_PROJECT env or "unknown") */
  project: string;
  /** Redact argument values for these keys (default: content, prompt) */
  redactKeys: string[];
  /** Max length of redacted preview (default: 100) */
  redactPreviewLength: number;
}

// --- Defaults ---

const DEFAULT_OPTIONS: AuditLoggerOptions = {
  logDir: join(process.cwd(), ".claude-flow", "logs"),
  filename: "audit.jsonl",
  project: process.env.INFRA_PROJECT ?? "unknown",
  redactKeys: ["content", "prompt", "code"],
  redactPreviewLength: 100,
};

// --- Redaction ---

/**
 * Redact sensitive argument values while preserving structure.
 */
export function redactArgs(
  args: Record<string, unknown>,
  redactKeys: string[],
  previewLength: number,
): Record<string, unknown> {
  const result: Record<string, unknown> = {};

  for (const [key, value] of Object.entries(args)) {
    if (redactKeys.includes(key) && typeof value === "string") {
      result[key] = value.length > previewLength
        ? `${value.slice(0, previewLength)}...[${value.length} chars]`
        : value;
    } else {
      result[key] = value;
    }
  }

  return result;
}

// --- Audit Logger ---

export class AuditLogger {
  private opts: AuditLoggerOptions;
  private logPath: string;

  constructor(opts: Partial<AuditLoggerOptions> = {}) {
    this.opts = { ...DEFAULT_OPTIONS, ...opts };
    this.logPath = join(this.opts.logDir, this.opts.filename);
    mkdirSync(this.opts.logDir, { recursive: true });
  }

  /**
   * Log a tool call event.
   */
  log(event: Omit<AuditEvent, "timestamp" | "project" | "args"> & { args: Record<string, unknown> }): void {
    const entry: AuditEvent = {
      timestamp: new Date().toISOString(),
      project: this.opts.project,
      agent: event.agent,
      tool: event.tool,
      args: redactArgs(event.args, this.opts.redactKeys, this.opts.redactPreviewLength),
      status: event.status,
      durationMs: event.durationMs,
      error: event.error,
      safetyWarnings: event.safetyWarnings,
    };

    try {
      appendJsonlRotated(this.logPath, JSON.stringify(entry));
    } catch (e) {
      // Don't let audit logging failures crash the MCP server
      logger.warn(`[audit-logger.log] failed to write audit event: ${entry.tool} ${extractErrorMessage(e)}`);
    }
  }

  /**
   * Create a timer for measuring tool call duration.
   */
  startTimer(): () => number {
    const start = Date.now();
    return () => Date.now() - start;
  }

  /** Get the log file path (for diagnostics). */
  getLogPath(): string {
    return this.logPath;
  }
}
