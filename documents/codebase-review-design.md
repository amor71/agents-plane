# Codebase Review Design Doc

## Changelog
- 2026-02-16: Added repository review scope, risk assessment, and prioritized remediation plan.

## Context
This review covers the current shell-based provisioning workflow (`scripts/setup.sh`, `scripts/provision-agent.sh`), Cloud Function example (`scripts/examples/cloud-function/index.js`), and test harness (`tests/*`).

## Goals
- Identify correctness, security, operability, and maintainability risks.
- Prioritize changes that reduce production risk for a regulated environment.
- Propose a practical rollout/rollback approach for hardening updates.

## Non-Goals
- Re-architecting the project into a full microservice platform.
- Implementing all fixes in this review pass.

## Architecture / Boundaries
- Control plane is primarily local shell scripts executed by an admin workstation.
- Provisioning path: Workspace/App Script -> HTTP Cloud Function -> Compute + Secret Manager.
- Agent bootstrap path: VM startup script pulled from GCS and executed on first boot.

## APIs / Contracts
- Cloud Function endpoint currently uses bearer token auth via `AUTH_SECRET` environment variable.
- Payload contract appears implicit (`email`, `action`, `model`, `budget`), not schema-validated.
- Idempotency is partial: existing VM checks are present, but request-level idempotency keying is absent.

## Data Model / Retention
- Local state persisted in `~/.openclaw/agents-plane/config.json` and per-agent JSON files.
- Secrets persisted in Secret Manager per agent as JSON blobs.
- No explicit retention/deletion lifecycle for per-agent metadata or old secret versions documented.

## Business Logic Layout
- Significant orchestration and policy logic is embedded directly in large shell scripts.
- Cloud Function mixes HTTP handling, auth, and provisioning logic in one module.

## Testing Strategy (Current + Plan)
### Current
- `tests/test-startup-script.js`: unit-style checks for startup script generation assumptions.
- `tests/test.sh`: wrapper for unit and docker integration paths.

### Gaps
- Existing unit test fails against current implementation due to architectural drift.
- No automated tests for Cloud Function auth, input validation, or IAM/least-privilege controls.

### Proposed Test Plan
1. Add contract tests for Cloud Function request validation/auth behavior.
2. Add smoke tests for provisioning decision logic (existing/running/stopped/not-found).
3. Add shell regression tests for generated gcloud commands with safe fixtures.
4. Gate CI on all tests and add linting (shellcheck + eslint).

## Security / Privacy
- Current deployment guidance explicitly allows unauthenticated function invocation.
- VM service account receives broad `cloud-platform` scope.
- Workspace admin service account receives broad admin roles and stores long-lived key material locally.
- Secret payload includes API key as plaintext JSON value.

## Compliance Notes (RIA-oriented; not legal advice)
- Missing explicit immutable audit trail and supervised change approvals for provisioning events.
- Broad privileges and public endpoints increase supervisory and least-privilege risk.
- Secret/version retention and teardown policies should be documented and controlled.

## Observability
- Logging mostly via stdout/stderr; no structured event schema.
- No explicit metrics/alerts for failed provisioning, auth failures, or policy violations.

## Performance / Scale
- Current approach should work for small fleets.
- Parallel provisioning/backpressure handling is not explicitly designed.

## Rollout / Migration
1. Introduce hardening behind feature flags/env vars (e.g., strict auth mode, strict input validation).
2. Deploy to staging project and run contract + integration tests.
3. Canary to one pilot OU/group.
4. Gradually enforce stricter IAM/auth defaults.

## Rollback
- Keep previous Cloud Function revision and revert traffic immediately if failures increase.
- Keep previous startup script object in GCS and pin via versioned URI.
- Preserve prior script release tags for local rollback.

## Risks / Open Questions
- Should Cloud Function require IAM-authenticated invocations only (no public invoker)?
- What is the required secret rotation cadence and retention policy?
- Is per-agent SA keyless auth with workload identity sufficient for all integrations?
