// Minimal logger shim for the bridge. Mimics the subset of the infra pino
// wrapper's API that sibling modules (sdk-agent-builder, etc.) use. Real
// events go to stdout via the bridge protocol; this logger is diagnostics
// only and writes to stderr.

type LogArg = string | Record<string, unknown>;

function write(level: string, module: string, arg1: LogArg, arg2?: LogArg) {
  const parts: string[] = [`[${module}]`, level];
  for (const arg of [arg1, arg2]) {
    if (arg === undefined) continue;
    if (typeof arg === "string") parts.push(arg);
    else parts.push(JSON.stringify(arg));
  }
  console.error(parts.join(" "));
}

export function createLogger(module: string) {
  return {
    info: (a: LogArg, b?: LogArg) => write("INFO", module, a, b),
    warn: (a: LogArg, b?: LogArg) => write("WARN", module, a, b),
    error: (a: LogArg, b?: LogArg) => write("ERROR", module, a, b),
    debug: (a: LogArg, b?: LogArg) => {
      if (process.env.BRIDGE_DEBUG === "1") write("DEBUG", module, a, b);
    },
  };
}
