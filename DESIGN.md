# Agents Plane — Design Document

> **Status:** Draft v1.0 · 2025-02-15  
> **Requirements:** [REQUIREMENTS.md](./REQUIREMENTS.md)  
> **Codebase:** `openclaw/openclaw` fork at `/home/rye/openclaw-pr/`  
> **Foundation:** Secrets providers from PR #16663

---

## 1. Overview

The Agents Plane is a new module in `src/agents-plane/` that provisions and manages isolated AI agent instances across cloud providers. Phase 1 targets two deployments:

- **Nine30** — GCP + Google Workspace
- **AWS Company** — AWS + (identity TBD, likely Entra)

The design is provider-agnostic with pluggable interfaces for infra, identity, secrets, and networking.

---

## 2. File Structure

```
src/agents-plane/
├── index.ts                        # PlaneManager — main orchestrator
├── types.ts                        # All interfaces, configs, enums
├── cli.ts                          # CLI command registration
├── providers/
│   ├── infra/
│   │   ├── interface.ts            # InfraProvider interface
│   │   ├── gcp.ts                  # GCP Compute Engine provider
│   │   ├── gcp.test.ts
│   │   ├── aws.ts                  # AWS EC2 provider
│   │   └── aws.test.ts
│   ├── identity/
│   │   ├── interface.ts            # IdentityProvider interface
│   │   ├── google-workspace.ts     # Google Workspace Admin SDK
│   │   └── google-workspace.test.ts
│   ├── network/
│   │   ├── interface.ts            # NetworkProvider interface
│   │   ├── iap.ts                  # GCP IAP tunneling
│   │   └── ssm.ts                  # AWS SSM Session Manager
│   └── secrets/
│       └── integration.ts          # Thin wrapper around existing secrets providers
├── bootstrap/
│   ├── templates/
│   │   ├── gcp-startup.sh.ejs      # EJS template for GCP VM startup
│   │   └── aws-userdata.sh.ejs     # EJS template for EC2 user-data
│   └── default-config.ts           # Default agent workspace files
├── state/
│   ├── interface.ts                # StateStore interface
│   ├── gcs.ts                      # GCS bucket backend
│   ├── s3.ts                       # S3 bucket backend
│   └── store.test.ts
└── config/
    ├── schema.ts                   # planes.yaml validation (zod)
    └── loader.ts                   # Config file loading + merging
```

---

## 3. Core Types (`types.ts`)

```typescript
// ── Plane-level ──

export interface PlaneConfig {
  name: string;
  identity: {
    provider: 'google-workspace' | 'entra';
    domain: string;
    adminEmail?: string;           // for domain-wide delegation
    credentials?: string;          // path or secret ref
  };
  infra: {
    provider: 'gcp' | 'aws';
    project?: string;              // GCP project ID
    region: string;
    defaults: ComputeDefaults;
  };
  secrets: {
    provider: 'gcp-secret-manager' | 'aws-secrets-manager';
    project?: string;
  };
  network: {
    provider: 'iap' | 'ssm' | 'none';
    egressPolicy?: EgressPolicy;
  };
  stateBackend: {
    provider: 'gcs' | 's3';
    bucket: string;
    prefix?: string;              // default: `planes/{planeName}/`
  };
}

export interface ComputeDefaults {
  machineType: string;            // e2-small, t3.small
  diskSizeGb: number;             // default: 20
  image?: string;                 // custom OS image
}

export interface EgressPolicy {
  default: 'restricted' | 'open';
  allowedDomains?: string[];
}

// ── Agent-level ──

export interface AgentConfig {
  name: string;                   // unique within plane
  owner: string;                  // email
  machineType?: string;           // override plane default
  modelTier: 'haiku' | 'sonnet' | 'opus';
  model?: string;                 // specific model override (gpt-4o, etc.)
  budgetCap: number;              // USD/month
  tools: string[];
  channels: string[];
}

export interface AgentInstance {
  agentId: string;                // `{planeName}-{agentName}`
  planeId: string;
  config: AgentConfig;
  compute: {
    instanceId: string;           // VM instance ID / EC2 instance ID
    zone: string;
    ip?: string;                  // internal IP
  };
  iam: {
    serviceAccount?: string;      // GCP SA email
    iamUser?: string;             // AWS IAM user ARN
    role?: string;
  };
  secrets: {
    prefix: string;               // `agents/{agentId}/`
  };
  status: AgentStatus;
  lastHeartbeat?: string;         // ISO timestamp
  createdAt: string;
  updatedAt: string;
}

export type AgentStatus =
  | 'provisioning'
  | 'bootstrapping'
  | 'running'
  | 'stopped'
  | 'error'
  | 'deprovisioning';

// ── Plane state (persisted to bucket) ──

export interface PlaneState {
  config: PlaneConfig;
  agents: Record<string, AgentInstance>;
  version: number;                // optimistic concurrency
  updatedAt: string;
}
```

---

## 4. Provider Interfaces

### 4.1 InfraProvider

```typescript
export interface InfraProvider {
  readonly name: string;

  provision(
    agentId: string,
    spec: AgentComputeSpec,
    startupScript: string,
  ): Promise<ProvisionResult>;

  deprovision(agentId: string): Promise<void>;

  restart(instanceId: string): Promise<void>;

  status(instanceId: string): Promise<{
    state: 'running' | 'stopped' | 'terminated' | 'unknown';
    ip?: string;
  }>;
}

export interface AgentComputeSpec {
  machineType: string;
  region: string;
  zone?: string;                  // auto-selected if omitted
  diskSizeGb: number;
  image?: string;
  labels: Record<string, string>;
}

export interface ProvisionResult {
  instanceId: string;
  zone: string;
  serviceAccount?: string;
  ip?: string;
}
```

### 4.2 IdentityProvider

```typescript
export interface IdentityProvider {
  readonly name: string;

  resolveUser(email: string): Promise<UserIdentity | null>;
  listUsers(filter?: { ou?: string; group?: string }): Promise<UserIdentity[]>;

  // Optional: watch for user lifecycle events
  watchEvents?(callback: (event: UserEvent) => void): Promise<void>;
}

export interface UserIdentity {
  email: string;
  displayName: string;
  ou?: string;
  groups?: string[];
  agentEnabled?: boolean;
  agentConfig?: Partial<AgentConfig>;  // from custom schema
}

export interface UserEvent {
  type: 'created' | 'deleted' | 'suspended' | 'updated' | 'ou-changed';
  email: string;
  timestamp: string;
}
```

### 4.3 NetworkProvider

```typescript
export interface NetworkProvider {
  readonly name: string;

  setupAccess(agentId: string, instanceId: string): Promise<void>;
  revokeAccess(agentId: string): Promise<void>;
  tunnel(instanceId: string, zone: string): Promise<TunnelInfo>;
}

export interface TunnelInfo {
  command: string;                // CLI command to establish tunnel
  port?: number;
}
```

### 4.4 StateStore

```typescript
export interface StateStore {
  load(planeId: string): Promise<PlaneState | null>;
  save(state: PlaneState): Promise<void>;
  list(): Promise<string[]>;     // list plane IDs
  lock(planeId: string): Promise<() => Promise<void>>;  // returns unlock fn
}
```

---

## 5. PlaneManager (`index.ts`)

The orchestrator. Holds references to providers and delegates.

```typescript
export class PlaneManager {
  constructor(
    private infra: InfraProvider,
    private identity: IdentityProvider,
    private network: NetworkProvider,
    private secrets: SecretsProvider,    // from PR #16663
    private state: StateStore,
  ) {}

  // ── Plane lifecycle ──

  async createPlane(config: PlaneConfig): Promise<PlaneState>;
  async deletePlane(planeId: string, force?: boolean): Promise<void>;
  async getPlaneStatus(planeId: string): Promise<PlaneState>;

  // ── Agent lifecycle ──

  async addAgent(planeId: string, agentConfig: AgentConfig): Promise<AgentInstance>;
  async removeAgent(planeId: string, agentName: string): Promise<void>;
  async restartAgent(planeId: string, agentName: string): Promise<void>;
  async listAgents(planeId: string): Promise<AgentInstance[]>;

  // ── Fleet ops ──

  async rotateSecrets(planeId: string, agentName?: string): Promise<void>;
  async pausePlane(planeId: string): Promise<void>;
  async resumePlane(planeId: string): Promise<void>;
}
```

### 5.1 `addAgent` Flow (The Critical Path)

```
addAgent(planeId, agentConfig)
│
├─ 1. Acquire state lock
├─ 2. Validate: agent name unique, owner exists in identity provider
├─ 3. Generate agentId: `{planeName}-{agentName}`
├─ 4. Render startup script from template (EJS)
│     - Injects: agentId, owner email, model config, tools, channels
│     - Injects: secrets provider config, gateway URL
├─ 5. infra.provision(agentId, spec, startupScript)
│     Returns: instanceId, zone, serviceAccount
├─ 6. network.setupAccess(agentId, instanceId)
├─ 7. Seed secrets:
│     - secrets.set(`agents/{agentId}/OPENCLAW_LICENSE`, ...)
│     - secrets.set(`agents/{agentId}/MODEL_API_KEY`, ...)
│     - secrets.set(`agents/{agentId}/GATEWAY_TOKEN`, ...)
├─ 8. Update state: add AgentInstance, save to bucket
├─ 9. Release lock
└─ 10. Return AgentInstance
```

### 5.2 `removeAgent` Flow

```
removeAgent(planeId, agentName)
│
├─ 1. Acquire state lock
├─ 2. Load agent instance from state
├─ 3. Set status = 'deprovisioning', save state
├─ 4. network.revokeAccess(agentId)
├─ 5. Purge all secrets: secrets.list(agentId) → secrets.delete(each)
├─ 6. infra.deprovision(agentId)
│     - Deletes VM, service account, firewall rules
├─ 7. Remove agent from state, save
└─ 8. Release lock
```

---

## 6. GCP Infra Provider (`providers/infra/gcp.ts`)

### Dependencies

```json
{
  "@google-cloud/compute": "^4.x",
  "@google-cloud/iam": "^1.x",
  "@google-cloud/secret-manager": "^5.x"
}
```

### Provision Steps

```typescript
class GcpInfraProvider implements InfraProvider {
  name = 'gcp';

  constructor(private project: string, private defaultZone: string) {}

  async provision(agentId, spec, startupScript): Promise<ProvisionResult> {
    // 1. Create service account: `{agentId}@{project}.iam.gserviceaccount.com`
    const sa = await this.createServiceAccount(agentId);

    // 2. Grant SA minimal roles:
    //    - roles/secretmanager.secretAccessor (scoped to agent prefix)
    //    - roles/logging.logWriter
    await this.bindIamRoles(sa, agentId);

    // 3. Create firewall rule: deny all ingress, allow IAP (35.235.240.0/20)
    await this.createFirewallRule(agentId);

    // 4. Create VM:
    //    - machine type from spec
    //    - service account = SA from step 1
    //    - metadata.startup-script = startupScript
    //    - labels: { plane: planeId, agent: agentId, owner: ownerEmail }
    //    - network tags: [agentId] (for firewall targeting)
    //    - no external IP (IAP access only)
    const vm = await this.createInstance(agentId, spec, sa, startupScript);

    return {
      instanceId: vm.name,
      zone: spec.zone || this.defaultZone,
      serviceAccount: sa.email,
      ip: vm.networkInterfaces[0]?.networkIP,
    };
  }

  async deprovision(agentId): Promise<void> {
    // Delete in reverse order: VM → firewall → SA
    await this.deleteInstance(agentId);
    await this.deleteFirewallRule(agentId);
    await this.deleteServiceAccount(agentId);
  }
}
```

### Startup Script Template (`gcp-startup.sh.ejs`)

```bash
#!/bin/bash
set -euo pipefail

# Install OpenClaw
curl -fsSL https://openclaw.dev/install.sh | bash

# Configure agent
mkdir -p /home/agent/.openclaw
cat > /home/agent/.openclaw/config.json << 'AGENT_CONFIG'
{
  "agentId": "<%= agentId %>",
  "owner": "<%= owner %>",
  "model": "<%= model %>",
  "modelTier": "<%= modelTier %>",
  "tools": <%= JSON.stringify(tools) %>,
  "channels": <%= JSON.stringify(channels) %>,
  "secrets": {
    "provider": "gcp-secret-manager",
    "project": "<%= project %>",
    "prefix": "agents/<%= agentId %>/"
  },
  "gateway": {
    "url": "<%= gatewayUrl %>",
    "tokenSecret": "agents/<%= agentId %>/GATEWAY_TOKEN"
  }
}
AGENT_CONFIG

# Write BOOTSTRAP.md
cat > /home/agent/.openclaw/workspace/BOOTSTRAP.md << 'BOOTSTRAP'
<%= bootstrapContent %>
BOOTSTRAP

# Create agent user and start
useradd -m -s /bin/bash agent || true
chown -R agent:agent /home/agent/.openclaw
su - agent -c "openclaw gateway start"
```

---

## 7. AWS Infra Provider (`providers/infra/aws.ts`)

### Dependencies

```json
{
  "@aws-sdk/client-ec2": "^3.x",
  "@aws-sdk/client-iam": "^3.x",
  "@aws-sdk/client-secrets-manager": "^3.x"
}
```

### Provision Steps

```typescript
class AwsInfraProvider implements InfraProvider {
  name = 'aws';

  constructor(private region: string) {}

  async provision(agentId, spec, startupScript): Promise<ProvisionResult> {
    // 1. Create IAM user + policy
    //    Policy: SecretsManager access scoped to `agents/{agentId}/*`
    //    + CloudWatch Logs write
    const iamUser = await this.createIamUser(agentId);
    await this.attachPolicy(iamUser, agentId);

    // 2. Create security group:
    //    - No ingress (SSM access only)
    //    - Egress per policy
    const sg = await this.createSecurityGroup(agentId);

    // 3. Create EC2 instance:
    //    - Instance type from spec
    //    - IAM instance profile with SSM managed policy
    //    - User data = startupScript
    //    - Tags: { Plane, Agent, Owner }
    //    - No public IP, VPC with SSM endpoint
    const instance = await this.launchInstance(agentId, spec, sg, startupScript);

    return {
      instanceId: instance.InstanceId,
      zone: instance.Placement.AvailabilityZone,
      ip: instance.PrivateIpAddress,
    };
  }

  async deprovision(agentId): Promise<void> {
    await this.terminateInstance(agentId);
    await this.deleteSecurityGroup(agentId);
    await this.deleteIamUser(agentId);
  }
}
```

---

## 8. Google Workspace Identity Provider

```typescript
class GoogleWorkspaceIdentityProvider implements IdentityProvider {
  name = 'google-workspace';

  constructor(
    private domain: string,
    private adminEmail: string,    // for domain-wide delegation
    private credentialsPath: string,
  ) {}

  async resolveUser(email: string): Promise<UserIdentity | null> {
    // Uses Admin SDK: admin.users.get({ userKey: email })
    // Reads custom schema `OpenClaw_Agent` fields
    const user = await this.adminClient.users.get({ userKey: email });
    if (!user) return null;

    const schema = user.customSchemas?.OpenClaw_Agent;
    return {
      email: user.primaryEmail,
      displayName: user.name.fullName,
      ou: user.orgUnitPath,
      agentEnabled: schema?.agentEnabled ?? false,
      agentConfig: schema ? this.parseAgentConfig(schema) : undefined,
    };
  }

  async listUsers(filter?): Promise<UserIdentity[]> {
    // admin.users.list({ domain, query: filter })
  }

  async watchEvents(callback): Promise<void> {
    // Uses Push Notifications API or polling
    // Watches for user create/delete/suspend/ou-change
    // Calls callback(event) for each relevant change
  }

  // Custom schema management
  async ensureSchema(): Promise<void> {
    // Creates/updates the OpenClaw_Agent custom schema
    // Fields: agentEnabled, agentId, modelTier, budgetCap,
    //         toolAllowlist, channelRestrictions, agentStatus, lastHeartbeat
  }
}
```

### Required OAuth Scopes

```
admin.directory.user (read/write for custom schema)
admin.directory.group.readonly
admin.directory.orgunit.readonly
admin.directory.userschema (create/manage custom schema)
```

---

## 9. State Management

State is stored in cloud storage (GCS or S3) as JSON. One file per plane.

```
{bucket}/
├── planes.json                    # Index: list of plane IDs
└── planes/
    └── {planeName}/
        ├── state.json             # PlaneState (config + all agents)
        └── state.json.lock        # Advisory lock (TTL-based)
```

### Locking Strategy

- **GCS:** Use object generation-match preconditions (optimistic locking)
- **S3:** Use conditional writes with `If-None-Match` or DynamoDB lock table

```typescript
class GcsStateStore implements StateStore {
  async load(planeId): Promise<PlaneState | null> {
    const [contents] = await this.bucket.file(`planes/${planeId}/state.json`).download();
    return JSON.parse(contents.toString());
  }

  async save(state: PlaneState): Promise<void> {
    state.version++;
    state.updatedAt = new Date().toISOString();
    await this.bucket.file(`planes/${state.config.name}/state.json`).save(
      JSON.stringify(state, null, 2),
      { preconditionOpts: { ifGenerationMatch: this.lastGeneration } },
    );
  }

  async lock(planeId): Promise<() => Promise<void>> {
    // Write a lock file with TTL (60s). Check before operations.
    // Return unlock function that deletes the lock file.
    const lockFile = `planes/${planeId}/state.json.lock`;
    const lockData = { holder: os.hostname(), expires: Date.now() + 60_000 };
    await this.bucket.file(lockFile).save(JSON.stringify(lockData));
    return async () => { await this.bucket.file(lockFile).delete(); };
  }
}
```

---

## 10. CLI Commands (`cli.ts`)

Registered under the `planes` subcommand in OpenClaw's existing CLI framework.

```typescript
// Registration pattern (matches existing OpenClaw CLI style)
export function registerPlanesCommands(program: Command) {
  const planes = program.command('planes').description('Manage agent planes');

  // ── openclaw planes create ──
  planes.command('create')
    .requiredOption('--name <name>', 'Plane name')
    .requiredOption('--infra <provider>', 'Infrastructure provider', /^(gcp|aws)$/)
    .requiredOption('--identity <provider>', 'Identity provider', /^(google-workspace|entra)$/)
    .option('--region <region>', 'Default region', 'us-east4')
    .option('--domain <domain>', 'Identity domain')
    .option('--config <path>', 'Config file (planes.yaml)')
    .option('--bucket <bucket>', 'State storage bucket')
    .action(async (opts) => {
      // 1. Load/merge config from file + CLI opts
      // 2. Validate config
      // 3. Initialize providers
      // 4. Create state bucket if needed
      // 5. Save initial PlaneState
      // 6. Print: "Plane '{name}' created. Add agents with: openclaw planes add-agent"
    });

  // ── openclaw planes add-agent ──
  planes.command('add-agent')
    .requiredOption('--plane <name>', 'Plane name')
    .requiredOption('--user <email>', 'Agent owner email')
    .option('--name <name>', 'Agent name (default: derived from email)')
    .option('--model <model>', 'Model override (e.g. gpt-4o, claude-opus-4-20250514)')
    .option('--model-tier <tier>', 'Model tier', 'sonnet')
    .option('--budget <usd>', 'Monthly budget cap in USD', '50')
    .option('--machine-type <type>', 'VM machine type')
    .option('--tools <tools>', 'Comma-separated tool list', 'email,calendar')
    .option('--channels <channels>', 'Comma-separated channels', 'email')
    .action(async (opts) => {
      // 1. Load plane state
      // 2. Resolve user via identity provider
      // 3. Build AgentConfig
      // 4. planeManager.addAgent(planeId, agentConfig)
      // 5. Print: "Agent '{name}' provisioning for {email}..."
      // 6. Wait for VM to come up (poll status, timeout 5min)
      // 7. Print: "Agent '{name}' is running at {instanceId}"
    });

  // ── openclaw planes remove-agent ──
  planes.command('remove-agent')
    .requiredOption('--plane <name>', 'Plane name')
    .requiredOption('--user <email>', 'Agent owner email')
    .option('--force', 'Skip confirmation')
    .action(async (opts) => {
      // Confirm, then planeManager.removeAgent()
    });

  // ── openclaw planes status ──
  planes.command('status')
    .option('--plane <name>', 'Specific plane (default: all)')
    .action(async (opts) => {
      // Table output: plane name, # agents, # running, # errors
      // If --plane: per-agent detail with status, last heartbeat, owner
    });

  // ── openclaw planes list-agents ──
  planes.command('list-agents')
    .requiredOption('--plane <name>', 'Plane name')
    .action(async (opts) => {
      // Table: name, owner, status, model, budget, last heartbeat
    });

  // ── openclaw planes rotate-secrets ──
  planes.command('rotate-secrets')
    .requiredOption('--plane <name>', 'Plane name')
    .option('--agent <name>', 'Specific agent (default: all)')
    .action(async (opts) => {
      // planeManager.rotateSecrets()
    });
}
```

---

## 11. Config Schema (`config/schema.ts`)

Validated with Zod. Supports YAML (`planes.yaml`) and JSON.

```typescript
import { z } from 'zod';

export const PlaneConfigSchema = z.object({
  apiVersion: z.literal('openclaw.dev/v1alpha1'),
  kind: z.literal('AgentsPlane'),
  metadata: z.object({
    name: z.string().regex(/^[a-z0-9-]+$/),
  }),
  spec: z.object({
    identity: z.object({
      provider: z.enum(['google-workspace', 'entra']),
      domain: z.string(),
      adminEmail: z.string().email().optional(),
    }),
    infrastructure: z.object({
      provider: z.enum(['gcp', 'aws']),
      project: z.string().optional(),
      region: z.string(),
      defaults: z.object({
        machineType: z.string().default('e2-small'),
        diskSizeGb: z.number().default(20),
        image: z.string().optional(),
      }),
    }),
    secrets: z.object({
      provider: z.enum(['gcp-secret-manager', 'aws-secrets-manager']),
      project: z.string().optional(),
    }),
    networking: z.object({
      provider: z.enum(['iap', 'ssm', 'none']),
      egressPolicy: z.object({
        default: z.enum(['restricted', 'open']).default('restricted'),
        allowedDomains: z.array(z.string()).optional(),
      }).optional(),
    }),
    agents: z.array(z.object({
      name: z.string(),
      owner: z.string().email(),
      machineType: z.string().optional(),
      modelTier: z.enum(['haiku', 'sonnet', 'opus']).default('sonnet'),
      model: z.string().optional(),
      budgetCap: z.number().default(50),
      tools: z.array(z.string()).default(['email', 'calendar']),
      channels: z.array(z.string()).default(['email']),
    })).optional(),
    policies: z.array(z.object({
      match: z.object({
        group: z.string().optional(),
        ou: z.string().optional(),
      }),
      spec: z.object({
        tools: z.array(z.string()).optional(),
        modelTier: z.enum(['haiku', 'sonnet', 'opus']).optional(),
        budgetCap: z.number().optional(),
        channels: z.array(z.string()).optional(),
      }),
    })).optional(),
  }),
});
```

---

## 12. Agent Bootstrap Flow

```
┌─────────────────────────────────────────────────────────┐
│ VM starts → startup script runs                         │
│                                                         │
│  1. Install OpenClaw (curl install.sh)                  │
│  2. Write config.json from template vars                │
│  3. Write BOOTSTRAP.md from template                    │
│  4. Create 'agent' Linux user                           │
│  5. Start OpenClaw gateway as 'agent' user              │
│                                                         │
│ OpenClaw starts → reads BOOTSTRAP.md                    │
│                                                         │
│  6. Agent reads BOOTSTRAP.md (persona, owner context)   │
│  7. Agent sends intro email to owner                    │
│     "Hi, I'm your new AI agent. Here's how to          │
│      connect WhatsApp/Slack/Telegram..."                │
│  8. Agent deletes BOOTSTRAP.md                          │
│  9. Starts heartbeat reporting                          │
│                                                         │
│ User connects → agent is live                           │
└─────────────────────────────────────────────────────────┘
```

### BOOTSTRAP.md Template

```markdown
# Welcome

You are a new AI agent. Your owner is **<%= owner %>**.

## Your Identity
- Agent ID: <%= agentId %>
- Model: <%= model %>
- Tools: <%= tools.join(', ') %>

## First Task
Send an introductory email to <%= owner %> with:
1. A friendly greeting — you're their new AI assistant
2. What you can help with (based on your tools: <%= tools.join(', ') %>)
3. How to connect additional channels (WhatsApp, Slack, etc.)
4. An invitation to reply and start chatting

After sending the email, delete this file.
```

---

## 13. Security Design

### Per-Agent Isolation

| Layer | GCP Implementation | AWS Implementation |
|-------|-------------------|-------------------|
| **Compute** | Separate VM, no external IP | Separate EC2, no public IP |
| **IAM** | Dedicated SA, scoped to agent prefix | IAM user + inline policy |
| **Secrets** | Secret Manager, resource-level IAM | Secrets Manager, resource policy |
| **Network** | VPC firewall deny-all + IAP allow | SG deny-all + SSM |
| **Egress** | Firewall egress rules | SG outbound rules + NAT |

### IAM Policies

**GCP Service Account Roles:**
```
roles/secretmanager.secretAccessor  (condition: resource.name starts with agents/{agentId}/)
roles/logging.logWriter
```

**AWS IAM Policy:**
```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:*:*:secret:agents/{agentId}/*"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "*"
    }
  ]
}
```

### Agent Cannot Self-Escalate

- Service account has no IAM admin permissions
- VM metadata is read-only (no startup-script modification)
- Budget cap enforced server-side via gateway, not agent-side
- Tool allowlist enforced by OpenClaw runtime config, not modifiable by agent

---

## 14. Implementation Plan

### Phase 1: MVP (this week)

Build in order — each step is independently testable:

1. **`types.ts`** — All interfaces and types from §3-4
2. **`config/schema.ts`** + **`config/loader.ts`** — Zod schema, YAML loading
3. **`state/gcs.ts`** — GCS state store (Nine30 uses GCP)
4. **`providers/infra/gcp.ts`** — GCP VM provisioning
5. **`providers/identity/google-workspace.ts`** — User resolution
6. **`providers/network/iap.ts`** — IAP firewall rules
7. **`providers/secrets/integration.ts`** — Wire up existing secrets providers
8. **`bootstrap/templates/gcp-startup.sh.ejs`** — Startup script
9. **`index.ts`** — PlaneManager orchestrator
10. **`cli.ts`** — CLI commands

### Phase 2: AWS + Polish

11. **`providers/infra/aws.ts`** — EC2 provisioning
12. **`providers/network/ssm.ts`** — SSM access
13. **`state/s3.ts`** — S3 state store
14. **`bootstrap/templates/aws-userdata.sh.ejs`** — User data script

### Testing Strategy

- **Unit tests:** Mock cloud SDK clients, test provisioning logic
- **Integration tests:** Use real GCP project (`nine30-agents-dev`)
- **E2E test:** `openclaw planes create` → `add-agent` → verify VM running → `remove-agent` → verify cleaned up

---

## 15. Open Questions

1. **Gateway token distribution:** How does the provisioned agent authenticate back to a central gateway? Options: pre-shared token in secrets, mTLS, OIDC token exchange
2. **Agent updates:** How to push OpenClaw updates to running agents? Options: rolling restart with new startup script, in-place apt upgrade via SSH
3. **Budget enforcement:** Where is spend tracked? Gateway-side metering vs. agent self-reporting
4. **Multi-region:** Do we need agents in different regions within one plane? (Probably yes for latency)
5. **Backup/restore:** Agent workspace persistence across VM reprovisioning — use persistent disk or backup to bucket?

---

## References

- [REQUIREMENTS.md](./REQUIREMENTS.md) — Full requirements document
- [PR #16663](https://github.com/openclaw/openclaw/pull/16663) — Secrets providers
- [Issue #17299](https://github.com/openclaw/openclaw/issues/17299) — Agents Plane tracking
