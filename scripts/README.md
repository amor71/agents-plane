# 🤖 Agents Plane — Google Workspace + GCP Integration

**Agents Plane** lets you provision and manage AI agents for your organization directly from Google Workspace. Each user in your domain can be assigned a personal AI agent running on a dedicated GCP VM, managed through the familiar Google Admin Console. Toggle agents on/off per user, set budgets, choose models — all from the same place you manage email and drives.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **macOS** | 12.0+ (Monterey or later) |
| **Google Workspace** | Business Standard or higher, with admin access |
| **GCP Billing** | A billing account linked to your project |
| **Homebrew** | Optional — script offers to install dependencies via brew |

---

## Quick Start

```bash
# Clone and run
git clone https://github.com/amor71/agents-plane.git
cd agents-plane/scripts
./setup.sh

# Or one-liner (when hosted)
curl -fsSL https://agents-plane.openclaw.com/setup.sh | bash
```

That's it. The script walks you through everything interactively.

---

## What the Setup Script Does

The `setup.sh` script runs 10 steps:

### Step 1 · Pre-flight Checks
Verifies `gcloud` CLI, `jq`, and macOS are present. Offers to install missing tools via Homebrew.

### Step 2 · Authentication
Opens a browser window for Google sign-in via `gcloud auth login`. Detects your domain automatically.

### Step 3 · Project Selection
Lists your existing GCP projects and lets you pick one — or create a new one. Checks that billing is enabled.

### Step 4 · Enable APIs
Enables the required GCP APIs:
- Admin SDK (`admin.googleapis.com`)
- Compute Engine (`compute.googleapis.com`)
- IAM (`iam.googleapis.com`)
- Secret Manager (`secretmanager.googleapis.com`)
- Cloud Resource Manager (`cloudresourcemanager.googleapis.com`)
- Cloud Functions (`cloudfunctions.googleapis.com`)
- Cloud Build (`cloudbuild.googleapis.com`)

### Step 5 · Service Account
Creates `openclaw-workspace-admin` service account with:
- Domain-wide delegation enabled
- JSON key saved to `~/.openclaw/agents-plane/workspace-admin-key.json`
- IAM roles: Compute Admin, SA Admin, Secret Manager Admin, IAP Tunnel

### Step 6 · Workspace Delegation (Manual)
Displays instructions for the one manual step — adding domain-wide delegation in the Google Admin Console. Provides the Client ID and scopes to copy-paste.

### Step 7 · Configuration
Prompts for plane name, GCP region, default VM type, and default AI model.

### Step 8 · Save Config
Writes everything to `~/.openclaw/agents-plane/config.json`.

### Step 9 · Verification
Tests that all APIs, service accounts, keys, and configs are valid.

### Step 10 · Summary
Prints a beautiful summary with next steps.

---

## After Setup: Provision Your First Agent

```bash
# Basic
./provision-agent.sh alice@yourcompany.com

# With options
./provision-agent.sh alice@yourcompany.com \
  --model gpt-4o \
  --budget 100 \
  --vm-type e2-medium \
  --disk 40

# Dry run (see what would happen)
./provision-agent.sh alice@yourcompany.com --dry-run
```

### What `provision-agent.sh` Creates

1. **VPC Network** — `agents-plane-vpc` with private subnet (shared, created once)
2. **Firewall Rules** — IAP SSH only, deny all external traffic
3. **Service Account** — Per-agent, with minimal permissions
4. **Secret** — Agent config in Secret Manager, accessible only to that agent
5. **Compute Instance** — Debian 12 VM with OpenClaw pre-installed via startup script

### Check Status

```bash
./status.sh
```

Shows all provisioned agents, their VM status, models, budgets, and infrastructure health.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Google Workspace                          │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Admin Console                                       │   │
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
│                                                              │
│  ┌──────────────────────────────────────────────┐           │
│  │  VPC: agents-plane-vpc (no external IPs)     │           │
│  │                                               │           │
│  │  ┌────────────┐  ┌────────────┐              │           │
│  │  │ agent-alice│  │ agent-bob  │              │           │
│  │  │ e2-standard-2   │  │ e2-standard-2   │              │           │
│  │  │ OpenClaw   │  │ OpenClaw   │              │           │
│  │  └──────┬─────┘  └──────┬─────┘              │           │
│  │         │               │                     │           │
│  │         ▼               ▼                     │           │
│  │  ┌──────────────────────────────┐            │           │
│  │  │  Secret Manager              │            │           │
│  │  │  agent-alice-config          │            │           │
│  │  │  agent-bob-config            │            │           │
│  │  └──────────────────────────────┘            │           │
│  └──────────────────────────────────────────────┘           │
│                                                              │
│  Access: IAP Tunnel only (SSH via gcloud)                    │
└──────────────────────────────────────────────────────────────┘
```

---

## Google Workspace Automation

The Admin Console can't directly run scripts, but you can create a seamless flow:

### How It Works

1. **Custom Schema**: A custom user attribute "AI Agent Enabled" appears in each user's profile
2. **Apps Script**: Polls for changes every 5 minutes, detects when the toggle changes
3. **Cloud Function**: Receives the event and provisions/deprovisions the agent

### Setup

#### 1. Deploy the Cloud Function

```bash
cd examples/cloud-function
gcloud functions deploy provision-agent \
  --runtime nodejs20 \
  --trigger-http \
  --allow-unauthenticated \
  --region us-east4 \
  --set-env-vars "AUTH_SECRET=$(openssl rand -hex 32),GCP_PROJECT=$PROJECT_ID,GCP_ZONE=us-east4-b"
```

#### 2. Set Up Apps Script

1. Go to [script.google.com](https://script.google.com)
2. Create a new project
3. Paste the contents of `examples/apps-script-trigger.js`
4. Update `CLOUD_FUNCTION_URL` with your deployed function URL
5. Add the `AUTH_SECRET` to Script Properties
6. Enable the **Admin SDK** advanced service
7. Run `createCustomSchema()` once to add the custom user fields
8. Set up a time-based trigger for `pollForAgentChanges` (every 5 minutes)

#### 3. Use It

In Google Admin Console:
1. Go to **Directory → Users**
2. Click on the user you want to enable
3. Click **User information** (top of the user page)
4. Scroll down past the default fields (department, building, etc.) to **Agent Configuration** under *Custom attributes*
5. Fill in:
   - **Agent Enabled** → `Yes`
   - **Agent Model** → the model name, e.g. `claude-opus-4-6`, `gpt-4o`, or `gemini-pro`
   - **Monthly Budget** → a number in USD, e.g. `50`, `100`, `200` (no dollar sign)
6. Click **Save**

Within 5 minutes, the agent VM will be provisioned automatically.

---

## Manual Setup Alternative

If you prefer not to run the script, here's what to do manually:

### 1. Install Prerequisites
```bash
brew install --cask google-cloud-sdk
brew install jq
```

### 2. Authenticate & Select Project
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### 3. Enable APIs
```bash
gcloud services enable \
  admin.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com
```

### 4. Create Service Account
```bash
gcloud iam service-accounts create openclaw-workspace-admin \
  --display-name="OpenClaw Workspace Admin"

# Generate key
mkdir -p ~/.openclaw/agents-plane
gcloud iam service-accounts keys create ~/.openclaw/agents-plane/workspace-admin-key.json \
  --iam-account=openclaw-workspace-admin@YOUR_PROJECT.iam.gserviceaccount.com

# Grant roles
for role in compute.admin iam.serviceAccountAdmin secretmanager.admin iap.tunnelResourceAccessor; do
  gcloud projects add-iam-policy-binding YOUR_PROJECT \
    --member="serviceAccount:openclaw-workspace-admin@YOUR_PROJECT.iam.gserviceaccount.com" \
    --role="roles/$role"
done
```

### 5. Domain-Wide Delegation
1. Get the Client ID: `jq -r '.client_id' ~/.openclaw/agents-plane/workspace-admin-key.json`
2. Go to https://admin.google.com/ac/owl/domainwidedelegation
3. Add new → paste Client ID → paste scopes:
   ```
   https://www.googleapis.com/auth/admin.directory.user,https://www.googleapis.com/auth/admin.directory.user.security,https://www.googleapis.com/auth/admin.directory.userschema,https://www.googleapis.com/auth/cloud-platform
   ```

### 6. Create Config
```bash
cat > ~/.openclaw/agents-plane/config.json << 'EOF'
{
  "plane": { "name": "YourCompany", "version": "1.0.0" },
  "gcp": {
    "project_id": "YOUR_PROJECT",
    "region": "us-east4",
    "zone": "us-east4-b",
    "default_vm_type": "e2-standard-2",
    "service_account": "openclaw-workspace-admin@YOUR_PROJECT.iam.gserviceaccount.com",
    "key_file": "~/.openclaw/agents-plane/workspace-admin-key.json"
  },
  "workspace": { "domain": "yourcompany.com", "admin_email": "admin@yourcompany.com" },
  "agents": { "default_model": "gpt-4o", "network": "agents-plane-vpc", "subnet": "agents-subnet", "firewall_tag": "agent-vm" }
}
EOF
```

---

## Troubleshooting

### "Permission denied" when running setup.sh
```bash
chmod +x setup.sh
```

### "Billing not enabled" error
Visit https://console.cloud.google.com/billing and link a billing account to your project.

### Service account key generation fails
You need the `iam.serviceAccountKeyAdmin` role on the project. Ask your org admin to grant it.

### Domain-wide delegation not working
- Ensure you used the **Client ID** (numeric), not the email address
- Scopes must be comma-separated, no spaces
- Changes can take up to 24 hours to propagate (usually ~5 minutes)

### VM creation fails with quota error
Request a quota increase at https://console.cloud.google.com/iam-admin/quotas or choose a different region.

### "API not enabled" errors
```bash
gcloud services enable APINAME.googleapis.com --project=YOUR_PROJECT
```

### Can't SSH to agent VM
Agent VMs have no external IP. Use IAP tunnel:
```bash
gcloud compute ssh VM_NAME --zone=ZONE --tunnel-through-iap
```

---

## Security Notes

### Principle of Least Privilege

- **Workspace Admin SA**: Has broad GCP permissions but Workspace access is scoped to specific APIs via domain-wide delegation
- **Agent SAs**: Each agent gets its own service account with only:
  - `secretmanager.secretAccessor` (read own config only)
  - `logging.logWriter` (write logs)
  - `monitoring.metricWriter` (write metrics)
- **Network**: VMs are in a private VPC with no external IPs. Access is only via IAP tunnel.
- **Firewall**: Only port 22 from Google's IAP range (35.235.240.0/20). All other external traffic is denied.

### Key Files
- `workspace-admin-key.json` is stored with `chmod 600` (owner-only read)
- Rotate keys periodically: delete old key → generate new one via `gcloud`

### Scopes Granted
| Scope | Purpose |
|---|---|
| `admin.directory.user` | Read user profiles to detect agent toggle |
| `admin.directory.user.security` | Manage user security settings |
| `admin.directory.userschema` | Read/write custom schema fields |
| `cloud-platform` | Manage GCP resources (VMs, secrets, etc.) |

---

## FAQ

**Q: How much does each agent cost?**
A: The default `e2-standard-2` VM costs ~$50/month. Add model API costs based on usage. The `--budget` flag sets a soft cap.

**Q: Can I use this with Google Workspace for Education?**
A: Yes, as long as you have admin access and a linked GCP billing account.

**Q: Can multiple users share a VM?**
A: Currently each user gets their own VM for isolation. Multi-tenant support is planned.

**Q: How do I update an agent's model or budget?**
A: Update the secret in Secret Manager, then restart the VM:
```bash
echo '{"user":"alice@co.com","model":"claude-4","budget":100}' | \
  gcloud secrets versions add agent-alice-config --data-file=-
gcloud compute instances reset agent-alice --zone=us-east4-b
```

**Q: Is the setup script safe to run multiple times?**
A: Yes. It's fully idempotent — it skips resources that already exist.

**Q: Can I tear everything down?**
A: Delete the VMs, service accounts, secrets, and VPC. Or delete the entire GCP project.

---

## File Structure

```
scripts/
├── setup.sh                          # Interactive setup (run first)
├── provision-agent.sh                # Provision agent for a user
├── status.sh                         # Dashboard / health check
├── README.md                         # This file
└── examples/
    ├── apps-script-trigger.js        # Google Apps Script for automation
    └── cloud-function/
        ├── index.js                  # Cloud Function for provisioning
        └── package.json
```

Config files (created by setup.sh):
```
~/.openclaw/agents-plane/
├── config.json                       # Plane configuration
├── workspace-admin-key.json          # Service account key (chmod 600)
└── agents/
    ├── alice.json                    # Per-agent records
    └── bob.json
```
