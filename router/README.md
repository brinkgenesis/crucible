# @crucible/router

Cost / quality / speed routing across Anthropic, Google, MiniMax, and Ollama — with per-provider circuit breakers, quota tracking, graceful fallback, and output safety checks.

## Install

```
npm i @crucible/router
```

## Usage

```ts
import { ModelRouter } from "@crucible/router";

const router = new ModelRouter();

const result = await router.route({
  prompt: "Summarize this: ...",
  complexityHint: 3,   // 1 = trivial lookup, 10 = architecture reasoning
  strategy: "cost",    // "cost" | "quality" | "speed"
});

console.log(result.route);      // { modelId, provider, reason }
console.log(result.text);
console.log(result.costUsd);
```

## How it routes

| Complexity | Cost strategy | Quality strategy | Speed strategy |
|-----------|---------------|------------------|---------------|
| 1-2 | Haiku 4.5 | Haiku 4.5 | Haiku 4.5 |
| 3-4 | Gemini 2.5 Flash | Sonnet 4.5 | Gemini 2.5 Flash |
| 5-6 | MiniMax M2 | Sonnet 4.5 | MiniMax M2 |
| 7-8 | Sonnet 4.5 | Opus 4.6 | Sonnet 4.5 |
| 9-10 | Opus 4.6 | Opus 4.6 | Opus 4.6 |

## Fallback order

When the primary provider fails (network, rate limit, circuit open), the router cycles through `ollama → google → minimax → anthropic`, selecting the cheapest model available at each provider.

## Circuit breaker

Per-provider circuit breakers auto-open after consecutive failures and cool down before retrying. Use `router.circuitStats()` to inspect state, `router.resetCircuit(name)` to clear.

## Quota tracking

Live provider quota is polled in the background. `router.getProviderHealth()` returns rate-limit utilization per provider. Exhausted providers are skipped until quota refreshes.

## License

Apache 2.0.
