# Agents Plane — Design Document

> **Status:** v1.0 · 2025-02-16  
> **Requirements:** [REQUIREMENTS.md](./REQUIREMENTS.md)

---

## 1. Overview

Agents Plane provisions and manages isolated AI agent instances on GCP, integrated with Google Workspace. Each user in the organization gets a dedicated VM running OpenClaw, managed through the familiar Google Admin Console.

The implementation is a set of bash scripts for interactive setup and per-user provisioning, plus a Cloud Function + Apps Script pair for automated Admin Console integration.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Google Workspace                          │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Admin Console — Custom Schema: "Agent Configuration" │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │   │
│  │  │ Alice 🤖 │  │ Bob  🤖  │  │ Carol    │          │   │
│  │  │ Agent:ON │  │ Agent:ON │  │ Agent:OFF│          │   │
│  │  └────┬─────┘  └────┬─────┘  └──────────┘          │   │
│  └───────┼──────────────┼──────────────────────────────┘   │
└──────────┼──────────────┼──────────────────────────────────┘
           │              │
           ▼              ▼
┌──────────────────────────────────────────────────────────────┐
│  Apps Script Trigger (polls every 5 min)                     │
│  Detects schema changes → calls Cloud Function               │
└──────────┬───────────────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────────┐
│  Cloud Function: provision-agent                             │
│  Creates/stops VMs, manages secrets                          │
└──────────┬───────────────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────────┐
│                    Google Cloud Platform                      │
│  ┌──────────────────────────────────────────────┐           │
│  │  VPC: agents-plane-vpc (no external IPs)     │           │
│  │  ┌────────────┐  ┌────────────┐              │           │
│  │  │ agent-alice│  │ agent-bob  │              │           │
│  │  │ OpenClaw   │  │ OpenClaw   │              │           │
│  │  └──────┬─────┘  └──────┬─────┘              │           │
│  │         ▼               ▼                     │           │
│  │  Secret Manager (per-agent config)            │           │
│  └──────────────────────────────────────────────┘           │
│  Access: IAP Tunnel only (SSH via gcloud)                    │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. File Structure

```
scripts/
├── setup.sh                          # Interactive setup wizard (13 steps, ~1600 lines)
├── provision-agent.sh                # Per-user agent provisioning
├── status.sh                         # Status dashboard / health check
└── examples/
    ├── apps-script-trigger.js        # Google Apps Script for Admin Console automation
    └── cloud-function/
        ├── index.js                  # Cloud Function for automated provisioning
        └── package.json

Config files (created by setup.sh):
~/.openclaw/agents-plane/
├── config.json                       # Plane configuration
├── workspace-admin-key.json          # Service account key (chmod 600)
└── agents/
    ├── alice.json                    # Per-agent records
    └── bob.json
```

---

## 4. Components

### 4.1 `setup.sh` — Interactive Setup Wizard

A ~1600-line bash script that walks the admin through complete infrastructure setup:

1. **Pre-flight checks** — Verifies gcloud, jq, macOS
2. **GCP authentication** — `gcloud auth login`, domain detection
3. **Project selection** — Pick or create GCP project, verify billing
4. **API enablement** — Admin SDK, Compute, IAM, Secret Manager, Cloud Functions, Cloud Build
5. **Service account** — Creates `openclaw-workspace-admin` with domain-wide delegation
6. **Workspace delegation** — Guides manual step in Admin Console
7. **Configuration** — Prompts for plane name, region, VM type, model
8. **Save config** — Writes `config.json`
8.5. **Network infrastructure** — VPC, subnet, firewall rules, Cloud NAT
9. **Verification** — Validates all APIs, keys, and configs
10. **Custom user schema** — Adds "Agent Configuration" fields to Workspace
11. **Cloud Function deployment** — Deploys automated provisioning function
12. **Apps Script trigger** — Sets up polling trigger for Admin Console changes

Fully idempotent — safe to run multiple times.

### 4.2 `provision-agent.sh` — Per-User Provisioning

Provisions a single agent for a user. Can be run manually or called by the Cloud Function.

**Steps:**
1. Validate user email and load plane config
2. Create per-agent service account with minimal IAM roles
3. Store agent config in Secret Manager
4. Create Compute Engine VM with startup script that:
   - Installs Node.js and `openclaw` (npm package)
   - Fetches agent config from Secret Manager
   - Writes `openclaw.yaml` gateway config
   - Writes `BOOTSTRAP.md` for agent self-onboarding
   - Sets up `openclaw-gateway` as a systemd service
5. Save agent record to local JSON
6. Agent self-onboards: sends welcome email + WhatsApp QR instructions on first boot

**Options:** `--model`, `--budget`, `--vm-type`, `--disk`, `--dry-run`

### 4.3 `status.sh` — Status Dashboard

Shows all provisioned agents, VM status, models, budgets, and infrastructure health.

### 4.4 Cloud Function (`examples/cloud-function/`)

Node.js Cloud Function triggered by the Apps Script when a user's agent toggle changes in Admin Console. Calls `provision-agent.sh` logic to create or stop VMs.

### 4.5 Apps Script Trigger (`examples/apps-script-trigger.js`)

Google Apps Script that polls Workspace user profiles every 5 minutes, detects changes to the custom "Agent Configuration" schema, and calls the Cloud Function.

---

## 5. Agent Bootstrap Flow

```
VM starts → startup script runs
│
├─ Install Node.js + openclaw
├─ Fetch config from Secret Manager
├─ Write openclaw.yaml (gateway config)
├─ Write BOOTSTRAP.md (onboarding instructions)
├─ Start openclaw-gateway (systemd)
│
└─ OpenClaw agent wakes up → reads BOOTSTRAP.md
   ├─ Sends welcome email to owner
   ├─ Includes WhatsApp QR connection instructions
   ├─ Deletes BOOTSTRAP.md
   └─ Begins normal operation
```

---

## 6. Security

### Per-Agent Isolation

| Layer | Implementation |
|-------|---------------|
| **Compute** | Separate VM per user, no external IP |
| **IAM** | Dedicated service account, scoped to agent's own secrets |
| **Secrets** | Secret Manager with resource-level IAM |
| **Network** | Private VPC, firewall deny-all + IAP allow (35.235.240.0/20) |
| **Egress** | Cloud NAT for outbound, no inbound |

### Agent Service Account Roles
- `roles/secretmanager.secretAccessor` (own config only)
- `roles/logging.logWriter`
- `roles/monitoring.metricWriter`

### Access
VMs have no external IPs. SSH access is via IAP tunnel only:
```bash
gcloud compute ssh agent-alice --zone=us-east4-b --tunnel-through-iap
```

---

## 7. Design Decisions

- **Bash over TypeScript**: The setup process is inherently interactive and imperative (gcloud commands, user prompts, manual steps). Bash is the natural fit and avoids a build step.
- **Cloud Function for automation**: Bridges the gap between Google Workspace (no webhooks for user schema changes) and GCP provisioning.
- **BOOTSTRAP.md for onboarding**: The agent handles its own welcome email rather than the provisioning script. This keeps provisioning infrastructure-focused and lets the agent personalize its introduction.
- **Systemd for gateway**: Ensures the OpenClaw gateway restarts on failure and starts on boot.

---

## References

- [REQUIREMENTS.md](./REQUIREMENTS.md) — Full requirements document
