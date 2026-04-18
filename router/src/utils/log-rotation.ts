/**
 * JSONL log rotation with daily file naming and configurable retention.
 *
 * Provides:
 * - Daily log files: `{base}-YYYY-MM-DD.jsonl`
 * - Automatic cleanup of files older than retention period
 * - Symlink-free: current log path stays the same, rotation is transparent
 * - Safe to call from hooks and servers (sync operations)
 */

import {
  existsSync,
  readdirSync,
  renameSync,
  unlinkSync,
  statSync,
  appendFileSync,
  mkdirSync,
} from "node:fs";
import { join, basename, dirname } from "node:path";
import { toDateString } from "./date-utils.js";

/** Default retention: 30 days of log files. */
const DEFAULT_RETENTION_DAYS = 30;

/** Maximum size before mid-day rotation (50 MB). */
const MAX_FILE_BYTES = 50 * 1024 * 1024;

/**
 * Get the current daily log file path for a base log name.
 * E.g., `cost-events.jsonl` → `cost-events-2025-01-15.jsonl`
 */
export function dailyLogPath(basePath: string): string {
  const dir = dirname(basePath);
  const name = basename(basePath, ".jsonl");
  const date = toDateString();
  return join(dir, `${name}-${date}.jsonl`);
}

/**
 * Rotate a JSONL log file if needed.
 *
 * Checks the main log file:
 * 1. If it exists and was created on a previous day, rename it to dated format
 * 2. If it exists and exceeds MAX_FILE_BYTES, rename it with hour suffix
 * 3. Clean up files older than `retentionDays`
 *
 * @returns The path to use for appending (always the main basePath)
 */
export function rotateIfNeeded(
  basePath: string,
  retentionDays = DEFAULT_RETENTION_DAYS,
): void {
  const dir = dirname(basePath);
  mkdirSync(dir, { recursive: true });

  if (existsSync(basePath)) {
    try {
      const st = statSync(basePath);
      const fileDate = toDateString(new Date(st.mtimeMs));
      const today = toDateString();

      if (fileDate !== today) {
        // Rotate yesterday's log to dated format
        const name = basename(basePath, ".jsonl");
        const archivePath = join(dir, `${name}-${fileDate}.jsonl`);
        try {
          renameSync(basePath, archivePath);
        } catch { /* another process may have already rotated */ }
      } else if (st.size > MAX_FILE_BYTES) {
        // Mid-day size rotation
        const hour = new Date().toISOString().slice(11, 13);
        const name = basename(basePath, ".jsonl");
        const archivePath = join(dir, `${name}-${today}-${hour}.jsonl`);
        try {
          renameSync(basePath, archivePath);
        } catch { /* ignore race */ }
      }
    } catch { /* stat failed, file may have been removed */ }
  }

  // Purge old log files beyond retention period
  purgeOldLogs(dir, basePath, retentionDays);
}

/**
 * Remove log files older than retention period.
 * Only removes files matching the base log name pattern.
 */
function purgeOldLogs(
  dir: string,
  basePath: string,
  retentionDays: number,
): void {
  const name = basename(basePath, ".jsonl");
  const cutoffMs = Date.now() - retentionDays * 86_400_000;
  const pattern = new RegExp(`^${escapeRegex(name)}-\\d{4}-\\d{2}-\\d{2}`);

  try {
    const files = readdirSync(dir);
    for (const file of files) {
      if (!pattern.test(file)) continue;

      const filePath = join(dir, file);
      try {
        const st = statSync(filePath);
        if (st.mtimeMs < cutoffMs) {
          unlinkSync(filePath);
        }
      } catch { /* skip files we can't stat/delete */ }
    }
  } catch { /* dir may not exist yet */ }
}

/** Escape special regex characters in a string. */
function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Append a line to a JSONL log file with automatic rotation.
 * Creates the directory if it doesn't exist.
 * Rotates the file if it's from a previous day or exceeds size limit.
 */
export function appendJsonlRotated(
  basePath: string,
  line: string,
  retentionDays = DEFAULT_RETENTION_DAYS,
): void {
  rotateIfNeeded(basePath, retentionDays);
  appendFileSync(basePath, line.endsWith("\n") ? line : line + "\n");
}
