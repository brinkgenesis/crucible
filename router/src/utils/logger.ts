/**
 * Structured logger built on pino.
 *
 * Usage:
 *   import { createLogger } from "./utils/logger.js";
 *   const log = createLogger("executor");
 *   log.info({ runId, cardId }, "Driving run");
 *   log.warn({ runId, retryCount }, "Retry cap exceeded");
 *   log.error({ err }, "Phase pickup failed");
 *
 * Creates child loggers with a `module` field for easy filtering:
 *   {"level":30,"time":1708462800,"module":"executor","runId":"abc","msg":"Driving run"}
 *
 * In development (NODE_ENV !== "production"), uses pino's pretty-print transport
 * for human-readable output. In production, outputs newline-delimited JSON.
 */

import pino from "pino";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { extractErrorMessage } from "./error.js";

const isDev = process.env.NODE_ENV !== "production";
const isDashboardApiProcess = process.argv.some((arg) => arg.includes("dashboard/api/server"));

function buildStreams(): pino.StreamEntry[] {
  const streams: pino.StreamEntry[] = [{ stream: process.stdout }];
  if (!isDashboardApiProcess) return streams;

  const infraHome = process.env.INFRA_HOME ?? process.cwd();
  const filePath = join(infraHome, ".claude-flow", "logs", "dashboard-api.log");
  try {
    mkdirSync(dirname(filePath), { recursive: true });
    streams.push({
      stream: pino.destination({
        dest: filePath,
        sync: false,
      }),
    });
  } catch (e) {
    // Keep stdout logging even if file stream setup fails.
    console.warn("[logger.buildStreams] file stream setup failed:", extractErrorMessage(e));
  }
  return streams;
}

const root = pino({
  level: process.env.LOG_LEVEL ?? (isDev ? "debug" : "info"),
  formatters: {
    level: (label: string) => ({ level: label }),
  },
}, pino.multistream(buildStreams()));

/**
 * Create a child logger scoped to a module.
 *
 * @param module - Short module name (e.g. "executor", "kanban", "server")
 * @param bindings - Optional extra fields to bind to every log line
 */
export function createLogger(
  module: string,
  bindings?: Record<string, unknown>,
): pino.Logger {
  return root.child({ module, ...bindings });
}

/** The root pino instance — prefer createLogger() for module-scoped logging. */
export { root as rootLogger };
