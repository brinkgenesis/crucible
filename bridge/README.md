# @crucible/bridge

Node subprocess that wraps `@anthropic-ai/claude-agent-sdk`. Invoked by the Crucible Elixir core via `Port.open/2`. Reads JSON config on stdin, streams tool-use / status / result events as JSON lines on stdout.

## Status

⚠️ Pre-alpha. Imports still reference orchestrator sibling modules; see `TODO.md`.

## TODO

- [ ] Inline or re-home `sdk-utils/sdk-agent-builder.ts` dependencies (currently references `../workflow/types.js`, `../../utils/logger.js` which don't exist here)
- [ ] Inline `selectModelForApiPhase` from the router
- [ ] Unit tests for the stdin/stdout protocol
- [ ] Integration test: mock Claude Agent SDK, verify `result` message closes the stream
