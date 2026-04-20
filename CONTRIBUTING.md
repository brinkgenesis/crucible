# Contributing to Crucible

Thanks for your interest. Crucible is Apache 2.0 and we welcome contributions from anyone running it in the wild. This guide keeps things short — for deeper architectural context, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Ground rules

- **By submitting a PR you agree your contribution is licensed under Apache 2.0** (inbound=outbound — no CLA).
- **Be kind.** We follow the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
- **Security issues**: do not open a public issue. Email the maintainers (see `mix.exs` / repo owners) with details; we will respond within 3 working days.

## Dev setup

Prereqs: Elixir 1.15+, Erlang/OTP 26+, PostgreSQL 15+, Node 20+ (for the router sidecar), optionally Docker (for sandbox integration tests).

```bash
git clone <repo>
cd crucible
cp .env.example .env        # fill in ANTHROPIC_API_KEY, GITHUB_TOKEN, DATABASE_URL, SECRET_KEY_BASE
mix deps.get
mix ecto.setup              # creates DB, runs migrations, seeds
mix phx.server              # http://localhost:4801
```

## Before you open a PR

Run the local quality gates — CI runs the same set:

```bash
mix precommit                # compile --warnings-as-errors, deps.unlock --unused, format, test
mix sobelow --config         # security lint (must exit 0)
mix dialyzer                 # type checks (optional but encouraged)
```

Expected: **zero warnings**, **zero test failures**. If you touch a Docker-dependent code path, also run:

```bash
mix test --include docker
```

## Code conventions

- **Elixir style**: follow `mix format`. See [AGENTS.md](AGENTS.md) for Phoenix 1.8 + Elixir gotchas we've hit repeatedly.
- **Functions under 50 lines, files under 500 lines** (soft cap — split when exceeded).
- **Non-destructive by default**: prefer COALESCE/`ON CONFLICT DO NOTHING`/preserving human edits in data paths.
- **HTTP client**: use `Req`. Do not add `:httpoison`, `:tesla`, or `:httpc`.
- **Tests alongside implementation**: a change without a corresponding test is unlikely to merge unless the change itself is a test or pure doc.
- **No hardcoded secrets**. Use `Crucible.Secrets.get/1` or `System.get_env/1` at the config boundary.

## Commit style

- **Subject**: short, declarative, imperative mood. Under 70 chars. Start lowercase.
- **Body**: explain the *why*, not the *what*. The diff shows what changed; the commit message is where the reasoning lives.
- **One logical change per commit** — rebase/squash before merging if you accumulated WIP commits.

Example:
```
harden sandbox fallback when docker daemon flaps

The ExternalCircuitBreaker opened on transient daemon restarts and
stayed open until process restart, silently degrading every run to
LocalProvider. Add half-open probe every 60s so recovery is automatic.
```

## Pull request process

1. **Open an issue first** for anything non-trivial (new adapter, schema change, breaking API change). A 5-minute alignment thread saves a 2-hour rewrite.
2. **Fork, branch from `main`**, name your branch `<type>/<short-desc>` (e.g. `fix/sandbox-circuit-reset`, `feat/openai-adapter`).
3. **Keep PRs focused**: one concern per PR. If you notice a second bug, ship it in a separate PR on the same train.
4. **Include test coverage** for new behaviour and regression tests for bug fixes.
5. **Update docs** in the same PR when you change public APIs, env vars, or operational behaviour (README troubleshooting section, ARCHITECTURE.md, `.env.example`).
6. **CI must pass.** Reviewers will not pre-approve a red build.
7. **Squash-merge is the default.** Preserve a clean linear history on `main`.

## Where to look

| Area | Entry point |
|---|---|
| Kanban UI | `lib/crucible_web/live/kanban_live.ex` |
| Workflow execution | `lib/crucible/orchestrator/` |
| Adapter registry | `lib/crucible/adapter/` — see [ARCHITECTURE.md](ARCHITECTURE.md#adapter-registry) |
| Router (model selection) | `router/` (Node sidecar) |
| Self-improvement | `lib/crucible/self_improvement/` |
| Memory / knowledge vault | `lib/crucible/memory/` |
| Schema & migrations | `priv/repo/migrations/` |

## Good first issues

Check the [issue tracker](../../issues) for the `good-first-issue` label. Examples of friendly starter work:

- New model adapter (mirror `Crucible.Adapter.ClaudePort` for another provider)
- New troubleshooting runbook entry in README
- Test coverage for a thinly-tested module (`mix test --cover` to find them)
- Doc polish — especially anything you tripped over during your own setup

## Release / maintainer notes

- Releases follow semver; 0.x means any release may break; once we cut 1.0, minor releases preserve backward compatibility for public APIs.
- Maintainers merge; contributors open PRs. If a PR sits untouched for 7 days without feedback, ping the thread — it's probably on the floor, not rejected.

Thanks again for contributing.
