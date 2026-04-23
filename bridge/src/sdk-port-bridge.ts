#!/usr/bin/env npx tsx
// @ts-nocheck — TODO: reconcile with @anthropic-ai/claude-agent-sdk types
/**
 * SDK Port Bridge — bidirectional stdin/stdout JSON protocol for Erlang Port.
 *
 * Reads config + follow-up messages from stdin, calls SDK query(),
 * streams events as newline-delimited JSON to stdout.
 *
 * Protocol:
 *   stdin  → {"type":"start","prompt":"...","options":{...},...}
 *   stdin  → {"type":"message","content":"follow-up instruction"}  (optional, future)
 *   stdin  → {"type":"interrupt"}                                   (optional)
 *   stdout ← {"type":"tool_use","tool":"Read","file_path":"...","duration_ms":45}
 *   stdout ← {"type":"api_retry","attempt":1,"max_retries":3,...}
 *   stdout ← {"type":"rate_limit","status":"allowed_warning",...}
 *   stdout ← {"type":"context_usage","percentage":72,...}
 *   stdout ← {"type":"result","subtype":"success","cost_usd":0.42,...}
 */

import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { appendFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { query as sdkQuery } from "@anthropic-ai/claude-agent-sdk";
import type {
  Query as SDKQuery,
  SDKMessage,
  SDKResultMessage,
  SDKRateLimitEvent,
  SDKUserMessage,
  Options,
} from "@anthropic-ai/claude-agent-sdk";
import { selectModelForApiPhase } from "./sdk-utils/strategy.js";
import { buildAgentDefinitions, buildSdkTeamOrchestratorPrompt } from "./sdk-utils/sdk-agent-builder.js";
import { resolvePermissions } from "./sdk-utils/permissions.js";
import { ModelDownshiftTracker, CourseCorrector, DOWNSHIFT_MODEL } from "./sdk-utils/sdk-phase-intelligence.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function emit(obj: Record<string, unknown>): void {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function resolveEffort(routingProfile?: string): Options["effort"] {
  switch (routingProfile) {
    case "deep-reasoning": return "high";
    case "scout": return "low";
    case "verification": return "high";
    default: return "medium";
  }
}

function resolveThinking(routingProfile?: string): Options["thinking"] {
  switch (routingProfile) {
    case "deep-reasoning": return { type: "enabled", budgetTokens: 10000 };
    case "verification": return { type: "adaptive" };
    case "scout": return { type: "adaptive" };
    default: return { type: "adaptive" };
  }
}

function resolveModel(routingProfile?: string): string {
  const { model } = selectModelForApiPhase(routingProfile ?? "throughput");
  return model;
}

function resolveFallbackModel(primaryModel: string): string {
  if (primaryModel.includes("opus")) return "sonnet";
  if (primaryModel.includes("sonnet")) return "haiku";
  return "haiku";
}

// ---------------------------------------------------------------------------
// Config type from stdin
// ---------------------------------------------------------------------------

interface PortConfig {
  type: "start";
  prompt: string;
  runId: string;
  phaseId: string;
  cardId?: string;
  infraHome: string;
  repoRoot?: string; // Main repo root for log paths (infraHome may be a worktree)
  phaseType: string;
  phaseName: string;
  routingProfile?: string;
  agents?: string[];
  timeoutMs?: number;
  budgetUsd?: number;
  maxTurns?: number;
  resumeSessionId?: string; // Resume a prior session (cross-phase resume)
  attemptId?: string; // Idempotency key for cost events (retry dedup)
  // Full run/phase objects for agent builder
  run?: Record<string, unknown>;
  phase?: Record<string, unknown>;
}

/** Messages Elixir can send after start. */
type StdinMessage =
  | { type: "interrupt" }
  | { type: "message"; content: string }
  | { type: "set_model"; model: string }
  | { type: "set_permission_mode"; mode: string };

// ---------------------------------------------------------------------------
// Async queue — bridges stdin messages to SDK's AsyncIterable<SDKUserMessage>
// ---------------------------------------------------------------------------

/**
 * Simple async queue implementing AsyncIterable. Push items from one async
 * context, consume them from another via `for await...of`.
 */
class AsyncQueue<T> implements AsyncIterable<T> {
  private queue: T[] = [];
  private waiting: ((value: IteratorResult<T>) => void) | null = null;
  private done = false;

  push(item: T): void {
    if (this.done) return;
    // Always enqueue first to preserve ordering, then wake the consumer.
    this.queue.push(item);
    if (this.waiting) {
      const w = this.waiting;
      this.waiting = null;
      w({ value: this.queue.shift()!, done: false });
    }
  }

  close(): void {
    this.done = true;
    if (this.waiting) {
      const w = this.waiting;
      this.waiting = null;
      w({ value: undefined as unknown as T, done: true });
    }
  }

  get length(): number { return this.queue.length; }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: (): Promise<IteratorResult<T>> => {
        if (this.queue.length > 0) {
          return Promise.resolve({ value: this.queue.shift()!, done: false });
        }
        if (this.done) {
          return Promise.resolve({ value: undefined as unknown as T, done: true });
        }
        return new Promise((resolve) => { this.waiting = resolve; });
      },
    };
  }
}

// ---------------------------------------------------------------------------
// Bidirectional stdin reader
// ---------------------------------------------------------------------------

/**
 * Reads stdin as an async line stream. Yields the initial config, then
 * continues reading follow-up messages until stdin closes.
 * The stream reference is held so follow-up messages can trigger side-effects
 * (interrupt, future multi-turn messages) while the SDK query runs.
 */
function createStdinReader() {
  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const iterator = rl[Symbol.asyncIterator]();
  let closed = false;

  rl.on("close", () => { closed = true; });

  return {
    /** Read the first line (config). */
    async readConfig(): Promise<string | undefined> {
      const result = await iterator.next();
      return result.done ? undefined : result.value;
    },
    /** Continuously read follow-up messages. Calls handler for each. */
    async pumpMessages(handler: (msg: StdinMessage) => void): Promise<void> {
      while (!closed) {
        const result = await iterator.next();
        if (result.done) break;
        try {
          const msg = JSON.parse(result.value) as StdinMessage;
          handler(msg);
        } catch { /* ignore malformed lines */ }
      }
    },
    close() { rl.close(); },
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const stdin = createStdinReader();

  // Read exactly one config line
  const configLine = await stdin.readConfig();
  if (!configLine) {
    emit({ type: "error", message: "No config received on stdin" });
    process.exit(1);
  }

  let config: PortConfig;
  try {
    config = JSON.parse(configLine) as PortConfig;
  } catch (err) {
    emit({ type: "error", message: `Invalid JSON config: ${err}` });
    process.exit(1);
  }

  if (config.type !== "start") {
    emit({ type: "error", message: `Expected type "start", got "${config.type}"` });
    process.exit(1);
  }

  // Signal to Elixir that config was parsed successfully — Elixir defers
  // its timeout timer until it receives this, avoiding false timeouts when
  // Node is slow to boot.
  emit({ type: "ready" });

  // Idempotency key — unique per execution attempt so retries don't double-count cost
  const attemptId = config.attemptId ?? randomUUID();

  // Resolve SDK options (matching claude-agent-sdk.ts adapter)
  const model = resolveModel(config.routingProfile);
  const fallbackModel = resolveFallbackModel(model);
  const phaseStub = {
    type: config.phaseType,
    routingProfile: config.routingProfile ?? "throughput",
  } as Parameters<typeof resolvePermissions>[0];
  const {
    permissionMode,
    disallowedTools,
    allowDangerouslySkipPermissions,
    canUseTool,
  } = resolvePermissions(phaseStub);
  const effort = resolveEffort(config.routingProfile);
  const thinking = resolveThinking(config.routingProfile);
  const budgetUsd = config.budgetUsd ?? (config.phaseType === "team" ? 10 : 5);
  // PR shepherd polls CI in a loop — needs more turns than coding phases
  const defaultMaxTurns = config.phaseType === "pr-shepherd" ? 60 : 30;
  const maxTurns = config.maxTurns ?? defaultMaxTurns;

  // Grant access to main repo root when running in a worktree
  const repoRoot = config.repoRoot ?? config.infraHome;
  const additionalDirs: string[] = [];
  if (repoRoot !== config.infraHome) additionalDirs.push(repoRoot);
  additionalDirs.push(join(homedir(), ".claude"));

  // Build phase-specific system prompt (preserves CC's default prompt)
  const phaseSystemContext = [
    `You are executing workflow phase "${config.phaseName}" (type: ${config.phaseType}).`,
    `Run ID: ${config.runId}.${config.cardId ? ` Card: ${config.cardId}.` : ""}`,
    config.routingProfile ? `Routing profile: ${config.routingProfile}.` : "",
  ].filter(Boolean).join(" ");

  const options: Options = {
    cwd: config.infraHome,
    model,
    fallbackModel,
    permissionMode,
    ...(disallowedTools ? { disallowedTools } : {}),
    ...(allowDangerouslySkipPermissions ? { allowDangerouslySkipPermissions } : {}),
    ...(canUseTool ? { canUseTool } : {}),
    effort,
    thinking,
    ...(additionalDirs.length > 0 ? { additionalDirectories: additionalDirs } : {}),
    maxTurns,
    maxBudgetUsd: budgetUsd,
    settingSources: ["project"],
    enableFileCheckpointing: true,
    ...(config.resumeSessionId ? { resume: config.resumeSessionId } : {}),
    systemPrompt: {
      type: "preset" as const,
      preset: "claude_code" as const,
      append: phaseSystemContext,
    },
    env: {
      ...process.env as Record<string, string>,
      CLAUDE_PROJECT_DIR: config.infraHome,
      CLAUDE_AGENT_SDK_CLIENT_APP: "infra-workflow/0.1.0",
    },
  };

  // Build agent definitions for team phases
  let effectivePrompt = config.prompt;
  if (config.phaseType === "team" && config.agents?.length && config.run && config.phase) {
    try {
      const agentDefs = buildAgentDefinitions(
        config.infraHome,
        config.agents,
        config.prompt,
        config.run as never,
        config.phase as never,
      );
      if (Object.keys(agentDefs).length > 0) {
        options.agents = agentDefs;
        effectivePrompt = buildSdkTeamOrchestratorPrompt(
          config.run as never,
          config.phase as never,
          agentDefs,
        );
        emit({ type: "agents_configured", agents: Object.keys(agentDefs) });
      }
    } catch (err) {
      emit({ type: "warning", message: `Agent build failed, using prompt orchestration: ${err}` });
    }
  }

  // Log paths — always write to the main repo root, not the worktree
  const logRoot = config.repoRoot ?? config.infraHome;
  const logsDir = join(logRoot, ".claude-flow", "logs");
  const tracesDir = join(logsDir, "traces");
  mkdirSync(tracesDir, { recursive: true });
  const costLogPath = join(logsDir, "cost-events.jsonl");
  const mcpToolsLogPath = join(tracesDir, "mcp-tools.jsonl");
  const lifecycleLogPath = join(logsDir, "agent-lifecycle.jsonl");

  // Track tool calls for result summary
  const editedFiles = new Set<string>();
  const createdFiles = new Set<string>();
  let toolCallCount = 0;
  let permissionDenials = 0;

  // Model downshift + course correction trackers
  const downshiftTracker = new ModelDownshiftTracker(config.phaseType);
  const courseCorrector = new CourseCorrector(config.phaseType);
  /** Deferred actions from hook (pushed after hook returns to avoid blocking). */
  const pendingActions: Array<() => void> = [];

  options.hooks = {
    PostToolUse: [{
      hooks: [async (hookInput: Record<string, unknown>) => {
        const toolName = typeof hookInput.tool_name === "string" ? hookInput.tool_name : "unknown";
        const wasDenied = hookInput.was_denied === true;
        const isError = hookInput.is_error === true;
        const durationMs = typeof hookInput.duration_ms === "number" ? hookInput.duration_ms : undefined;

        const toolInput = hookInput.tool_input as Record<string, unknown> | undefined;
        const filePath = typeof hookInput.file_path === "string" ? hookInput.file_path
          : typeof toolInput?.file_path === "string" ? toolInput.file_path
          : typeof toolInput?.path === "string" ? toolInput.path
          : undefined;

        toolCallCount++;
        if (wasDenied) permissionDenials++;

        if (filePath && typeof filePath === "string" && !filePath.includes(" ")) {
          if (toolName === "Edit" || toolName === "edit_file") editedFiles.add(filePath);
          if (toolName === "Write" || toolName === "write_file") createdFiles.add(filePath);
        }

        // Emit to stdout for Elixir SdkPort streaming
        emit({
          type: "tool_use",
          tool: toolName,
          ...(filePath ? { file_path: filePath } : {}),
          duration_ms: durationMs ?? null,
          is_error: isError,
          was_denied: wasDenied,
        });

        // Emit cost event via stdout for Elixir CostEventWriter
        emit({ type: "cost_event", payload: {
          timestamp: new Date().toISOString(),
          tool: toolName,
          runId: config.runId,
          phase: config.phaseName,
          cardId: config.cardId,
          attemptId,
          adapter: "sdk_port",
          executionType: "sdk",
          durationMs: durationMs ?? null,
          isError,
          wasDenied,
          ...(filePath ? { filePath } : {}),
        }});

        // Emit trace event for MCP tools via stdout for Elixir TraceEventWriter
        emit({ type: "trace_event", payload: {
          timestamp: new Date().toISOString(),
          traceId: config.runId,
          eventType: "mcp_tool_call",
          tool: toolName,
          metadata: {
            status: isError ? "error" : wasDenied ? "denied" : "success",
            durationMs: durationMs ?? 0,
            args: filePath ? { file_path: filePath } : {},
            adapter: "sdk_port",
            runId: config.runId,
            phase: config.phaseName,
          },
        }});

        // Legacy file writes — kept behind env flag for rollback
        if (process.env.LEGACY_COST_WRITE === "1") {
          try {
            appendFileSync(costLogPath, JSON.stringify({
              timestamp: new Date().toISOString(), tool: toolName, runId: config.runId,
              phase: config.phaseName, cardId: config.cardId, attemptId,
              adapter: "sdk_port", executionType: "sdk",
              durationMs: durationMs ?? null, isError, wasDenied,
              ...(filePath ? { filePath } : {}),
            }) + "\n");
          } catch { /* legacy fallback */ }
          try {
            appendFileSync(mcpToolsLogPath, JSON.stringify({
              timestamp: new Date().toISOString(), traceId: config.runId,
              eventType: "mcp_tool_call", tool: toolName,
              metadata: { status: isError ? "error" : wasDenied ? "denied" : "success",
                durationMs: durationMs ?? 0, adapter: "sdk_port",
                runId: config.runId, phase: config.phaseName },
            }) + "\n");
          } catch { /* legacy fallback */ }
        }

        // Model downshift: check if we should switch to a cheaper model.
        // Deferred to avoid calling setModel inside the hook synchronously.
        const downshiftTo = downshiftTracker.onToolCall(toolName);
        if (downshiftTo) {
          pendingActions.push(() => {
            stream.setModel(downshiftTo).then(
              () => emit({ type: "model_downshift", from: model, to: downshiftTo, at_tool_call: toolCallCount }),
              () => {
                // Retry once after 1s — setModel can fail if the stream is mid-response
                setTimeout(() => {
                  stream.setModel(downshiftTo).then(
                    () => emit({ type: "model_downshift", from: model, to: downshiftTo, at_tool_call: toolCallCount, retry: true }),
                    () => emit({ type: "warning", message: `setModel(${downshiftTo}) failed after retry — continuing on ${model}` }),
                  );
                }, 1000);
              },
            );
          });
        }

        // Course correction: check for loops/drift patterns.
        const commandStr = typeof toolInput?.command === "string" ? toolInput.command : undefined;
        const correction = courseCorrector.onToolCall(toolName, filePath, isError, commandStr);
        if (correction) {
          pendingActions.push(() => {
            inputChannel.push({
              type: "user",
              message: { role: "user", content: correction },
              parent_tool_use_id: null,
              session_id: "",
            } as SDKUserMessage);
            emit({ type: "course_correction", message: correction, correction_number: courseCorrector.correctionCount() });
          });
        }

        return { async: true } as Record<string, unknown>;
      }],
    }],
  };

  // Emit agent lifecycle events for dashboard AGENTS tab
  if (options.agents) {
    for (const [role, def] of Object.entries(options.agents)) {
      try {
        appendFileSync(lifecycleLogPath, JSON.stringify({
          timestamp: new Date().toISOString(),
          event: "agent_spawned",
          agent_id: `${config.runId}-${role}`,
          agent_type: role,
          teammate_name: role,
          run_id: config.runId,
          phase: config.phaseName,
          model: (def as Record<string, unknown>).model ?? "sonnet",
          adapter: "sdk_port",
        }) + "\n");
      } catch { /* non-critical */ }
    }
  }

  // ---------------------------------------------------------------------------
  // Multi-turn input channel: AsyncIterable<SDKUserMessage> prompt
  // ---------------------------------------------------------------------------
  // Instead of passing a string prompt, we pass an async iterable.
  // The first item is the initial prompt; follow-up stdin messages of type
  // "message" become additional user turns. This unlocks mid-phase control
  // methods (setModel, setPermissionMode) on the returned Query object.
  const inputChannel = new AsyncQueue<SDKUserMessage>();

  // Push initial prompt as first user message
  inputChannel.push({
    type: "user",
    message: { role: "user", content: effectivePrompt },
    parent_tool_use_id: null,
    session_id: "",
  } as SDKUserMessage);

  // Two-stage timeout: graceful interrupt at 90%, hard abort at 100%
  const abortController = new AbortController();
  options.abortController = abortController;
  const timeoutMs = config.timeoutMs ?? 300_000;
  const stream: SDKQuery = sdkQuery({ prompt: inputChannel, options });

  const interruptTimeoutId = setTimeout(async () => {
    try { await stream.interrupt(); } catch { /* stream may already be done */ }
  }, Math.floor(timeoutMs * 0.9));
  const abortTimeoutId = setTimeout(() => abortController.abort(), timeoutMs);

  // Start bidirectional stdin pump — handle interrupt, messages, and control
  // requests from Elixir. Runs concurrently with SDK stream iteration below.
  const stdinPump = stdin.pumpMessages((msg) => {
    if (msg.type === "interrupt") {
      stream.interrupt().catch(() => {});
    } else if (msg.type === "message" && "content" in msg) {
      // Inject follow-up user message into the conversation
      inputChannel.push({
        type: "user",
        message: { role: "user", content: msg.content },
        parent_tool_use_id: null,
        session_id: "",
      } as SDKUserMessage);
    } else if (msg.type === "set_model" && "model" in msg) {
      stream.setModel(msg.model).catch(() => {});
    } else if (msg.type === "set_permission_mode" && "mode" in msg) {
      stream.setPermissionMode(msg.mode as Options["permissionMode"] & string).catch(() => {});
    }
  });

  try {
    let resultMsg: SDKResultMessage | undefined;
    let sessionId: string | undefined;
    let lastRateLimitStatus: string | undefined;

    for await (const msg of stream as AsyncIterable<SDKMessage>) {
      // Drain any deferred actions from PostToolUse hook
      while (pendingActions.length > 0) {
        const action = pendingActions.shift();
        if (action) action();
      }

      // Capture session ID from any message
      if ("session_id" in msg && typeof msg.session_id === "string" && !sessionId) {
        sessionId = msg.session_id;
      }

      if (msg.type === "result") {
        resultMsg = msg as SDKResultMessage;
        if (msg.session_id) sessionId = msg.session_id;
        // Close the input channel so the SDK stream finishes
        inputChannel.close();
        continue;
      }

      // API retry events
      if (msg.type === "system" && "subtype" in msg && msg.subtype === "api_retry") {
        const retry = msg as { attempt: number; max_retries: number; retry_delay_ms: number; error_status: number | null; error: string };
        emit({
          type: "api_retry",
          attempt: retry.attempt,
          max_retries: retry.max_retries,
          retry_delay_ms: retry.retry_delay_ms,
          error_status: retry.error_status,
        });
        continue;
      }

      // Rate limit events (Max subscription)
      if (msg.type === "rate_limit_event") {
        const rl = (msg as SDKRateLimitEvent).rate_limit_info;
        lastRateLimitStatus = rl.status;
        emit({
          type: "rate_limit",
          status: rl.status,
          rate_limit_type: rl.rateLimitType ?? null,
          utilization: rl.utilization ?? null,
          resets_at: rl.resetsAt ?? null,
          is_overage: rl.isUsingOverage ?? false,
        });
        continue;
      }

      // Subagent lifecycle events
      if (msg.type === "system" && "subtype" in msg) {
        const sub = msg as { subtype: string; task_id?: string; description?: string; summary?: string; status?: string; usage?: { total_tokens: number; tool_uses: number; duration_ms: number }; last_tool_name?: string };
        if (sub.subtype === "task_started" || sub.subtype === "task_progress" || sub.subtype === "task_notification") {
          emit({
            type: "subagent_event",
            subtype: sub.subtype,
            task_id: sub.task_id,
            ...(sub.description ? { description: sub.description } : {}),
            ...(sub.summary ? { summary: sub.summary } : {}),
            ...(sub.status ? { status: sub.status } : {}),
            ...(sub.usage ? { tokens: sub.usage.total_tokens, tool_uses: sub.usage.tool_uses, duration_ms: sub.usage.duration_ms } : {}),
          });

          // Also write to lifecycle log
          try {
            appendFileSync(lifecycleLogPath, JSON.stringify({
              timestamp: new Date().toISOString(),
              event: sub.subtype === "task_started" ? "subagent_started"
                : sub.subtype === "task_notification" ? "subagent_completed"
                : "subagent_progress",
              task_id: sub.task_id,
              run_id: config.runId,
              phase: config.phaseName,
              adapter: "sdk_port",
              ...(sub.status ? { status: sub.status } : {}),
              ...(sub.usage ? { tokens: sub.usage.total_tokens, tool_uses: sub.usage.tool_uses, duration_ms: sub.usage.duration_ms } : {}),
            }) + "\n");
          } catch { /* non-critical */ }
        }
      }
    }

    // Final drain — catch any actions pushed during the last stream message
    while (pendingActions.length > 0) {
      const action = pendingActions.shift();
      if (action) action();
    }

    clearTimeout(interruptTimeoutId);
    clearTimeout(abortTimeoutId);
    inputChannel.close();

    // Query context usage for observability
    let contextUsagePercent: number | undefined;
    try {
      const ctxUsage = await stream.getContextUsage();
      contextUsagePercent = ctxUsage.percentage;
      emit({
        type: "context_usage",
        percentage: ctxUsage.percentage,
        total_tokens: ctxUsage.totalTokens,
        max_tokens: ctxUsage.maxTokens,
        model: ctxUsage.model,
      });
    } catch { /* stream may have closed */ }

    // Emit session log path so the dashboard can read the transcript
    if (sessionId) {
      const slug = config.infraHome.replace(/\/+$/, "").replace(/\//g, "-");
      const logPath = join(homedir(), ".claude", "projects", slug, `${sessionId}.jsonl`);
      if (existsSync(logPath)) {
        emit({ type: "session_log", session_id: sessionId, path: logPath });
      }
    }

    const usage = resultMsg?.subtype === "success" ? resultMsg.usage : undefined;
    const costUsd = resultMsg?.subtype === "success" ? resultMsg.total_cost_usd : 0;
    const numTurns = resultMsg?.subtype === "success" ? resultMsg.num_turns : 0;

    emit({
      type: "result",
      subtype: resultMsg?.subtype ?? "unknown",
      model,
      attempt_id: attemptId,
      cost_usd: costUsd,
      turns: numTurns,
      session_id: sessionId ?? null,
      input_tokens: usage?.input_tokens ?? 0,
      output_tokens: usage?.output_tokens ?? 0,
      cache_read_tokens: usage?.cache_read_input_tokens ?? 0,
      tool_call_count: toolCallCount,
      files_modified: [...editedFiles],
      files_created: [...createdFiles],
      ...(contextUsagePercent !== undefined ? { context_usage_percent: contextUsagePercent } : {}),
      ...(lastRateLimitStatus ? { last_rate_limit_status: lastRateLimitStatus } : {}),
      ...(downshiftTracker.didDownshift() ? { model_downshifted: true, downshift_model: DOWNSHIFT_MODEL } : {}),
      ...(courseCorrector.correctionCount() > 0 ? { course_corrections: courseCorrector.correctionCount() } : {}),
      ...(sessionId ? { session_log_path: join(homedir(), ".claude", "projects", config.infraHome.replace(/\/+$/, "").replace(/\//g, "-"), `${sessionId}.jsonl`) } : {}),
    });

    // Emit phase_complete cost summary via stdout for Elixir
    const cacheRead = usage?.cache_read_input_tokens ?? 0;
    const inputTok = usage?.input_tokens ?? 0;
    emit({ type: "cost_event", payload: {
      timestamp: new Date().toISOString(),
      tool: "sdk_phase_complete",
      session: sessionId ?? config.runId,
      taskId: config.cardId,
      attemptId,
      modelId: model,
      costUsd,
      inputTokens: inputTok,
      outputTokens: usage?.output_tokens ?? 0,
      executionType: "sdk",
      adapter: "sdk_port",
      resultSubtype: resultMsg?.subtype ?? "unknown",
      permissionDenials,
      toolCallCount,
      cacheHitRate: (cacheRead + inputTok) > 0 ? cacheRead / (cacheRead + inputTok) : 0,
      ...(lastRateLimitStatus ? { lastRateLimitStatus } : {}),
      ...(contextUsagePercent !== undefined ? { contextUsagePercent } : {}),
    }});

    // Legacy file write for rollback
    if (process.env.LEGACY_COST_WRITE === "1") {
      try {
        appendFileSync(costLogPath, JSON.stringify({
          timestamp: new Date().toISOString(), tool: "sdk_phase_complete",
          session: sessionId ?? config.runId, taskId: config.cardId, attemptId,
          modelId: model, costUsd, inputTokens: inputTok,
          outputTokens: usage?.output_tokens ?? 0, executionType: "sdk",
          adapter: "sdk_port",
        }) + "\n");
      } catch { /* legacy fallback */ }
    }

    // Write agent completion lifecycle events
    if (options.agents) {
      for (const [role] of Object.entries(options.agents)) {
        try {
          appendFileSync(lifecycleLogPath, JSON.stringify({
            timestamp: new Date().toISOString(),
            event: "agent_completed",
            agent_id: `${config.runId}-${role}`,
            agent_type: role,
            teammate_name: role,
            run_id: config.runId,
            phase: config.phaseName,
            tool_count: toolCallCount,
            files_edited: [...editedFiles, ...createdFiles],
            adapter: "sdk_port",
          }) + "\n");
        } catch { /* non-critical */ }
      }
    }

    // Close stdin pump, then exit
    stdin.close();
    await stdinPump.catch(() => {});
    process.exit(resultMsg?.subtype === "success" ? 0 : 1);
  } catch (err) {
    clearTimeout(interruptTimeoutId);
    clearTimeout(abortTimeoutId);
    inputChannel.close();
    stdin.close();
    await stdinPump.catch(() => {});

    const message = err instanceof Error ? err.message : String(err);
    const isTimeout = message.includes("abort") || message.includes("timeout");

    emit({
      type: "result",
      subtype: isTimeout ? "timeout" : "error",
      model,
      attempt_id: attemptId,
      error: message,
      cost_usd: 0,
      turns: 0,
      session_id: null,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      tool_call_count: toolCallCount,
      files_modified: [...editedFiles],
      files_created: [...createdFiles],
    });

    process.exit(1);
  }
}

main().catch((err) => {
  emit({ type: "error", message: `Fatal: ${err}` });
  process.exit(1);
});
