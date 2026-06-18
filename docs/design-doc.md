# CodeBase Prototype Design Doc

## Summary

CodeBase is a self-hosted, AI-native software development platform prototype. The project starts from a proven forge foundation rather than rebuilding git hosting from scratch: use Gitea for repositories, pull requests, branch protection, CI hooks, webhooks, and API access, then layer differentiated AI capabilities around it.

The core prototype goal is to validate an end-to-end loop where code changes move through a familiar PR workflow while AI agents can safely review, reason about, and eventually assist with code changes using attributable identities, structured context, auditability, and human approval gates.

## Product Thesis

A modern internal code platform should treat agents as first-class collaborators, not external scripts bolted onto GitHub-style workflows. The fastest path is to preserve mature git and review primitives from Gitea while focusing custom work on the AI-native layer: code context, agent operations, permissions, audit trails, safety controls, and cost visibility.

## Prototype Scope

The prototype should prove the following high-level flow:

1. Host a real repository in a self-hosted Gitea deployment.
2. Run CI on push and pull request events using Gitea Actions.
3. Receive pull request events in a companion AI service.
4. Fetch the PR diff and relevant repository metadata through Gitea APIs.
5. Generate an AI review and post it back to the pull request.
6. Add a context service so agents can retrieve richer code knowledge efficiently.
7. Evaluate whether agent identity and permissions can remain outside Gitea core or require a minimal fork.
8. Add trust primitives — audit, budget controls, and human approval gates — before broader repo migration.

Detailed implementation plans, acceptance criteria, and dependencies are tracked in the project task board.

## Architecture Direction

CodeBase should be built in layers:

- **Forge foundation:** Gitea provides git hosting, PRs, branch protection, webhooks, REST APIs, and Actions.
- **Deployment layer:** Docker-based deployment with Caddy for HTTPS; SQLite is acceptable for prototype speed, with Postgres as the likely production path.
- **AI companion services:** External services consume Gitea webhooks and act through Gitea APIs. This is the default extension mechanism.
- **Context layer:** A repository-aware indexing/retrieval service provides diffs, related files, history, symbols, prior PRs/issues, and semantic search to agents.
- **Trust layer:** Audit logs, cost tracking, scoped permissions, and human approval gates make agent activity understandable and governable.

## Customization Strategy

Avoid forking Gitea unless a core differentiator cannot be implemented safely through existing extension points.

Preferred order:

1. **Alongside Gitea:** standalone AI services connected by webhooks and APIs.
2. **Upgrade-safe seams:** configuration, templates, OAuth, Actions, and light UI integration.
3. **Minimal core fork:** only if first-class agent identities, permissions, or other essential platform primitives cannot be achieved externally.

## Key Differentiators

- Agent identities with clear attribution and scoped capabilities.
- Code context service optimized for agent reasoning.
- Agent-native operations such as review, patch proposal, PR creation, and gated merge assistance.
- Durable audit trails and cost controls for all agent activity.
- Human approval gates for sensitive operations.

## Current Roadmap Reference

The prototype has been split into phase tasks in `/tasks`:

- Phase 1: Baseline Gitea deployment.
- Phase 2: Gitea Actions CI runner.
- Phase 3: First AI PR review loop.
- Phase 4: Code context service.
- Phase 5: Agent identity and permission evaluation.
- Phase 6: Cost, audit, and human approval gates.
- Phase 7: Broader repository and workflow migration.

## Open Risks

- Gitea fork tax if core changes become necessary.
- API and webhook differences from GitHub-style assumptions.
- Security model for agents that can read code and eventually write changes.
- Cost and latency of richer repository context retrieval.
- Migration risk for critical repositories and CI workflows.

## Guiding Principle

Ship the smallest end-to-end internal prototype that proves AI can participate safely and usefully in the software development lifecycle, while keeping the foundation boring, upgradeable, and operationally simple.
