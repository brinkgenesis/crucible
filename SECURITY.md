# Security Policy

## Reporting a vulnerability

**Do not open a public issue for security bugs.**

Instead, report privately via GitHub's "Report a vulnerability" form on the
[Security Advisories](https://github.com/brinkgenesis/crucible/security/advisories/new)
page of this repository.

When you report, please include:

- A description of the issue and its impact.
- Steps to reproduce (or a minimal proof-of-concept).
- The commit SHA or release you tested against.
- Any mitigations you've already identified.

We'll acknowledge receipt within **72 hours** and aim to have a fix or
mitigation timeline within **14 days** of acknowledgment.

## Scope

In scope:

- The Crucible Phoenix/Elixir control plane (`lib/`).
- The Claude Agent SDK bridge (`bridge/`).
- Sandbox policy, secrets handling, and any code path that executes agent
  output on the host.

Out of scope:

- Vulnerabilities in upstream dependencies — report those to the upstream
  project. If the upstream fix is blocked and Crucible is affected, we'll
  ship a version pin or workaround.
- Social-engineering attacks on repository maintainers.
- Issues requiring physical access to a machine running Crucible.

## Supported versions

Crucible is pre-1.0. Only `main` receives security fixes. We'll expand this
policy once we cut tagged releases.
