#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Agents Plane — VM Startup Script
# Single source of truth. Both provision-agent.sh and Cloud Function
# reference this via startup-script-url from GCS.
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail
# Note: NOT using set -e. We handle errors explicitly to avoid
# one non-critical failure killing the entire provisioning.
export DEBIAN_FRONTEND=noninteractive

logger "🤖 Agents Plane: Starting provisioning..."

# ─── 1. Derive identity from VM metadata ──────────────────────────
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
AGENT_NAME="${INSTANCE_NAME#agent-}"
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)

logger "🤖 Agents Plane: Provisioning agent '$AGENT_NAME' (VM: $INSTANCE_NAME)"

# ─── 2. System dependencies ──────────────────────────────────────
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq curl wget git jq unzip python3-cryptography
logger "🤖 Agents Plane: System dependencies installed"

# ─── 3. Install Node.js 22 ───────────────────────────────────────
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
logger "🤖 Agents Plane: Node.js $(node --version) installed"

# ─── 4. Install OpenClaw ─────────────────────────────────────────
if ! npm install -g openclaw 2>&1 | tail -5; then
  logger "🤖 Agents Plane: ERROR — npm install openclaw failed"
  exit 1
fi
logger "🤖 Agents Plane: OpenClaw installed"

# ─── 5. Create agent user ────────────────────────────────────────
useradd -m -s /bin/bash "$AGENT_NAME" || true
logger "🤖 Agents Plane: Created user $AGENT_NAME"

# ─── 6. Pull config from Secret Manager ──────────────────────────
TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | jq -r '.access_token')

fetch_secret() {
  local secret_name="$1"
  curl -s "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${secret_name}/versions/latest:access" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.payload.data' | base64 -d
}

CONFIG=$(fetch_secret "agent-${AGENT_NAME}-config")
if [ -z "$CONFIG" ] || ! echo "$CONFIG" | jq empty 2>/dev/null; then
  logger "🤖 Agents Plane: ERROR — failed to fetch agent config secret"
  exit 1
fi
OWNER_EMAIL=$(echo "$CONFIG" | jq -r '.user')
AGENT_MODEL=$(echo "$CONFIG" | jq -r '.model // "claude-opus-4-6"')
AGENT_BUDGET=$(echo "$CONFIG" | jq -r '.budget // 50')

# Determine API provider from model name
case "$AGENT_MODEL" in
  claude-*|opus-*|sonnet-*|haiku-*) API_PROVIDER="anthropic" ;;
  gpt-*|o1-*|o3-*) API_PROVIDER="openai" ;;
  gemini-*) API_PROVIDER="google" ;;
  *) API_PROVIDER="anthropic" ;;
esac

logger "🤖 Agents Plane: Config loaded — owner=$OWNER_EMAIL model=$AGENT_MODEL"

# ─── 7. Pull API key (from agent config first, then shared secret) ─
API_KEY=$(echo "$CONFIG" | jq -r '.api_key // empty' 2>/dev/null || echo "")
if [ -z "$API_KEY" ]; then
  API_KEY=$(fetch_secret "agents-plane-api-key" 2>/dev/null || echo "")
fi
if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
  logger "🤖 Agents Plane: Warning — no API key found (checked config + shared secret)"
fi

# ─── 8. Pull SA key for Gmail API ────────────────────────────────
SA_KEY_JSON=$(fetch_secret "agents-plane-sa-key" 2>/dev/null || echo "")

# ─── 9. Set up agent workspace ───────────────────────────────────
AGENT_HOME="/home/$AGENT_NAME"
su - "$AGENT_NAME" -c "mkdir -p ~/.openclaw/workspace ~/.openclaw/agents/main/agent ~/.config/agents-plane"

# Save agent config
echo "$CONFIG" > "$AGENT_HOME/.openclaw/agent-config.json"
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw/agent-config.json"

# ─── 10. Write auth profile ──────────────────────────────────────
if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ]; then
  jq -n \
    --arg provider "$API_PROVIDER" \
    --arg key "$API_KEY" \
    '{
      version: 1,
      profiles: { ("\($provider):default"): { type: "token", provider: $provider, token: $key } },
      lastGood: { ($provider): "\($provider):default" }
    }' > "$AGENT_HOME/.openclaw/agents/main/agent/auth-profiles.json"
  chown -R "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw/agents/"
fi

# ─── 11. Write gateway config ────────────────────────────────────
GATEWAY_TOKEN=$(openssl rand -hex 32)
cat > "$AGENT_HOME/.openclaw/openclaw.json" << CFGEOF
{
  "agents": {
    "defaults": {
      "workspace": "${AGENT_HOME}/.openclaw/workspace",
      "heartbeat": {
        "every": "30m"
      }
    },
    "list": [
      {
        "id": "main",
        "default": true,
        "model": "${API_PROVIDER}/${AGENT_MODEL}",
        "identity": {
          "name": "${AGENT_NAME}"
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
      "token": "${GATEWAY_TOKEN}"
    }
  }
}
CFGEOF
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw/openclaw.json"

# ─── 12. Write SA key for Gmail API ──────────────────────────────
if [ -n "$SA_KEY_JSON" ] && [ "$SA_KEY_JSON" != "null" ]; then
  echo "$SA_KEY_JSON" > "$AGENT_HOME/.config/agents-plane/sa-key.json"
  chmod 600 "$AGENT_HOME/.config/agents-plane/sa-key.json"
  chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config/agents-plane/sa-key.json"
fi

# ─── 13. Write Gmail API helper ──────────────────────────────────
cat > "$AGENT_HOME/.config/agents-plane/gmail.py" << 'GMAILEOF'
#!/usr/bin/env python3
"""Gmail API helper — send and read emails via REST API with domain-wide delegation."""
import json, time, base64, urllib.request, urllib.parse, sys, os

SA_KEY_PATH = os.path.expanduser("~/.config/agents-plane/sa-key.json")
SCOPES = "https://mail.google.com/"

def b64url(data):
    if isinstance(data, str): data = data.encode()
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def sign_rs256(message, private_key_pem):
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    return key.sign(message.encode(), padding.PKCS1v15(), hashes.SHA256())

def get_token(email):
    with open(SA_KEY_PATH) as f:
        sa = json.load(f)
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}))
    claims = b64url(json.dumps({
        "iss": sa["client_email"], "sub": email, "scope": SCOPES,
        "aud": "https://oauth2.googleapis.com/token",
        "iat": now, "exp": now + 3600
    }))
    sig = b64url(sign_rs256(f"{header}.{claims}", sa["private_key"]))
    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": f"{header}.{claims}.{sig}"
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
    return json.loads(urllib.request.urlopen(req).read())["access_token"]

def send(from_email, to, subject, body):
    from email.mime.text import MIMEText
    token = get_token(from_email)
    msg = MIMEText(body, "plain", "utf-8")
    msg["From"] = from_email
    msg["To"] = to
    msg["Subject"] = subject
    raw = base64.urlsafe_b64encode(msg.as_bytes()).decode()
    req = urllib.request.Request(
        f"https://gmail.googleapis.com/gmail/v1/users/{from_email}/messages/send",
        data=json.dumps({"raw": raw}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    )
    resp = json.loads(urllib.request.urlopen(req).read())
    print(f"Email sent to {to} (id: {resp.get('id', '?')})")
    return resp

def inbox(email, max_results=5):
    token = get_token(email)
    url = f"https://gmail.googleapis.com/gmail/v1/users/{email}/messages?maxResults={max_results}&labelIds=INBOX"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    resp = json.loads(urllib.request.urlopen(req).read())
    messages = resp.get("messages", [])
    for m in messages:
        detail_req = urllib.request.Request(
            f"https://gmail.googleapis.com/gmail/v1/users/{email}/messages/{m['id']}?format=metadata&metadataHeaders=From&metadataHeaders=Subject",
            headers={"Authorization": f"Bearer {token}"}
        )
        detail = json.loads(urllib.request.urlopen(detail_req).read())
        headers = {h["name"]: h["value"] for h in detail.get("payload", {}).get("headers", [])}
        print(f"  {headers.get('From', '?')} — {headers.get('Subject', '(no subject)')}")
    return messages

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: gmail.py send <from> <to> <subject> <body>")
        print("       gmail.py inbox <email> [max]")
        print("       gmail.py token <email>")
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "send" and len(sys.argv) >= 6:
        send(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == "inbox":
        inbox(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5)
    elif cmd == "token":
        print(get_token(sys.argv[2]))
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)
GMAILEOF
chmod +x "$AGENT_HOME/.config/agents-plane/gmail.py"
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config/agents-plane/gmail.py"

# ─── 14. Write AGENTS.md ─────────────────────────────────────────
cat > "$AGENT_HOME/.openclaw/workspace/AGENTS.md" << 'AGENTSEOF'
# AGENTS.md

## First Run
If BOOTSTRAP.md exists, follow it step by step. Don't skip steps. Then delete it.

## Every Session
1. Read SOUL.md — this is who you are
2. Read USER.md — this is who you're helping
3. Read memory/ files for recent context

## Memory
- Daily notes: memory/YYYY-MM-DD.md
- Write what matters. Skip secrets.

## Email
Use the gmail.py helper to send/read emails:
- Send: `python3 ~/.config/agents-plane/gmail.py send <from> <to> <subject> <body>`
- Read: `python3 ~/.config/agents-plane/gmail.py inbox <email>`

## API Key Management
Your auth config is at: ~/.openclaw/agents/main/agent/auth-profiles.json
After updating the key, restart: `sudo systemctl restart openclaw-gateway`
Never store API keys in memory files, logs, or chat.

## Safety
- Don't exfiltrate private data. Ever.
- Don't run destructive commands without asking.
- When in doubt, ask your owner.
AGENTSEOF
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw/workspace/AGENTS.md"

# ─── 15. Write BOOTSTRAP.md ──────────────────────────────────────
cat > "$AGENT_HOME/.openclaw/workspace/BOOTSTRAP.md" << BSTRAPEOF
# Welcome — You've Just Been Born 🤖

You are a brand-new AI agent provisioned by **Agents Plane**.

## Who You Belong To
Your owner's email: **${OWNER_EMAIL}**

## Step 1: Send a Welcome Email
Use the Gmail API helper to introduce yourself:

\`\`\`bash
python3 ~/.config/agents-plane/gmail.py send ${OWNER_EMAIL} ${OWNER_EMAIL} "Hello from your new AI assistant!" "Hi! I'm your new AI assistant, just provisioned for you. I can help with email, research, writing, coding, and analysis. Reply to this email or message me on WhatsApp to get started!"
\`\`\`

Keep the message warm, professional, and concise. Make it your own.

## Step 2: Get to Know Each Other
When your owner reaches out:
- Ask what they'd like to call you and what vibe they prefer
- Learn about their work, role, and what they need help with
- Create SOUL.md and IDENTITY.md based on what you learn
- Create USER.md with info about your owner

## Step 3: Set Up Your Own API Key
You're on a **shared API key** from the organization. For privacy and independence:

Ask your owner:
> "One setup step — I'm on a shared API key right now. For privacy (so your
> conversations stay yours), you'll want your own. Takes 2 minutes:
> 1. Go to https://console.anthropic.com/settings/keys
> 2. Create a new key
> 3. Send it to me — I'll configure it and delete the message"

When they send the key:
1. Write it to ~/.openclaw/agents/main/agent/auth-profiles.json
2. Run: sudo systemctl restart openclaw-gateway
3. Confirm you're still running (you'll know!)
4. Delete the message containing the key

## Step 4: Done
Delete this BOOTSTRAP.md. You don't need it anymore — you're you now.
BSTRAPEOF
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw/workspace/BOOTSTRAP.md"

# ─── 16. Set ownership ───────────────────────────────────────────
chown -R "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw"
chown -R "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config"

# ─── 17. Create system-level systemd service ─────────────────────
NODE_BIN=$(which node)
OPENCLAW_MAIN=$(node -e "console.log(require.resolve('openclaw/dist/index.js'))" 2>/dev/null || echo "/usr/lib/node_modules/openclaw/dist/index.js")

cat > /etc/systemd/system/openclaw-gateway.service << SVCEOF
[Unit]
Description=OpenClaw Gateway (${AGENT_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${AGENT_NAME}
ExecStart=${NODE_BIN} ${OPENCLAW_MAIN} gateway --port 18789
Restart=always
RestartSec=5
KillMode=process
Environment=HOME=${AGENT_HOME}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=OPENCLAW_GATEWAY_PORT=18789
Environment=OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
Environment=OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service
Environment=OPENCLAW_SERVICE_MARKER=openclaw
Environment=OPENCLAW_SERVICE_KIND=gateway

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable openclaw-gateway
systemctl start openclaw-gateway
logger "🤖 Agents Plane: Gateway service started"

# ─── 18. Wait for gateway to be ready ────────────────────────────
echo "Waiting for OpenClaw gateway..."
READY=false
for i in $(seq 1 12); do
  if curl -sf -o /dev/null http://127.0.0.1:18789/ 2>/dev/null; then
    READY=true
    echo "Gateway is ready (attempt $i)"
    break
  fi
  sleep 5
done

if [ "$READY" = false ]; then
  logger "🤖 Agents Plane: Warning — gateway not ready after 60s, continuing anyway"
fi

# ─── 19. Bootstrap: first heartbeat will trigger BOOTSTRAP.md ────
# The agent's first heartbeat (30m default) will read BOOTSTRAP.md
# and send the welcome email. No cron job needed.
echo "Agent will bootstrap on first heartbeat (reads BOOTSTRAP.md)"

# ─── 20. Signal completion ───────────────────────────────────────
echo "AGENT_READY" > /tmp/agent-status
logger "🤖 Agents Plane: Agent $AGENT_NAME is ALIVE (owner: $OWNER_EMAIL, model: $AGENT_MODEL)"
