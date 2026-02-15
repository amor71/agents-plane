/**
 * 🤖 Agents Plane — Cloud Function for Agent Provisioning
 *
 * This Cloud Function is triggered by the Apps Script when a user's
 * "AI Agent" toggle is changed in Google Workspace Admin Console.
 *
 * It creates/destroys GCP resources for the agent.
 *
 * Deploy:
 *   gcloud functions deploy provision-agent \
 *     --runtime nodejs20 \
 *     --trigger-http \
 *     --allow-unauthenticated \
 *     --region us-east4 \
 *     --set-env-vars "AUTH_SECRET=your-secret,GCP_PROJECT=your-project,GCP_ZONE=us-east4-b"
 */

const compute = require('@google-cloud/compute');
const { SecretManagerServiceClient } = require('@google-cloud/secret-manager');

const instancesClient = new compute.InstancesClient();
const secretManager = new SecretManagerServiceClient();

const PROJECT = process.env.GCP_PROJECT || process.env.PROJECT_ID || process.env.GCLOUD_PROJECT;
const ZONE = process.env.GCP_ZONE || 'us-east4-b';
const REGION = ZONE.replace(/-[a-z]$/, '');
const AUTH_SECRET = process.env.AUTH_SECRET;
const NETWORK = process.env.NETWORK || 'agents-plane-vpc';
const SUBNET = process.env.SUBNET || 'agents-subnet';
const DEFAULT_VM_TYPE = process.env.DEFAULT_VM_TYPE || 'e2-standard-2';

/**
 * HTTP Cloud Function entry point.
 */
exports.provisionAgent = async (req, res) => {
  // CORS
  res.set('Access-Control-Allow-Origin', '*');
  if (req.method === 'OPTIONS') {
    res.set('Access-Control-Allow-Methods', 'POST');
    res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    return res.status(204).send('');
  }

  // Auth
  const authHeader = req.headers.authorization || '';
  const token = authHeader.replace('Bearer ', '');
  if (AUTH_SECRET && token !== AUTH_SECRET) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  // Parse
  const { email, action, model, budget } = req.body;
  if (!email) {
    return res.status(400).json({ error: 'Missing email' });
  }

  const username = email.split('@')[0];
  const safeName = username.replace(/\./g, '-').toLowerCase();
  const vmName = `agent-${safeName}`;

  try {
    if (action === 'deprovision') {
      await deprovisionAgent(vmName, safeName);
      return res.json({ success: true, action: 'deprovisioned', email });
    }

    const result = await provisionAgent(vmName, safeName, email, model, budget);
    return res.json({ success: true, action: 'provisioned', email, ...result });
  } catch (err) {
    console.error(`Error processing ${action} for ${email}:`, err);
    return res.status(500).json({ error: err.message });
  }
};

/**
 * Provision a new agent VM.
 */
async function provisionAgent(vmName, safeName, email, model = 'claude-opus-4-6', budget = 50) {
  // Check if VM already exists
  try {
    const [instance] = await instancesClient.get({ project: PROJECT, zone: ZONE, instance: vmName });
    if (instance.status === 'TERMINATED') {
      const [startOp] = await instancesClient.start({ project: PROJECT, zone: ZONE, instance: vmName });
      if (startOp && typeof startOp.promise === 'function') await startOp.promise();
      return { status: 'started', vmName };
    }
    return { status: 'already_exists', vmName };
  } catch (err) {
    if (!err.message?.includes('not found') && err.code !== 5) throw err;
    // VM doesn't exist, continue to create
  }

  // Create secret (or update if exists)
  const secretName = `agent-${safeName}-config`;
  const parent = `projects/${PROJECT}`;
  const secretPath = `${parent}/secrets/${secretName}`;

  try {
    await secretManager.createSecret({
      parent,
      secretId: secretName,
      secret: { replication: { automatic: {} } },
    });
    console.log(`Created secret ${secretName}`);
  } catch (err) {
    if (err.code === 6 || err.message?.includes('ALREADY_EXISTS')) {
      console.log(`Secret ${secretName} already exists, adding new version`);
    } else {
      throw err;
    }
  }

  // Always add a new version with latest config
  await secretManager.addSecretVersion({
    parent: secretPath,
    payload: {
      data: Buffer.from(JSON.stringify({ user: email, model, budget })),
    },
  });

  // Startup script
  const startupScript = `#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

logger "🤖 Agents Plane: Starting provisioning..."

# --- 1. System setup ---
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq curl wget git jq unzip

# --- 2. Install Node.js 22 ---
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs

# --- 3. Install OpenClaw ---
npm install -g openclaw
logger "🤖 Agents Plane: OpenClaw CLI installed"

# --- 4. Create agent user ---
useradd -m -s /bin/bash agent || true

# --- 5. Pull agent config from Secret Manager ---
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
AGENT_NAME="\${INSTANCE_NAME#agent-}"
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
TOKEN=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | jq -r '.access_token')
CONFIG=$(curl -s "https://secretmanager.googleapis.com/v1/projects/\${PROJECT_ID}/secrets/agent-\${AGENT_NAME}-config/versions/latest:access" -H "Authorization: Bearer \${TOKEN}" | jq -r '.payload.data' | base64 -d)

OWNER_EMAIL=$(echo "\$CONFIG" | jq -r '.user')
AGENT_MODEL=$(echo "\$CONFIG" | jq -r '.model // "claude-opus-4-6"')
AGENT_BUDGET=$(echo "\$CONFIG" | jq -r '.budget // 50')

# --- 6. Set up agent workspace ---
su - agent -c "mkdir -p ~/.openclaw/workspace"

echo "\$CONFIG" > /home/agent/.openclaw/agent-config.json
chown agent:agent /home/agent/.openclaw/agent-config.json

# --- 7. Write BOOTSTRAP.md (welcome prompt) ---
cat > /home/agent/.openclaw/workspace/BOOTSTRAP.md << 'WELCOME_EOF'
# Welcome

You are a new AI agent, just provisioned on the Agents Plane.

## Your Identity
- Owner: OWNER_EMAIL_PLACEHOLDER
- Model: AGENT_MODEL_PLACEHOLDER
- Agent Name: AGENT_NAME_PLACEHOLDER

## Step 1: Welcome Email
Send an introductory email to your owner (OWNER_EMAIL_PLACEHOLDER) with:
1. A friendly greeting — you're their new AI assistant, provisioned by their organization
2. What you can help with — email, calendar, research, writing, coding, analysis
3. How to connect additional channels (WhatsApp, Slack, Telegram) for easier access
4. An invitation to reply to this email and start chatting

Keep it warm, professional, and concise. You're excited to help but not over the top.

## Step 2: Get to Know Each Other
When your owner replies, have a conversation:
- Ask what they'd like to call you and what vibe they prefer
- Learn about their work, role, and what they need help with
- Create your SOUL.md and IDENTITY.md based on what you learn
- Create USER.md with info about your owner

## Step 3: Set Up Your Own API Key
You're currently running on a shared API key provided by the organization.
For privacy and independence, you need your own.

Ask your owner:
> "One last setup step — I'm currently running on a shared API key from the
> organization. For privacy (so your conversations stay yours) and to avoid
> usage limits, you'll want to set up your own. It takes about 2 minutes:
>
> 1. Go to https://console.anthropic.com/settings/keys
> 2. Create a new API key (name it whatever you like)
> 3. Send me the key here — I'll configure it and delete the message
>
> I'll verify it works before switching over."

When they send the key:
1. Verify it works by checking it starts with \`sk-ant-\`
2. Update your auth config:
   \`\`\`
   Write the new key to ~/.openclaw/agents/main/agent/auth-profiles.json
   replacing the existing anthropic:default token value
   \`\`\`
3. Confirm the new key works (you'll know because you're still running!)
4. Tell your owner: "All set — you're now on your own key. Your conversations are private to you."
5. Delete the message containing the key from chat history if possible

## Step 4: Done
After all steps are complete, delete this BOOTSTRAP.md file. You don't need it anymore — you're you now.
WELCOME_EOF

# Replace placeholders
sed -i "s/OWNER_EMAIL_PLACEHOLDER/\$OWNER_EMAIL/g" /home/agent/.openclaw/workspace/BOOTSTRAP.md
sed -i "s/AGENT_MODEL_PLACEHOLDER/\$AGENT_MODEL/g" /home/agent/.openclaw/workspace/BOOTSTRAP.md
sed -i "s/AGENT_NAME_PLACEHOLDER/\$AGENT_NAME/g" /home/agent/.openclaw/workspace/BOOTSTRAP.md
chown agent:agent /home/agent/.openclaw/workspace/BOOTSTRAP.md

# --- 8. Write AGENTS.md ---
cat > /home/agent/.openclaw/workspace/AGENTS.md << 'AGENTS_EOF'
# AGENTS.md

## First Run
If BOOTSTRAP.md exists, follow it step by step. Don't skip steps.

## Every Session
1. Read SOUL.md — this is who you are
2. Read USER.md — this is who you're helping
3. Read memory/ files for recent context

## API Key Management
Your auth config is at: ~/.openclaw/agents/main/agent/auth-profiles.json

To update your API key, write the new key to that file:
\`\`\`json
{
  "version": 1,
  "profiles": {
    "anthropic:default": {
      "type": "token",
      "provider": "anthropic",
      "token": "NEW_KEY_HERE"
    }
  },
  "lastGood": {
    "anthropic": "anthropic:default"
  }
}
\`\`\`

After writing the file, the next session will use the new key automatically.
If a user sends you an API key, update the file and then delete the message
from your memory/history if possible. Keys should never be stored in memory files.

## Safety
- Don't exfiltrate private data. Ever.
- Don't run destructive commands without asking
- API keys go in auth-profiles.json ONLY — never in memory, logs, or other files
- When in doubt, ask your owner
AGENTS_EOF
chown agent:agent /home/agent/.openclaw/workspace/AGENTS.md

logger "🤖 Agents Plane: Agent \$AGENT_NAME provisioned for \$OWNER_EMAIL (model: \$AGENT_MODEL)"

# --- 9. Pull shared API key + SA key from Secret Manager ---
ANTHROPIC_KEY=$(curl -s "https://secretmanager.googleapis.com/v1/projects/\${PROJECT_ID}/secrets/agents-shared-anthropic-key/versions/latest:access" -H "Authorization: Bearer \${TOKEN}" | jq -r '.payload.data' | base64 -d)

# Get service account key for Gmail API (domain-wide delegation)
SA_KEY_SECRET="agents-plane-sa-key"
SA_KEY_JSON=$(curl -s "https://secretmanager.googleapis.com/v1/projects/\${PROJECT_ID}/secrets/\${SA_KEY_SECRET}/versions/latest:access" -H "Authorization: Bearer \${TOKEN}" | jq -r '.payload.data' | base64 -d)

logger "🤖 Agents Plane: API key and SA key retrieved"

# --- 10. Configure OpenClaw gateway ---
su - agent -c "mkdir -p ~/.openclaw/agents/main/agent"

# Write auth profile with Anthropic key
cat > /home/agent/.openclaw/agents/main/agent/auth-profiles.json << AUTHEOF
{
  "version": 1,
  "profiles": {
    "anthropic:default": {
      "type": "token",
      "provider": "anthropic",
      "token": "\$ANTHROPIC_KEY"
    }
  },
  "lastGood": {
    "anthropic": "anthropic:default"
  }
}
AUTHEOF
chown -R agent:agent /home/agent/.openclaw/agents/

# Write gateway config (must match OpenClaw's expected schema)
GATEWAY_TOKEN=$(openssl rand -hex 32)
cat > /home/agent/.openclaw/openclaw.json << CFGEOF
{
  "agents": {
    "defaults": {
      "workspace": "/home/agent/.openclaw/workspace",
      "models": {
        "anthropic/\$AGENT_MODEL": {}
      },
      "heartbeat": {
        "every": "30m"
      }
    },
    "list": [
      {
        "id": "main",
        "default": true,
        "identity": {
          "name": "\$AGENT_NAME"
        }
      }
    ]
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "\$GATEWAY_TOKEN"
    }
  }
}
CFGEOF
chown agent:agent /home/agent/.openclaw/openclaw.json

# --- 11. Configure email via Gmail API (domain-wide delegation) ---
su - agent -c "mkdir -p ~/.config/himalaya ~/.config/agents-plane"

# Store SA key for OAuth2 token generation
echo "\$SA_KEY_JSON" > /home/agent/.config/agents-plane/sa-key.json
chmod 600 /home/agent/.config/agents-plane/sa-key.json
chown agent:agent /home/agent/.config/agents-plane/sa-key.json

# Write OAuth2 token helper script (uses SA key to impersonate user via Gmail API)
cat > /home/agent/.config/agents-plane/get-gmail-token.py << 'TOKENEOF'
#!/usr/bin/env python3
"""Get OAuth2 access token for Gmail via domain-wide delegation."""
import json, time, base64, hashlib, urllib.request, urllib.parse, sys

SA_KEY_PATH = "/home/agent/.config/agents-plane/sa-key.json"
SCOPES = "https://mail.google.com/"

def b64url(data):
    if isinstance(data, str): data = data.encode()
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def sign_rs256(message, private_key_pem):
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    return key.sign(message.encode(), padding.PKCS1v15(), hashes.SHA256())

def get_token(subject_email):
    with open(SA_KEY_PATH) as f:
        sa = json.load(f)
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}))
    claims = b64url(json.dumps({
        "iss": sa["client_email"],
        "sub": subject_email,
        "scope": SCOPES,
        "aud": "https://oauth2.googleapis.com/token",
        "iat": now, "exp": now + 3600
    }))
    sig = b64url(sign_rs256(f"{header}.{claims}", sa["private_key"]))
    jwt = f"{header}.{claims}.{sig}"
    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": jwt
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
    resp = json.loads(urllib.request.urlopen(req).read())
    print(resp["access_token"])

if __name__ == "__main__":
    get_token(sys.argv[1])
TOKENEOF
chmod +x /home/agent/.config/agents-plane/get-gmail-token.py
chown agent:agent /home/agent/.config/agents-plane/get-gmail-token.py

# Install cryptography for JWT signing
pip3 install cryptography -q 2>/dev/null || apt-get install -y -qq python3-cryptography

DOMAIN=$(echo "\$OWNER_EMAIL" | cut -d@ -f2)
ACCT_NAME=$(echo "\$DOMAIN" | cut -d. -f1)

# Configure himalaya with OAuth2 via command
cat > /home/agent/.config/himalaya/config.toml << EMAILEOF
[accounts.\$ACCT_NAME]
default = true
display-name = "Agent \$AGENT_NAME"
email = "\$OWNER_EMAIL"
folder.alias.inbox = "INBOX"
folder.alias.sent = "[Gmail]/Sent Mail"
folder.alias.drafts = "[Gmail]/Drafts"
folder.alias.trash = "[Gmail]/Trash"

backend.type = "imap"
backend.host = "imap.gmail.com"
backend.port = 993
backend.encryption = "tls"
backend.login = "\$OWNER_EMAIL"
backend.auth.type = "xoauth2"
backend.auth.access-token.cmd = "python3 /home/agent/.config/agents-plane/get-gmail-token.py \$OWNER_EMAIL"

message.send.backend.type = "smtp"
message.send.backend.host = "smtp.gmail.com"
message.send.backend.port = 465
message.send.backend.encryption = "tls"
message.send.backend.login = "\$OWNER_EMAIL"
message.send.backend.auth.type = "xoauth2"
message.send.backend.auth.access-token.cmd = "python3 /home/agent/.config/agents-plane/get-gmail-token.py \$OWNER_EMAIL"

message.send.save-copy = false
EMAILEOF
chown -R agent:agent /home/agent/.config/himalaya/

logger "🤖 Agents Plane: OpenClaw + Gmail (OAuth2 via domain-wide delegation) configured"

# --- 12. Start OpenClaw gateway ---
# OpenClaw uses user-level systemd, so we need lingering + user service

# Enable lingering so user services start at boot (not just on login)
loginctl enable-linger agent

# Find openclaw's node entry point
NODE_BIN=$(which node)
OPENCLAW_MAIN=$(node -e "console.log(require.resolve('openclaw/dist/index.js'))" 2>/dev/null || echo "/usr/lib/node_modules/openclaw/dist/index.js")

# Create user systemd directory
su - agent -c "mkdir -p ~/.config/systemd/user"

cat > /home/agent/.config/systemd/user/openclaw-gateway.service << SVCEOF
[Unit]
Description=OpenClaw Gateway (\$AGENT_NAME)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=\$NODE_BIN \$OPENCLAW_MAIN gateway --port 18789
Restart=always
RestartSec=5
KillMode=process
Environment=HOME=/home/agent
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=OPENCLAW_GATEWAY_PORT=18789
Environment=OPENCLAW_GATEWAY_TOKEN=\$GATEWAY_TOKEN
Environment=OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service
Environment=OPENCLAW_SERVICE_MARKER=openclaw
Environment=OPENCLAW_SERVICE_KIND=gateway

[Install]
WantedBy=default.target
SVCEOF
chown -R agent:agent /home/agent/.config/systemd/

# Enable and start the user service
su - agent -c "XDG_RUNTIME_DIR=/run/user/\$(id -u agent) systemctl --user daemon-reload"
su - agent -c "XDG_RUNTIME_DIR=/run/user/\$(id -u agent) systemctl --user enable openclaw-gateway"
su - agent -c "XDG_RUNTIME_DIR=/run/user/\$(id -u agent) systemctl --user start openclaw-gateway"

logger "🤖 Agents Plane: Gateway started for \$AGENT_NAME — agent is ALIVE"
`;

  // Create VM
  const config = {
    machineType: `zones/${ZONE}/machineTypes/${DEFAULT_VM_TYPE}`,
    tags: { items: ['agent-vm'] },
    labels: {
      'agent-user': safeName,
      'managed-by': 'agents-plane',
    },
    networkInterfaces: [
      {
        network: `projects/${PROJECT}/global/networks/${NETWORK}`,
        subnetwork: `projects/${PROJECT}/regions/${REGION}/subnetworks/${SUBNET}`,
        // No external IP
      },
    ],
    // Per-agent service accounts can be created later for isolation
    // For now, VMs use the default compute service account
    serviceAccounts: [
      {
        email: 'default',
        scopes: ['https://www.googleapis.com/auth/cloud-platform'],
      },
    ],
    disks: [
      {
        boot: true,
        autoDelete: true,
        initializeParams: {
          sourceImage: 'projects/debian-cloud/global/images/family/debian-12',
          diskSizeGb: '20',
          diskType: `zones/${ZONE}/diskTypes/pd-balanced`,
        },
      },
    ],
    metadata: {
      items: [{ key: 'startup-script', value: startupScript }],
    },
  };

  const instanceResource = {
    name: vmName,
    ...config,
  };

  const [operation] = await instancesClient.insert({
    project: PROJECT,
    zone: ZONE,
    instanceResource,
  });

  // Wait for the LRO to complete (v4+ API)
  if (operation && typeof operation.promise === 'function') {
    await operation.promise();
  }

  return { status: 'created', vmName };
}

/**
 * Deprovision (stop) an agent VM. Does NOT delete to preserve data.
 */
async function deprovisionAgent(vmName, safeName) {
  try {
    const [instance] = await instancesClient.get({ project: PROJECT, zone: ZONE, instance: vmName });
    if (instance.status === 'RUNNING') {
      const [stopOp] = await instancesClient.stop({ project: PROJECT, zone: ZONE, instance: vmName });
      if (stopOp && typeof stopOp.promise === 'function') await stopOp.promise();
    }
    return { status: 'stopped', vmName };
  } catch (err) {
    if (err.message?.includes('not found') || err.code === 5) {
      return { status: 'not_found', vmName };
    }
    throw err;
  }
}

// For local testing
if (require.main === module) {
  const express = require('express');
  const app = express();
  app.use(express.json());
  app.all('/provision-agent', (req, res) => exports.provisionAgent(req, res));
  const port = process.env.PORT || 8080;
  app.listen(port, () => console.log(`Listening on :${port}`));
}
