# Codebase Review Findings

Date: 2026-02-16

## Executive Summary
The project is a pragmatic bootstrap/provisioning system and is understandable for small-scale ops, but it currently carries **high security and reliability risk** for production enterprise use unless hardening and test maintenance are addressed.

## Priority Findings

### P0 — Publicly invokable provisioning endpoint
- Deployment instructions and script comments use `--allow-unauthenticated`, making the function internet-reachable.
- Current protection is a shared bearer secret (`AUTH_SECRET`) only.
- Impact: elevated risk of unauthorized provisioning attempts, brute force/credential replay, and weak non-repudiation.

### P0 — Excessive privilege model in compute and control plane
- VM instances run with `cloud-platform` OAuth scope, effectively broadening available API surface.
- Setup grants broad roles to workspace admin SA (`compute.admin`, `iam.serviceAccountAdmin`, `iam.serviceAccountKeyAdmin`, `secretmanager.admin`).
- Impact: blast radius is large if SA/token/host is compromised.

### P0 — Long-lived service account key material written to local disk
- Workspace admin key JSON is persisted under `~/.openclaw/agents-plane/workspace-admin-key.json`.
- Even with `chmod 600`, this remains high-value long-lived credential material.
- Impact: key exfiltration risk and operational burden for secure rotation/revocation.

### P1 — Test suite drift indicates broken CI signal
- Unit test expects an inlined startup script template in Cloud Function source.
- Cloud Function now uses startup script from GCS URL; test fails immediately.
- Impact: false negatives reduce confidence and block rapid safe changes.

### P1 — Input validation and schema enforcement are minimal
- Cloud Function validates only that `email` exists; `action`, `model`, and `budget` are not strictly validated.
- Shell scripts do not consistently validate numeric ranges (budget/disk) or sanitize all dynamic values.
- Impact: malformed payloads can create inconsistent state or unexpected behavior.

### P1 — Inconsistent single source of truth for startup logic
- Test framework assumes startup script in JS source while provisioning points to external GCS script.
- Impact: high drift risk and unclear ownership/versioning of bootstrap behavior.

### P2 — Observability and operational controls are limited
- Logging is mostly plain text and not structured.
- No explicit metrics/alerts for auth failures, provisioning failures, or reconciliation drift.
- Impact: harder incident response, weak supervision evidence.

## Recommended Remediation Order
1. **Secure ingress**: switch to IAM-authenticated function invocation; remove unauthenticated invoker.
2. **Least privilege**: remove `cloud-platform` scope, assign minimal per-agent permissions.
3. **Keyless auth path**: move from long-lived SA keys to workload identity/federated auth where possible.
4. **Repair tests**: align startup-script tests with actual source-of-truth and add Cloud Function contract tests.
5. **Validation hardening**: strict schema validation + bounded values for all user inputs.
6. **Observability upgrades**: structured logs + key metrics/alerts.

## Compliance-Sensitive Notes (not legal advice)
- Add immutable audit records for provisioning/deprovisioning events with actor identity.
- Document secret retention/rotation/deletion controls and supervisory review checkpoints.
- Ensure marketing/performance claims in onboarding automation are compliance-reviewed before enabling at scale.
