/**
 * Task complexity classifier.
 * Scores tasks 1-10 based on content analysis to determine model routing.
 * @since 2026-04
 */

export interface ClassificationResult {
  complexity: number; // 1-10
  category: string;
  reasoning: string;
}

const COMPLEXITY_SIGNALS = {
  // High complexity signals (8-10)
  high: [
    /architect/i,
    /design\s+(system|api|schema|database)/i,
    /tradeoff/i,
    /trade-off/i,
    /complex\s+reasoning/i,
    /multi.?step\s+plan/i,
    /security\s+(audit|review|analysis)/i,
    /refactor\s+(entire|whole|complete)/i,
    /migration\s+strateg/i,
  ],
  // Medium-high complexity (6-7)
  mediumHigh: [
    /debug/i,
    /code\s+review/i,
    /implement.*integrat/i,
    /fix.*bug/i,
    /performance\s+(optim|improv|tun)/i,
    /test.*coverage/i,
    /error\s+handling/i,
  ],
  // Medium complexity (4-5)
  medium: [
    /implement/i,
    /write\s+(code|function|class|module)/i,
    /create\s+(endpoint|api|component)/i,
    /add\s+(feature|functionality)/i,
    /edit\s+(file|code)/i,
    /update/i,
    /coding/i,
  ],
  // Low complexity (2-3)
  low: [
    /summarize/i,
    /explain/i,
    /describe/i,
    /list/i,
    /format/i,
    /convert/i,
    /translate/i,
    /general/i,
  ],
  // Trivial (1)
  trivial: [
    /classify/i,
    /yes\s+or\s+no/i,
    /true\s+or\s+false/i,
    /which\s+(one|option)/i,
    /quick\s+question/i,
    /lookup/i,
  ],
};

export function classifyTask(prompt: string, hint?: number): ClassificationResult {
  if (hint !== undefined && Number.isInteger(hint) && hint >= 1 && hint <= 10) {
    return {
      complexity: hint,
      category: getCategoryForComplexity(hint),
      reasoning: `User-provided complexity hint: ${hint}`,
    };
  }

  let score = 5; // Default to medium
  const matches: string[] = [];

  for (const [level, patterns] of Object.entries(COMPLEXITY_SIGNALS)) {
    for (const pattern of patterns) {
      if (pattern.test(prompt)) {
        matches.push(`${level}: ${pattern.source}`);
      }
    }
  }

  // Count matches at each level
  const highMatches = matches.filter((m) => m.startsWith("high")).length;
  const mediumHighMatches = matches.filter((m) => m.startsWith("mediumHigh")).length;
  const mediumMatches = matches.filter((m) => m.startsWith("medium")).length;
  const lowMatches = matches.filter((m) => m.startsWith("low")).length;
  const trivialMatches = matches.filter((m) => m.startsWith("trivial")).length;

  if (highMatches > 0) score = 9 + Math.min(highMatches - 1, 1);
  else if (mediumHighMatches > 0) score = 7 + Math.min(mediumHighMatches - 1, 1);
  else if (mediumMatches > 0) score = 5 + Math.min(mediumMatches - 1, 1);
  else if (lowMatches > 0) score = 3 + Math.min(lowMatches - 1, 1);
  else if (trivialMatches > 0) score = 1 + Math.min(trivialMatches - 1, 1);

  // Prompt length as a secondary signal (only when no pattern matched)
  const wordCount = prompt.split(/\s+/).length;
  if (wordCount > 500) score = Math.min(score + 1, 10);
  if (wordCount < 10 && matches.length === 0) score = Math.max(score - 1, 1);

  score = Math.max(1, Math.min(10, score));

  return {
    complexity: score,
    category: getCategoryForComplexity(score),
    reasoning: matches.length > 0
      ? `Matched signals: ${matches.join(", ")}`
      : `Default classification based on prompt length (${wordCount} words)`,
  };
}

/** Map router complexity (1-10) to workflow team size (1-3).
 *  1-4 → 1 coder + reviewer, 5-7 → 2 coders + reviewer, 8-10 → full roster. */
export function complexityToTeamSize(complexity: number): number {
  if (complexity <= 4) return 1;
  if (complexity <= 7) return 2;
  return 3;
}

function getCategoryForComplexity(c: number): string {
  if (c >= 9) return "architecture";
  if (c >= 7) return "complex-coding";
  if (c >= 5) return "coding";
  if (c >= 3) return "general";
  return "trivial";
}
