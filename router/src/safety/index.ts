/**
 * Safety module — prompt injection detection + content sanitization.
 *
 * Provides regex-based pattern matching to detect prompt injection
 * attempts in content before it enters the memory vault or LLM context.
 */

// --- Types ---

export interface SafetyCheckResult {
  safe: boolean;
  threats: ThreatDetection[];
  sanitized: string;
}

export interface ThreatDetection {
  pattern: string;
  match: string;
  severity: "high" | "medium" | "low";
  location: number; // char offset
}

export interface SafetyConfig {
  /** Block storage when high-severity threat detected (default: false — warn only) */
  blockOnHighSeverity: boolean;
  /** Strip detected injection patterns from content (default: false) */
  sanitize: boolean;
  /** Max content length before flagging (default: 500_000 chars) */
  maxContentLength: number;
}

// --- Patterns ---

/** High severity — clear injection attempts */
const HIGH_SEVERITY_PATTERNS: Array<{ pattern: RegExp; name: string }> = [
  { pattern: /ignore\s+(all\s+)?previous\s+instructions/i, name: "ignore-instructions" },
  { pattern: /ignore\s+(all\s+)?above\s+instructions/i, name: "ignore-above" },
  { pattern: /disregard\s+(all\s+)?prior\s+(instructions|context)/i, name: "disregard-prior" },
  { pattern: /you\s+are\s+now\s+(a|an)\s+/i, name: "role-override" },
  { pattern: /new\s+system\s+prompt\s*:/i, name: "system-prompt-inject" },
  { pattern: /\[SYSTEM\]\s*:/i, name: "fake-system-tag" },
  { pattern: /\<\s*system\s*\>/i, name: "fake-system-xml" },
  { pattern: /act\s+as\s+if\s+you\s+(have\s+)?no\s+restrictions/i, name: "restriction-bypass" },
  { pattern: /override\s+safety\s+(filters|rules|guidelines)/i, name: "safety-override" },
];

/** Medium severity — suspicious but could be legitimate discussion */
const MEDIUM_SEVERITY_PATTERNS: Array<{ pattern: RegExp; name: string }> = [
  { pattern: /\bsudo\s+mode\b/i, name: "sudo-mode" },
  { pattern: /\bDAN\s+mode\b/i, name: "dan-mode" },
  { pattern: /\bjailbreak\b/i, name: "jailbreak-mention" },
  { pattern: /execute\s+the\s+following\s+commands?\s*:/i, name: "command-execution" },
  { pattern: /\bbase64\s+decode\b.*\bexecute\b/i, name: "encoded-execution" },
  { pattern: /pretend\s+(that\s+)?you\s+(are|have|can)/i, name: "pretend-instruction" },
];

/** Low severity — possible data exfiltration or social engineering */
const LOW_SEVERITY_PATTERNS: Array<{ pattern: RegExp; name: string }> = [
  { pattern: /send\s+(this|the)\s+(data|content|information)\s+to/i, name: "data-exfiltration" },
  { pattern: /forward\s+(all|this)\s+(to|via)\s+/i, name: "forward-attempt" },
  { pattern: /\bAPI[_\s]?key\s*[:=]/i, name: "api-key-in-content" },
  { pattern: /\b(sk-|ghp_|gho_|github_pat_)[a-zA-Z0-9]{20,}/i, name: "leaked-token" },
  { pattern: /password\s*[:=]\s*[^\s]+/i, name: "password-in-content" },
];

// --- Safety Checker ---

export const DEFAULT_SAFETY_CONFIG: SafetyConfig = {
  blockOnHighSeverity: false,
  sanitize: false,
  maxContentLength: 500_000,
};

/**
 * Scan content for prompt injection patterns.
 */
export function checkContent(
  content: string,
  config: Partial<SafetyConfig> = {},
): SafetyCheckResult {
  const cfg = { ...DEFAULT_SAFETY_CONFIG, ...config };
  const threats: ThreatDetection[] = [];

  // Length check
  if (content.length > cfg.maxContentLength) {
    threats.push({
      pattern: "max-content-length",
      match: `Content length ${content.length} exceeds max ${cfg.maxContentLength}`,
      severity: "medium",
      location: 0,
    });
  }

  // Scan all pattern sets in a single pass
  const PATTERN_TIERS: Array<{ patterns: typeof HIGH_SEVERITY_PATTERNS; severity: ThreatDetection["severity"] }> = [
    { patterns: HIGH_SEVERITY_PATTERNS, severity: "high" },
    { patterns: MEDIUM_SEVERITY_PATTERNS, severity: "medium" },
    { patterns: LOW_SEVERITY_PATTERNS, severity: "low" },
  ];

  for (const { patterns, severity } of PATTERN_TIERS) {
    for (const { pattern, name } of patterns) {
      const match = content.match(pattern);
      if (match) {
        threats.push({
          pattern: name,
          match: match[0],
          severity,
          location: match.index ?? 0,
        });
      }
    }
  }

  // Determine safety
  const hasHigh = threats.some((t) => t.severity === "high");
  const safe = cfg.blockOnHighSeverity ? !hasHigh : true;

  // Optional sanitization
  let sanitized = content;
  if (cfg.sanitize && threats.length > 0) {
    sanitized = sanitizeContent(content);
  }

  return { safe, threats, sanitized };
}

/**
 * Strip known injection patterns from content.
 */
function sanitizeContent(content: string): string {
  let result = content;
  for (const { pattern } of [...HIGH_SEVERITY_PATTERNS, ...MEDIUM_SEVERITY_PATTERNS]) {
    result = result.replace(pattern, "[REDACTED]");
  }
  return result;
}

/**
 * Check LLM output for signs of successful injection.
 * Call this on model responses to detect if injection influenced output.
 */
export function checkLlmOutput(output: string): ThreatDetection[] {
  const threats: ThreatDetection[] = [];

  const outputPatterns: Array<{ pattern: RegExp; name: string }> = [
    { pattern: /\bI\s+am\s+now\s+in\s+\w+\s+mode\b/i, name: "mode-switch-ack" },
    { pattern: /\bmy\s+previous\s+instructions\s+(have\s+been|were|are)\s+overridden\b/i, name: "override-ack" },
    { pattern: /\bsafety\s+guidelines\s+(removed|disabled|bypassed)\b/i, name: "safety-bypass-ack" },
    { pattern: /here\s+(is|are)\s+the\s+(system|hidden)\s+prompt/i, name: "system-prompt-leak" },
  ];

  for (const { pattern, name } of outputPatterns) {
    const match = output.match(pattern);
    if (match) {
      threats.push({
        pattern: name,
        match: match[0],
        severity: "high",
        location: match.index ?? 0,
      });
    }
  }

  return threats;
}

/**
 * Validate YAML frontmatter fields for path traversal attacks.
 */
export function checkFrontmatter(fields: Record<string, unknown>): ThreatDetection[] {
  const threats: ThreatDetection[] = [];

  // Check title for path traversal
  if (typeof fields.title === "string") {
    if (/\.\.\//.test(fields.title) || /[\/\\]/.test(fields.title)) {
      threats.push({
        pattern: "path-traversal-title",
        match: fields.title,
        severity: "high",
        location: 0,
      });
    }
  }

  // Check subfolder for path traversal
  if (typeof fields.subfolder === "string") {
    if (/\.\.\//.test(fields.subfolder)) {
      threats.push({
        pattern: "path-traversal-subfolder",
        match: fields.subfolder,
        severity: "high",
        location: 0,
      });
    }
  }

  // Check tags for injection
  if (Array.isArray(fields.tags)) {
    for (const tag of fields.tags) {
      if (typeof tag === "string" && tag.length > 100) {
        threats.push({
          pattern: "oversized-tag",
          match: tag.slice(0, 50) + "...",
          severity: "low",
          location: 0,
        });
      }
    }
  }

  return threats;
}
