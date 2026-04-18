/** Extract a message from an unknown error. Replaces 13 identical `err instanceof Error ? err.message : String(err)` patterns. */
export function extractErrorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
