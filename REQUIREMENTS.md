# Agents Plane — Requirements Document

> **Status:** Draft v1.0 · 2025-02-15
> **Tracking:** [openclaw/openclaw#17299](https://github.com/openclaw/openclaw/issues/17299)
> **Author:** @amor71

---

## Table of Contents

1. [Overview](#overview)
2. [Project 1: Agent Orchestration Framework](#project-1-agent-orchestration-framework)
3. [Project 2: Google Workspace Add-on](#project-2-google-workspace-add-on)
4. [Shared Architecture](#shared-architecture)
5. [Security Model](#security-model)
6. [Phased Rollout](#phased-rollout)
7. [References](#references)

---

## Overview

Two interconnected projects that together deliver **"OpenClaw for Teams"** — a provider-agnostic orchestration layer for deploying isolated AI agents, paired with a Google Workspace Add-on that lets admins manage agents like any other Workspace service.

**Core principle:** An admin enables an agent for a user in the Workspace Admin Console. Everything else — VM, secrets, networking, channels, onboarding — happens automatically. The user never touches a terminal.

### Relationship Between Projects

```
┌──────────────────────────────┐
│  Google Workspace Add-on     │  ← Admin UI (enable/disable/configure)
│  (Project 2)                 │
└──────────┬───────────────────┘
           │ Webhook / API calls
           ▼
┌──────────────────────────────┐
│  Agent Orchestration         │  ← Provisioning engine
│  Framework (Project 1)       │
│  ┌────────┐ ┌────────┐      │
│  │Identity│ │ Infra  │      │
│  │Provider│ │Provider│      │
│  ├────────┤ ├────────┤      │
│  │Secrets │ │Network │      │
│  │Provider│ │Provider│      │
│  └────────┘ └────────┘      │
└──────────────────────────────┘
```

---

## Project 1: Agent Orchestration Framework

> **Issue:** [#17299](https://github.com/openclaw/openclaw/issues/17299)
> **Foundation:** Secrets providers from [PR #16663](https://github.com/openclaw/openclaw/pull/16663)

### 1.1 Goals

- Provider-agnostic agent provisioning with pluggable backends
- Per-agent isolation: compute, secrets, network, IAM
- CLI-first management (`openclaw planes ...`)
- Declarative config schema for reproducible deployments
- Support single-agent and fleet (hundreds) scale

### 1.2 Pluggable Provider Architecture

#### 1.2.1 Identity Providers

Resolve "who is this user?" and map to agent ownership.

| Provider | Auth Protocol | Notes |
|----------|--------------|-------|
| Google Workspace | OAuth2 / OIDC | Primary target; ties into Project 2 |
| Microsoft Entra (Azure AD) | OAuth2 / OIDC / SAML | Enterprise SSO |
| Okta | OAuth2 / SAML | Widely used IdP |
| LDAP | LDAP bind | Legacy on-prem |
| SAML (generic) | SAML 2.0 | Catch-all federation |

**Interface:**
```typescript
interface IdentityProvider {
  name: string;
  authenticate(token: string): Promise<UserIdentity>;
  resolveUser(email: string): Promise<UserIdentity | null>;
  listUsers(filter?: UserFilter): Promise<UserIdentity[]>;
  watchEvents?(callback: (event: UserEvent) => void): void; // offboarding, group changes
}
```

**Requirements:**
- [ ] REQ-ID-01: Provider registry with runtime selection
- [ ] REQ-ID-02: User → agent ownership mapping persisted in plane config
- [ ] REQ-ID-03: Group/OU membership drives policy assignment
- [ ] REQ-ID-04: Offboarding events trigger agent teardown
- [ ] REQ-ID-05: Support domain-wide delegation (Google) and app registrations (Entra)

#### 1.2.2 Infrastructure Providers

Provision compute for each agent.

| Provider | Compute Options | Container Options |
|----------|----------------|-------------------|
| GCP | Compute Engine VMs | GKE pods |
| AWS | EC2 instances | EKS pods |
| Azure | Azure VMs | AKS pods |
| Self-hosted | Bare metal / existing VMs | Docker / Podman |

**Interface:**
```typescript
interface InfraProvider {
  name: string;
  provision(spec: AgentComputeSpec): Promise<AgentInstance>;
  deprovision(agentId: string): Promise<void>;
  restart(agentId: string): Promise<void>;
  status(agentId: string): Promise<AgentStatus>;
  listInstances(planeId: string): Promise<AgentInstance[]>;
  resize(agentId: string, spec: Partial<AgentComputeSpec>): Promise<void>;
}

interface AgentComputeSpec {
  machineType: string;      // e.g. "e2-small", "t3.small"
  region: string;
  diskSizeGb: number;
  image?: string;            // custom OS image
  labels: Record<string, string>;
  startupScript?: string;
}
```

**Requirements:**
- [ ] REQ-INFRA-01: VM-per-agent as default isolation model
- [ ] REQ-INFRA-02: Container-per-agent (K8s) as cost-optimized alternative
- [ ] REQ-INFRA-03: Self-hosted provider for air-gapped / on-prem deployments
- [ ] REQ-INFRA-04: Startup script installs OpenClaw, configures agent identity
- [ ] REQ-INFRA-05: Health checks (heartbeat) with auto-restart on failure
- [ ] REQ-INFRA-06: Rolling upgrades across a plane (`openclaw planes upgrade`)
- [ ] REQ-INFRA-07: Cost labels/tags per agent for billing attribution

#### 1.2.3 Secrets Providers

**Already built** in [PR #16663](https://github.com/openclaw/openclaw/pull/16663). Related repos:
- [`openclaw/secrets-provider-gcp`](https://github.com/openclaw/secrets-provider-gcp)
- [`openclaw/secrets-provider-aws`](https://github.com/openclaw/secrets-provider-aws)
- [`openclaw/secrets-provider-azure`](https://github.com/openclaw/secrets-provider-azure)
- [`openclaw/secrets-provider-vault`](https://github.com/openclaw/secrets-provider-vault)

**Interface** (existing):
```typescript
interface SecretsProvider {
  name: string;
  get(key: string, agentId: string): Promise<string>;
  set(key: string, value: string, agentId: string): Promise<void>;
  delete(key: string, agentId: string): Promise<void>;
  list(agentId: string): Promise<string[]>;
  rotate(agentId: string): Promise<RotationResult>;
}
```

**Additional requirements for Agents Plane integration:**
- [ ] REQ-SEC-01: Per-agent secret namespace (prefix/path isolation)
- [ ] REQ-SEC-02: Bulk rotation across a plane
- [ ] REQ-SEC-03: Secret purge on agent teardown (zero residual)
- [ ] REQ-SEC-04: Admin can trigger rotation without accessing secret values
- [ ] REQ-SEC-05: Audit log for all secret access

#### 1.2.4 Networking Providers

Secure access to agent instances.

| Provider | Protocol | Best For |
|----------|----------|----------|
| GCP IAP | TCP tunneling over HTTPS | GCP VMs |
| AWS SSM | Session Manager | AWS EC2 |
| WireGuard | VPN mesh | Self-hosted / multi-cloud |
| Tailscale | WireGuard-based overlay | Simple setup |
| None (direct) | SSH with firewall rules | Dev/testing |

**Interface:**
```typescript
interface NetworkProvider {
  name: string;
  setupAccess(agentId: string, ownerIdentity: string): Promise<AccessConfig>;
  revokeAccess(agentId: string): Promise<void>;
  tunnel(agentId: string): Promise<TunnelInfo>;  // returns connection details
  configureEgress(agentId: string, policy: EgressPolicy): Promise<void>;
}
```

**Requirements:**
- [ ] REQ-NET-01: Zero agents exposed to public internet by default
- [ ] REQ-NET-02: Agent-to-agent traffic blocked (zero-trust between agents)
- [ ] REQ-NET-03: Egress policy configurable per agent (allowlist domains/ports)
- [ ] REQ-NET-04: All access audited (who connected, when, from where)
- [ ] REQ-NET-05: Owner-only access enforcement (IAP/SSM identity binding)

### 1.3 CLI Specification

```bash
# Plane lifecycle
openclaw planes create \
  --name <plane-name> \
  --identity-provider google-workspace \
  --infra-provider gcp \
  --secrets-provider gcp-secret-manager \
  --network-provider iap \
  --region us-east4 \
  --config planes.yaml

openclaw planes list
openclaw planes status [--plane <name>]
openclaw planes delete --plane <name> [--force]
openclaw planes upgrade --plane <name> [--version <tag>]

# Agent lifecycle
openclaw planes add-agent \
  --plane <name> \
  --name <agent-name> \
  --owner <email> \
  --machine-type e2-small \
  --model-tier opus \
  --budget-cap 100 \
  --tools "exec,github,email" \
  --channels "whatsapp,slack"

openclaw planes remove-agent --plane <name> --name <agent-name>
openclaw planes restart-agent --plane <name> --name <agent-name>
openclaw planes logs --plane <name> --name <agent-name> [--follow]

# Fleet operations
openclaw planes rotate-secrets --plane <name> [--agent <name>]
openclaw planes pause --plane <name>          # pause all agents
openclaw planes resume --plane <name>
openclaw planes cost-report --plane <name> [--period 30d]
```

### 1.4 Config Schema

```yaml
# planes.yaml
apiVersion: openclaw.dev/v1alpha1
kind: AgentsPlane
metadata:
  name: acme-agents
  
spec:
  identity:
    provider: google-workspace
    domain: acme.com
    adminEmail: admin@acme.com
    
  infrastructure:
    provider: gcp
    project: acme-prod-123
    region: us-east4
    defaults:
      machineType: e2-small
      diskSizeGb: 20
      image: projects/openclaw/global/images/openclaw-agent-v1
      
  secrets:
    provider: gcp-secret-manager
    project: acme-prod-123
    # Per-agent prefix: secrets/agents/{agentId}/*
    
  networking:
    provider: iap
    egressPolicy:
      default: restricted
      allowedDomains:
        - "*.googleapis.com"
        - "api.openai.com"
        - "api.anthropic.com"
        
  agents:
    - name: alice-agent
      owner: alice@acme.com
      machineType: e2-medium  # override default
      modelTier: opus
      budgetCap: 200
      tools: [exec, github, email, calendar]
      channels: [whatsapp, slack]
      
    - name: bob-agent
      owner: bob@acme.com
      modelTier: sonnet
      budgetCap: 50
      tools: [email, calendar]
      channels: [email]
      
  policies:
    - match:
        group: engineering@acme.com
      spec:
        tools: [exec, github, email, calendar, ssh]
        modelTier: opus
        budgetCap: 200
        
    - match:
        ou: /Sales
      spec:
        tools: [email, crm, calendar]
        modelTier: sonnet
        budgetCap: 75
```

### 1.5 Per-Agent Isolation Matrix

| Dimension | VM-per-agent | K8s-per-agent | Notes |
|-----------|-------------|---------------|-------|
| Compute | Separate VM | Pod + resource limits | VM is strongest |
| Secrets | SA + IAM binding | SA + Workload Identity | Both strong |
| Network | VPC firewall rules | NetworkPolicy + mesh | Both adequate |
| IAM | Dedicated service account | Workload Identity SA | Equivalent |
| Filesystem | Separate disk | PVC + securityContext | VM is simpler |
| Cost tracking | GCP labels | K8s labels + namespace | Both work |

---

## Project 2: Google Workspace Add-on for Agent Management

> **Issue:** To be created
> **Depends on:** Project 1 (Orchestration Framework)

### 2.1 Goals

- Manage AI agents from Google Workspace Admin Console — as naturally as enabling Gmail or Drive
- Zero-touch onboarding for end users
- Full lifecycle management: provision, configure, monitor, teardown
- Policy enforcement via OUs and Groups (native Workspace concepts)

### 2.2 Admin Experience

#### 2.2.1 Agent Service Card (Admin Console)

Appears under **Apps → Additional Google Services** (or a custom admin card):

**Requirements:**
- [ ] REQ-WS-01: Toggle agent on/off per user (like enabling/disabling a Workspace service)
- [ ] REQ-WS-02: Per-user configuration: model tier, budget cap, tool allowlist, channel restrictions
- [ ] REQ-WS-03: Per-OU/Group policy inheritance (Engineering gets exec+GitHub, Sales gets email+CRM)
- [ ] REQ-WS-04: Dashboard showing per-agent: status (running/stopped/error), health (last heartbeat), usage (API calls, tokens), costs (MTD)
- [ ] REQ-WS-05: Bulk actions: rotate all credentials, pause all agents, export cost report by department
- [ ] REQ-WS-06: User offboarding in Workspace triggers automatic agent shutdown, secret purge, VM deletion
- [ ] REQ-WS-07: Agent restart and reprovision from admin console (one-click)
- [ ] REQ-WS-08: Push model upgrades from admin (e.g., upgrade all agents from Sonnet to Opus)
- [ ] REQ-WS-09: Audit log viewer: who accessed what, when, filterable by user/agent/action

#### 2.2.2 Policy Configuration

```
Admin Console → Apps → OpenClaw Agent
├── Organization-wide settings
│   ├── Default model tier: Sonnet
│   ├── Default budget cap: $50/mo
│   ├── Default tools: [email, calendar]
│   └── Default channels: [email]
├── Organizational Units
│   ├── /Engineering
│   │   ├── Model tier: Opus
│   │   ├── Budget cap: $200/mo
│   │   ├── Tools: [exec, github, email, calendar, ssh]
│   │   └── Channels: [whatsapp, slack, email]
│   └── /Sales
│       ├── Tools: [email, crm, calendar]
│       └── Channels: [email, slack]
└── Groups
    └── engineering-leads@acme.com
        └── Budget cap: $500/mo (override)
```

### 2.3 User Experience (Zero-Touch Onboarding)

**Flow:**
1. Admin enables "OpenClaw Agent" for user in Admin Console
2. Webhook fires → Orchestration Framework provisions VM, secrets, network, channels
3. Agent boots, runs BOOTSTRAP.md
4. Agent sends introductory email to user: _"Hey, I'm your new AI agent. Let's get connected."_
5. Email contains:
   - Quick intro of capabilities (based on policy/tools)
   - Links to connect WhatsApp / Slack / Telegram
   - "Just reply to this email to start chatting"
6. User replies or connects a channel
7. Agent begins learning about the user (preferences, workflows, schedule)

**Requirements:**
- [ ] REQ-UX-01: User never needs terminal, SSH, cloud console, or CLI access
- [ ] REQ-UX-02: Onboarding email sent within 5 minutes of admin enabling the agent
- [ ] REQ-UX-03: At least email channel available immediately; others via simple link-click
- [ ] REQ-UX-04: BOOTSTRAP.md executed automatically — agent introduces itself and learns user context
- [ ] REQ-UX-05: User can request capability changes through the agent (routed to admin for approval)

### 2.4 Ongoing Maintenance

- [ ] REQ-MAINT-01: Agent heartbeat status visible in Admin Console (green/yellow/red)
- [ ] REQ-MAINT-02: One-click restart from Admin Console
- [ ] REQ-MAINT-03: One-click reprovision (fresh VM, preserved memory/config)
- [ ] REQ-MAINT-04: Automatic secret rotation on configurable schedule (default: 90 days)
- [ ] REQ-MAINT-05: Central model version management (upgrade all or per-OU)
- [ ] REQ-MAINT-06: Agent workspace backup/restore
- [ ] REQ-MAINT-07: Cost alerts when agent approaches budget cap (80%, 95%, 100%)

### 2.5 Technical Implementation

#### 2.5.1 Architecture

```
┌─────────────────────────┐     ┌──────────────────────────┐
│ Google Workspace Admin   │     │ Google Cloud Marketplace  │
│ Console                  │     │ Listing                   │
│ ┌─────────────────────┐ │     └──────────┬───────────────┘
│ │ OpenClaw Agent Card  │ │                │ Install
│ │ (Admin SDK Widget)   │ │                ▼
│ └──────────┬──────────┘ │     ┌──────────────────────────┐
└────────────┼────────────┘     │ OpenClaw Control Plane    │
             │ Admin SDK         │ (Cloud Run / GKE)         │
             │ + Webhooks        │                            │
             ▼                   │ ┌────────────────────────┐ │
┌─────────────────────────┐     │ │ Orchestration API       │ │
│ Workspace Events         │────▶│ │ POST /agents/provision  │ │
│ - User created/deleted   │     │ │ POST /agents/configure  │ │
│ - OU/Group membership    │     │ │ DELETE /agents/{id}      │ │
│ - Service enabled/disabled│    │ │ GET /agents/{id}/status  │ │
└─────────────────────────┘     │ └───────────┬────────────┘ │
                                │             │              │
                                │             ▼              │
                                │ ┌────────────────────────┐ │
                                │ │ Agent Orchestration     │ │
                                │ │ Framework (Project 1)   │ │
                                │ └────────────────────────┘ │
                                └──────────────────────────┘
```

#### 2.5.2 Components

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Admin Card | Workspace Admin SDK + Apps Script | UI in Admin Console |
| Webhook Receiver | Cloud Run | Receives Workspace events |
| Orchestration API | Cloud Run / GKE | REST API for agent CRUD |
| State Store | Firestore / Cloud SQL | Agent config, status, audit log |
| Event Bus | Pub/Sub | Async provisioning pipeline |
| Marketplace Listing | Google Cloud Marketplace | Distribution + billing |

#### 2.5.3 Custom User Schema

```json
{
  "schemaName": "OpenClaw_Agent",
  "fields": [
    { "fieldName": "agentEnabled", "fieldType": "BOOL" },
    { "fieldName": "agentId", "fieldType": "STRING" },
    { "fieldName": "modelTier", "fieldType": "STRING" },
    { "fieldName": "budgetCap", "fieldType": "INT64" },
    { "fieldName": "toolAllowlist", "fieldType": "STRING" },
    { "fieldName": "channelRestrictions", "fieldType": "STRING" },
    { "fieldName": "agentStatus", "fieldType": "STRING" },
    { "fieldName": "lastHeartbeat", "fieldType": "STRING" }
  ]
}
```

#### 2.5.4 Workspace Event Webhooks

| Event | Action |
|-------|--------|
| `users.create` + agent enabled for OU | Provision agent |
| `users.delete` / `users.suspend` | Teardown agent, purge secrets |
| Service toggled ON for user | Provision agent |
| Service toggled OFF for user | Teardown agent |
| User moved to new OU | Reconfigure agent policies |
| Group membership changed | Update tool/channel allowlists |

### 2.6 Security

- [ ] REQ-WSEC-01: OAuth2 with domain-wide delegation (minimal scopes)
- [ ] REQ-WSEC-02: Admin roles: "Agent Admin" (full CRUD), "Agent Viewer" (read-only dashboard)
- [ ] REQ-WSEC-03: All provisioning actions logged to Cloud Audit Logs
- [ ] REQ-WSEC-04: Agent can NEVER modify its own permissions, budget, or tool allowlist
- [ ] REQ-WSEC-05: Instant revocation on user offboarding (< 60 seconds to full teardown)
- [ ] REQ-WSEC-06: No secret values visible in Admin Console (admin sees metadata only)
- [ ] REQ-WSEC-07: Marketplace OAuth consent screen with minimal scope request
- [ ] REQ-WSEC-08: SOC 2 Type II compatible audit trail

#### OAuth2 Scopes Required

```
https://www.googleapis.com/auth/admin.directory.user
https://www.googleapis.com/auth/admin.directory.group
https://www.googleapis.com/auth/admin.directory.orgunit
https://www.googleapis.com/auth/admin.directory.userschema
https://www.googleapis.com/auth/cloud-platform  (for provisioning)
```

---

## Shared Architecture

### API Contract (Orchestration Framework ↔ Workspace Add-on)

```yaml
openapi: 3.0.0
info:
  title: OpenClaw Orchestration API
  version: 1.0.0

paths:
  /v1/planes:
    post:
      summary: Create an agents plane
    get:
      summary: List planes
      
  /v1/planes/{planeId}/agents:
    post:
      summary: Provision a new agent
      requestBody:
        content:
          application/json:
            schema:
              type: object
              properties:
                name: { type: string }
                ownerEmail: { type: string }
                modelTier: { type: string, enum: [haiku, sonnet, opus] }
                budgetCap: { type: integer }
                tools: { type: array, items: { type: string } }
                channels: { type: array, items: { type: string } }
    get:
      summary: List agents in plane
      
  /v1/planes/{planeId}/agents/{agentId}:
    get:
      summary: Agent status + health
    patch:
      summary: Update agent config
    delete:
      summary: Teardown agent
      
  /v1/planes/{planeId}/agents/{agentId}/restart:
    post:
      summary: Restart agent
      
  /v1/planes/{planeId}/rotate-secrets:
    post:
      summary: Rotate all secrets in plane
      
  /v1/planes/{planeId}/cost-report:
    get:
      summary: Cost report for plane
```

---

## Security Model (Cross-Cutting)

### Trust Boundaries

```
┌─ Trust Boundary 1: Admin ──────────────────────┐
│  Workspace Admin Console                        │
│  Can: enable/disable, configure, view dashboard │
│  Cannot: access secret values, SSH into agents  │
└─────────────────────────────────────────────────┘

┌─ Trust Boundary 2: User ───────────────────────┐
│  Agent owner (via channels)                     │
│  Can: chat with agent, request capabilities     │
│  Cannot: access other agents, modify policies   │
└─────────────────────────────────────────────────┘

┌─ Trust Boundary 3: Agent ──────────────────────┐
│  Agent instance                                 │
│  Can: access own secrets, own tools, own memory │
│  Cannot: access other agents, modify own policy │
│  Cannot: increase own budget or permissions     │
└─────────────────────────────────────────────────┘
```

### Threat Model Highlights

| Threat | Mitigation |
|--------|-----------|
| Agent escalates own permissions | IAM enforced; agent SA has no IAM admin role |
| Agent accesses another agent's secrets | Per-agent SA + secret prefix isolation |
| Rogue admin reads agent secrets | Admin SDK has no secret-read scope; separation of duties |
| Stale agent after user offboarding | Workspace event → automatic teardown pipeline |
| Supply chain attack on agent image | Signed images, Binary Authorization (GCP) |

---

## Phased Rollout

### Phase 1: Foundation (Q2 2025)
- [ ] Provider interfaces defined and documented
- [ ] GCP infra provider (VM-per-agent)
- [ ] GCP secrets provider integration (from PR #16663)
- [ ] IAP networking provider
- [ ] Google Workspace identity provider
- [ ] CLI: `openclaw planes create/add-agent/remove-agent/status`
- [ ] Config schema (planes.yaml)

### Phase 2: Workspace Integration (Q3 2025)
- [ ] Google Workspace Add-on (Admin Console card)
- [ ] Webhook receiver for Workspace events
- [ ] Zero-touch onboarding flow
- [ ] User offboarding automation
- [ ] Basic admin dashboard (status, health)
- [ ] Google Cloud Marketplace listing (private/alpha)

### Phase 3: Enterprise Features (Q4 2025)
- [ ] AWS infra provider (EC2 + EKS)
- [ ] Azure infra provider (VMs + AKS)
- [ ] Microsoft Entra identity provider
- [ ] Cost tracking and budget enforcement
- [ ] Audit log viewer in Admin Console
- [ ] K8s backend for GCP (GKE)

### Phase 4: Scale & Polish (Q1 2026)
- [ ] Self-hosted infra provider
- [ ] Okta / LDAP identity providers
- [ ] WireGuard / Tailscale networking
- [ ] Rolling upgrades across planes
- [ ] SOC 2 compliance documentation
- [ ] Public Marketplace listing (GA)

---

## References

| Reference | Link |
|-----------|------|
| Agents Plane issue | [openclaw/openclaw#17299](https://github.com/openclaw/openclaw/issues/17299) |
| Secrets providers PR | [openclaw/openclaw#16663](https://github.com/openclaw/openclaw/pull/16663) |
| Thinking Clock | [openclaw/openclaw#17287](https://github.com/openclaw/openclaw/issues/17287) |
| GCP Secrets Provider | [openclaw/secrets-provider-gcp](https://github.com/openclaw/secrets-provider-gcp) |
| AWS Secrets Provider | [openclaw/secrets-provider-aws](https://github.com/openclaw/secrets-provider-aws) |
| Azure Secrets Provider | [openclaw/secrets-provider-azure](https://github.com/openclaw/secrets-provider-azure) |
| Vault Secrets Provider | [openclaw/secrets-provider-vault](https://github.com/openclaw/secrets-provider-vault) |
