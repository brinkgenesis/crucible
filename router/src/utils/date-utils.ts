/**
 * Lightweight date/time formatting helpers to eliminate scattered
 * `.toISOString().slice(0, 10)` patterns across the codebase.
 */

/** YYYY-MM-DD from a Date (defaults to now). */
export function toDateString(date: Date = new Date()): string {
  return date.toISOString().slice(0, 10);
}

/** HH:mm from a Date (defaults to now). */
export function toTimeString(date: Date = new Date()): string {
  return date.toISOString().slice(11, 16);
}

/** Full ISO 8601 timestamp (defaults to now). */
export function nowIso(): string {
  return new Date().toISOString();
}
