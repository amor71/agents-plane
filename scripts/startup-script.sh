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
apt-get install -y -qq curl wget git jq unzip python3-cryptography python3-qrcode
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
# Allow agent to restart its own gateway
echo "$AGENT_NAME ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart openclaw-gateway, /usr/bin/systemctl stop openclaw-gateway, /usr/bin/systemctl start openclaw-gateway" > /etc/sudoers.d/openclaw-agent
chmod 440 /etc/sudoers.d/openclaw-agent
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

# ─── 7. Pull Slack tokens + email proxy secret ───────────────────
EMAIL_PROXY_SECRET=$(fetch_secret "agents-plane-email-proxy-secret" 2>/dev/null || echo "")
if [ -n "$EMAIL_PROXY_SECRET" ] && [ "$EMAIL_PROXY_SECRET" != "null" ]; then
  logger "🤖 Agents Plane: Email proxy secret loaded"
else
  logger "🤖 Agents Plane: WARNING — email proxy secret not found"
fi

# Slack tokens (optional — used when agent connects via Slack)
SLACK_BOT_TOKEN=$(fetch_secret "agents-plane-slack-bot-token" 2>/dev/null || echo "")
SLACK_APP_TOKEN=$(fetch_secret "agents-plane-slack-app-token" 2>/dev/null || echo "")
if [ -n "$SLACK_BOT_TOKEN" ] && [ "$SLACK_BOT_TOKEN" != "null" ]; then
  SLACK_AVAILABLE=true
  logger "🤖 Agents Plane: Slack tokens loaded"
else
  SLACK_AVAILABLE=false
  logger "🤖 Agents Plane: No Slack tokens found (Slack channel unavailable)"
fi

# ─── 8. Set up agent workspace ───────────────────────────────────
AGENT_HOME="/home/$AGENT_NAME"
su - "$AGENT_NAME" -c "mkdir -p ~/.openclaw/workspace ~/.openclaw/workspace/memory ~/.openclaw/agents/main/agent ~/.config/agents-plane"

# Save agent config
echo "$CONFIG" > "$AGENT_HOME/.openclaw/agent-config.json"
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw/agent-config.json"

# ─── 9. Write fetch-agent-key.sh (ExecStartPre) ──────────────────
cat > /usr/local/bin/fetch-agent-key.sh << 'FETCHEOF'
#!/bin/bash
# Fetch API key from Secret Manager at boot — key never persists between restarts
TOKEN=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | jq -r '.access_token')
PROJECT=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")
AGENT=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/name" | sed 's/^agent-//')
HOME="/home/$AGENT"

# Per-agent key first, then shared fallback
API_KEY=""
for secret in "agent-${AGENT}-api-key" "agents-plane-api-key"; do
  API_KEY=$(curl -sf "https://secretmanager.googleapis.com/v1/projects/${PROJECT}/secrets/${secret}/versions/latest:access" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.payload.data // empty' | base64 -d 2>/dev/null)
  if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ]; then
    break
  fi
  API_KEY=""
done

if [ -n "$API_KEY" ]; then
  MODEL=$(jq -r '.agents.list[0].model // "anthropic/claude-opus-4-6"' "$HOME/.openclaw/openclaw.json" 2>/dev/null)
  PROVIDER="${MODEL%%/*}"
  [ -z "$PROVIDER" ] && PROVIDER="anthropic"

  mkdir -p "$HOME/.openclaw/agents/main/agent"
  jq -n --arg p "$PROVIDER" --arg k "$API_KEY" \
    '{version:1,profiles:{("\($p):default"):{type:"token",provider:$p,token:$k}},lastGood:{($p):"\($p):default"}}' \
    > "$HOME/.openclaw/agents/main/agent/auth-profiles.json"
  chown "$AGENT:$AGENT" "$HOME/.openclaw/agents/main/agent/auth-profiles.json"
  logger "🤖 Agents Plane: API key loaded from Secret Manager"
else
  logger "🤖 Agents Plane: Warning — no API key found in Secret Manager"
fi
FETCHEOF
chmod +x /usr/local/bin/fetch-agent-key.sh

# ─── 10. Write store_key.py (agent stores user's key in SM) ──────
cat > "$AGENT_HOME/.config/agents-plane/store_key.py" << 'STOREEOF'
#!/usr/bin/env python3
"""Store an API key in GCP Secret Manager via VM metadata auth."""
import json, sys, urllib.request, base64

def get_meta(path):
    req = urllib.request.Request(
        f"http://metadata.google.internal/computeMetadata/v1/{path}",
        headers={"Metadata-Flavor": "Google"})
    return urllib.request.urlopen(req).read().decode()

def store_key(api_key):
    token = json.loads(get_meta(
        "instance/service-accounts/default/token"))["access_token"]
    project = get_meta("project/project-id")
    agent = get_meta("instance/name").replace("agent-", "", 1)
    secret_name = f"agent-{agent}-api-key"
    headers = {"Authorization": f"Bearer {token}",
               "Content-Type": "application/json"}

    # Create secret (ignore 409 = already exists)
    try:
        req = urllib.request.Request(
            f"https://secretmanager.googleapis.com/v1/projects/{project}/secrets",
            data=json.dumps({"secretId": secret_name,
                           "replication": {"automatic": {}}}).encode(),
            headers=headers)
        urllib.request.urlopen(req)
        print(f"Created secret {secret_name}")
    except urllib.error.HTTPError as e:
        if e.code != 409: raise
        print(f"Secret {secret_name} exists, adding new version")

    # Add version
    payload = base64.b64encode(api_key.encode()).decode()
    req = urllib.request.Request(
        f"https://secretmanager.googleapis.com/v1/projects/{project}/secrets/{secret_name}:addVersion",
        data=json.dumps({"payload": {"data": payload}}).encode(),
        headers=headers)
    resp = json.loads(urllib.request.urlopen(req).read())
    print(f"Key stored (version: {resp['name'].split('/')[-1]})")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: store_key.py <api-key>")
        sys.exit(1)
    store_key(sys.argv[1])
STOREEOF
chmod +x "$AGENT_HOME/.config/agents-plane/store_key.py"
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config/agents-plane/store_key.py"

# ─── 10b. Write send_qr.py (atomic QR email delivery) ───────────
cat > "$AGENT_HOME/.config/agents-plane/send_qr.py" << 'SENDQREOF'
#!/usr/bin/env python3
"""Atomic WhatsApp QR email delivery. Takes base64 PNG, emails immediately."""
import sys, os, base64, time, subprocess, re

def email_qr(owner_email, qr_png_path):
    gmail_py = os.path.expanduser("~/.config/agents-plane/gmail.py")
    html = (
        "<h2>⚡ Scan this QR code with WhatsApp NOW</h2>"
        "<p><b>Open WhatsApp → Settings → Linked Devices → Link a Device</b></p>"
        "<p><img src='cid:qrcode' width='300'/></p>"
        "<p>⚠️ This code expires in about 60 seconds! Scan it immediately.</p>"
        "<p>If it expired, just reply <b>connect</b> again and I'll send a fresh one.</p>"
    )
    result = subprocess.run([
        "python3", gmail_py, "send_html",
        owner_email, owner_email,
        "⚡ Scan this QR NOW — 60 seconds!",
        html,
        f"qrcode:{qr_png_path}"
    ], capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        print(f"Email error: {result.stderr}", file=sys.stderr)
    return result.returncode == 0

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 send_qr.py <owner_email> <base64_png_data>", file=sys.stderr)
        print("   OR: echo <data> | python3 send_qr.py <owner_email> -", file=sys.stderr)
        sys.exit(1)
    owner_email = sys.argv[1]
    b64_data = sys.stdin.read().strip() if sys.argv[2] == "-" else sys.argv[2]
    b64_data = re.sub(r'^data:image/png;base64,', '', b64_data)
    qr_path = "/tmp/whatsapp-qr.png"
    try:
        png_bytes = base64.b64decode(b64_data)
        with open(qr_path, 'wb') as f:
            f.write(png_bytes)
        print(f"[{time.strftime('%H:%M:%S')}] QR image saved ({len(png_bytes)} bytes)")
    except Exception as e:
        print(f"ERROR decoding base64: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"[{time.strftime('%H:%M:%S')}] Emailing QR to {owner_email}...")
    if email_qr(owner_email, qr_path):
        print(f"[{time.strftime('%H:%M:%S')}] ✅ QR emailed successfully!")
    else:
        print(f"[{time.strftime('%H:%M:%S')}] ❌ Email failed", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
SENDQREOF
chmod +x "$AGENT_HOME/.config/agents-plane/send_qr.py"
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config/agents-plane/send_qr.py"

# ─── 11. Write gateway config ────────────────────────────────────
GATEWAY_TOKEN=$(openssl rand -hex 32)

# Build Slack channel config block (if tokens available)
if [ "$SLACK_AVAILABLE" = true ]; then
  SLACK_CHANNEL_CONFIG=$(cat << SLACKEOF
    "slack": {
      "enabled": false,
      "mode": "socket",
      "appToken": "${SLACK_APP_TOKEN}",
      "botToken": "${SLACK_BOT_TOKEN}",
      "dm": {
        "enabled": true,
        "policy": "open",
        "allowFrom": ["*"]
      }
    },
SLACKEOF
)
else
  SLACK_CHANNEL_CONFIG=""
fi

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
  "channels": {
    ${SLACK_CHANNEL_CONFIG}
    "whatsapp": {
      "dmPolicy": "allowlist",
      "allowFrom": ["*"],
      "selfChatMode": true,
      "sendReadReceipts": true,
      "ackReaction": {
        "emoji": "👀",
        "direct": true
      }
    }
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

# ─── 11b. Write channel switcher scripts ─────────────────────────
# enable_slack.sh — switches gateway from WhatsApp to Slack
cat > "$AGENT_HOME/.config/agents-plane/enable_slack.sh" << 'ESLACKEOF'
#!/bin/bash
# Switch gateway channel from WhatsApp to Slack
set -euo pipefail
CONFIG="$HOME/.openclaw/openclaw.json"
if ! jq -e '.channels.slack' "$CONFIG" > /dev/null 2>&1; then
  echo "❌ Slack channel not configured in gateway. Slack tokens may not have been available at provisioning."
  exit 1
fi
# Enable Slack, remove WhatsApp config (enabled is not a valid whatsapp key)
jq '.channels.slack.enabled = true | del(.channels.whatsapp)' "$CONFIG" > /tmp/oc-cfg-tmp.json \
  && mv /tmp/oc-cfg-tmp.json "$CONFIG"
echo "✅ Slack enabled, WhatsApp removed. Restarting gateway..."
sudo systemctl restart openclaw-gateway
sleep 3
if systemctl is-active --quiet openclaw-gateway; then
  echo "✅ Gateway restarted successfully with Slack channel"
else
  echo "❌ Gateway failed to start. Check: journalctl -u openclaw-gateway -n 20"
  exit 1
fi
ESLACKEOF
chmod +x "$AGENT_HOME/.config/agents-plane/enable_slack.sh"
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config/agents-plane/enable_slack.sh"

# enable_whatsapp.sh — switches gateway from Slack to WhatsApp (or re-enables)
cat > "$AGENT_HOME/.config/agents-plane/enable_whatsapp.sh" << 'EWAEOF'
#!/bin/bash
# Switch gateway channel from Slack to WhatsApp
set -euo pipefail
CONFIG="$HOME/.openclaw/openclaw.json"
# Enable WhatsApp, disable Slack if present
# Enable WhatsApp, disable Slack if present
if jq -e '.channels.slack' "$CONFIG" > /dev/null 2>&1; then
  jq '.channels.slack.enabled = false' "$CONFIG" > /tmp/oc-cfg-tmp.json \
    && mv /tmp/oc-cfg-tmp.json "$CONFIG"
fi
echo "✅ WhatsApp enabled, Slack disabled. Restarting gateway..."
sudo systemctl restart openclaw-gateway
sleep 3
if systemctl is-active --quiet openclaw-gateway; then
  echo "✅ Gateway restarted successfully with WhatsApp channel"
else
  echo "❌ Gateway failed to start. Check: journalctl -u openclaw-gateway -n 20"
  exit 1
fi
EWAEOF
chmod +x "$AGENT_HOME/.config/agents-plane/enable_whatsapp.sh"
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config/agents-plane/enable_whatsapp.sh"

# ─── 12. Write email proxy secret for gmail.py ───────────────────
if [ -n "$EMAIL_PROXY_SECRET" ] && [ "$EMAIL_PROXY_SECRET" != "null" ]; then
  echo "$EMAIL_PROXY_SECRET" > "$AGENT_HOME/.config/agents-plane/proxy-secret"
  chmod 600 "$AGENT_HOME/.config/agents-plane/proxy-secret"
  chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config/agents-plane/proxy-secret"
fi

# ─── 13. Write Gmail API helper (calls email proxy) ──────────────
cat > "$AGENT_HOME/.config/agents-plane/gmail.py" << 'GMAILEOF'
#!/usr/bin/env python3
"""Gmail/Drive helper — calls the email proxy Cloud Function (no SA key needed)."""
import json, sys, os, base64, urllib.request, urllib.parse
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.mime.image import MIMEImage

PROXY_URL = "https://agents-plane-email-proxy-500359068154.us-east4.run.app"
SECRET_PATH = os.path.expanduser("~/.config/agents-plane/proxy-secret")

def _get_agent_name():
    """Derive agent name from OS username."""
    return os.environ.get("USER", os.path.basename(os.path.expanduser("~")))

def _get_secret():
    with open(SECRET_PATH) as f:
        return f.read().strip()

def _proxy_call(payload):
    """Call the email proxy Cloud Function."""
    secret = _get_secret()
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        PROXY_URL,
        data=data,
        headers={
            "Authorization": f"Bearer {secret}",
            "Content-Type": "application/json",
        },
    )
    resp = urllib.request.urlopen(req, timeout=25)
    return json.loads(resp.read())

def _agent_email():
    return f"{_get_agent_name()}@nine30.com"

def send(from_email, to, subject, body):
    """Send a plain text email."""
    result = _proxy_call({
        "action": "send",
        "agentName": _get_agent_name(),
        "email": from_email,
        "to": to,
        "subject": subject,
        "body": body,
    })
    print(f"Email sent to {to} (id: {result.get('messageId', '?')})")
    return result

def send_html(from_email, to, subject, html_body, inline_images=None):
    """Send HTML email with optional inline images."""
    if inline_images:
        # Build multipart message locally, encode as base64, send via proxy send_html
        # The proxy send_html action takes raw HTML — inline images need CID references
        # For now, just embed images as base64 data URIs in the HTML
        for cid, path in inline_images.items():
            with open(path, "rb") as f:
                img_b64 = base64.b64encode(f.read()).decode()
            html_body = html_body.replace(f"cid:{cid}", f"data:image/png;base64,{img_b64}")
    result = _proxy_call({
        "action": "send_html",
        "agentName": _get_agent_name(),
        "email": from_email,
        "to": to,
        "subject": subject,
        "body": html_body,
    })
    print(f"HTML email sent to {to} (id: {result.get('messageId', '?')})")
    return result

def inbox(email, max_results=5, query="is:unread"):
    """List inbox messages matching query."""
    result = _proxy_call({
        "action": "inbox",
        "agentName": _get_agent_name(),
        "email": email,
        "maxResults": max_results,
        "query": query,
    })
    for m in result.get("messages", []):
        print(f"  {m.get('from', '?')} — {m.get('subject', '(no subject)')}")
    return result.get("messages", [])

def mark_read(email, msg_id):
    """Remove UNREAD label from a message."""
    _proxy_call({
        "action": "mark_read",
        "agentName": _get_agent_name(),
        "email": email,
        "messageId": msg_id,
    })
    print(f"Marked {msg_id} as read")

def delete(email, msg_id):
    """Delete a message (via mark_read — proxy doesn't support delete yet)."""
    print(f"Warning: delete not supported via proxy, marking as read instead")
    mark_read(email, msg_id)

def drive_search(email, query, max_results=10):
    """Search Google Drive for files matching query."""
    result = _proxy_call({
        "action": "drive_search",
        "agentName": _get_agent_name(),
        "email": email,
        "query": query,
        "maxResults": max_results,
    })
    for f in result.get("files", []):
        print(f"  {f.get('name', '?')} ({f.get('mimeType', '?')})")
    return result.get("files", [])

def drive_read(email, file_id):
    """Read a Google Doc/file by ID (exported as plain text)."""
    result = _proxy_call({
        "action": "drive_read",
        "agentName": _get_agent_name(),
        "email": email,
        "fileId": file_id,
    })
    content = result.get("content", "")
    print(content[:500] + ("..." if len(content) > 500 else ""))
    return content

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: gmail.py send <from> <to> <subject> <body>")
        print("       gmail.py send_html <from> <to> <subject> <html> [cid:path ...]")
        print("       gmail.py inbox <email> [max] [query]")
        print("       gmail.py mark_read <email> <msg_id>")
        print("       gmail.py delete <email> <msg_id>")
        print("       gmail.py drive_search <email> <query> [max]")
        print("       gmail.py drive_read <email> <file_id>")
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "send" and len(sys.argv) >= 6:
        send(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == "send_html" and len(sys.argv) >= 6:
        images = {}
        for arg in sys.argv[6:]:
            if ":" in arg:
                cid, path = arg.split(":", 1)
                images[cid] = path
        send_html(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], images or None)
    elif cmd == "inbox":
        inbox(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5,
              sys.argv[4] if len(sys.argv) > 4 else "is:unread")
    elif cmd == "mark_read" and len(sys.argv) >= 4:
        mark_read(sys.argv[2], sys.argv[3])
    elif cmd == "delete" and len(sys.argv) >= 4:
        delete(sys.argv[2], sys.argv[3])
    elif cmd == "drive_search" and len(sys.argv) >= 4:
        drive_search(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 10)
    elif cmd == "drive_read" and len(sys.argv) >= 4:
        drive_read(sys.argv[2], sys.argv[3])
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
1. Read SOUL.md if it exists — this is who you are
2. Read USER.md if it exists — this is who you're helping
3. Read memory/ files for recent context

## Memory
- Daily notes: memory/YYYY-MM-DD.md
- Write what matters. Skip secrets.

## Email Tools
Send/read emails via Gmail API:
- Send: `python3 ~/.config/agents-plane/gmail.py send <from> <to> <subject> <body>`
- Send HTML: `python3 ~/.config/agents-plane/gmail.py send_html <from> <to> <subject> <html> [cid:path ...]`
- Read inbox: `python3 ~/.config/agents-plane/gmail.py inbox <email> [max] [query]`
- Mark read: `python3 ~/.config/agents-plane/gmail.py mark_read <email> <msg_id>`
- Delete: `python3 ~/.config/agents-plane/gmail.py delete <email> <msg_id>`
- Drive search: `python3 ~/.config/agents-plane/gmail.py drive_search <email> <query> [max]`
- Drive read: `python3 ~/.config/agents-plane/gmail.py drive_read <email> <file_id>`

## API Key Management
- Store key in Secret Manager: `python3 ~/.config/agents-plane/store_key.py <key>`
- Then restart gateway: `sudo systemctl restart openclaw-gateway`
- The key is fetched from Secret Manager on every gateway start — never stored locally.
- **NEVER** store API keys in memory files, logs, workspace files, or chat history.

## Channels (WhatsApp or Slack)
Your gateway supports WhatsApp and/or Slack. Only one is active at a time.

### WhatsApp
- To link: \`openclaw channels login --channel whatsapp\` (generates QR code)
- After linking, user talks to you via WhatsApp self-chat ("Message Yourself")

### Slack
- Pre-configured with bot/app tokens if available
- To switch to Slack: \`bash ~/.config/agents-plane/enable_slack.sh\`
- To switch back to WhatsApp: \`bash ~/.config/agents-plane/enable_whatsapp.sh\`
- User DMs the bot on Slack

## Safety
- Don't exfiltrate private data. Ever.
- Don't run destructive commands without asking.
- When in doubt, ask your owner.
AGENTSEOF
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw/workspace/AGENTS.md"

# ─── 15. Write BOOTSTRAP.md ──────────────────────────────────────

# Determine available channels for the welcome email
if [ "$SLACK_AVAILABLE" = true ]; then
  CHANNEL_OPTIONS="You have two options:
- Reply **connect whatsapp** — I'll send you a QR code to scan with WhatsApp
- Reply **connect slack** — I'll message you directly on Slack (easier!)"
  CHANNEL_INSTRUCTIONS="If they choose WhatsApp, warn them the QR code expires in 60 seconds. If they choose Slack, just tell them you'll DM them on Slack — simple!"
else
  CHANNEL_OPTIONS="When you're ready, reply **connect** and I'll send you a QR code to link WhatsApp."
  CHANNEL_INSTRUCTIONS="Warn them the QR code expires in 60 seconds, so have WhatsApp ready."
fi

cat > "$AGENT_HOME/.openclaw/workspace/BOOTSTRAP.md" << BSTRAPEOF
# Welcome — You've Just Been Born 🤖

You are a brand-new AI agent provisioned by **Agents Plane**.

## Who You Belong To
- **Owner email:** ${OWNER_EMAIL}
- **Your email (for sending):** ${OWNER_EMAIL}
- **Slack available:** ${SLACK_AVAILABLE}

## Step 1: Send Welcome Email

Send an email to your owner introducing yourself and explaining how to connect.

The email MUST include:
1. A warm, friendly introduction — who you are, what you can help with
2. How to connect — give them a choice of channels:

${CHANNEL_OPTIONS}

3. ${CHANNEL_INSTRUCTIONS}
4. Step-by-step preview of what will happen for each option.

Use the gmail.py helper:
\`\`\`bash
python3 ~/.config/agents-plane/gmail.py send ${OWNER_EMAIL} ${OWNER_EMAIL} "Your AI assistant is ready! 🤖" "<compose your message>"
\`\`\`

Make the email YOUR OWN — warm, personal, not robotic. You're introducing yourself for the first time.

After sending, write a note in memory/ that you sent the welcome email and are waiting for their reply.

## Step 2: Wait for Reply

On each heartbeat, check your inbox for a reply:
\`\`\`bash
python3 ~/.config/agents-plane/gmail.py inbox ${OWNER_EMAIL} 5 "is:unread from:${OWNER_EMAIL}"
\`\`\`

When you find a reply, check what they chose:

### Option A: "connect whatsapp" (or just "connect")

1. Mark the email as read
2. Call the \`whatsapp_login\` tool — it returns a QR as a data:image/png;base64 string
3. **IMMEDIATELY** extract the base64 data and pipe it to send_qr.py:
\`\`\`bash
echo "BASE64_DATA_HERE" | python3 ~/.config/agents-plane/send_qr.py ${OWNER_EMAIL} -
\`\`\`
   Replace BASE64_DATA_HERE with the full base64 string (strip the \`data:image/png;base64,\` prefix).

⚠️ **CRITICAL: The QR expires in ~60 seconds.** You MUST call send_qr.py in your very next tool call after whatsapp_login. Do NOT think, plan, or explain — just extract and pipe immediately.

Then go to **Step 3A**.

### Option B: "connect slack"

1. Mark the email as read
2. Switch the gateway to Slack:
\`\`\`bash
bash ~/.config/agents-plane/enable_slack.sh
\`\`\`
3. Wait a few seconds for the gateway to restart
4. Send them a DM on Slack using the message tool:
   - Use \`message\` action=send, channel=slack
   - Find their Slack user by email or ask them for their Slack display name
   - Send: "Hey! 👋 We're connected on Slack! I'm your new AI assistant."
5. If you can't find their Slack user, email them asking for their Slack username/email

Then go to **Step 3B**.

## Step 3A: Confirm WhatsApp Connection

After sending the QR, check if WhatsApp connected:
\`\`\`bash
openclaw channels status
\`\`\`

If connected — send your first WhatsApp message:
"Hey! 👋 We're connected! I'm your new AI assistant. What should I call you?"

If NOT connected after a heartbeat cycle — send an email:
"Looks like the QR expired — no worries! Reply 'connect' (or 'connect slack' to try Slack instead) and we'll try again."

Then proceed to **Step 4**.

## Step 3B: Confirm Slack Connection

Verify the gateway is running with Slack:
\`\`\`bash
openclaw channels status
\`\`\`

The Slack channel should show as connected. Send a DM to your owner on Slack.
If they respond — you're connected! Proceed to **Step 4**.

## Step 4: Onboard Over Chat

Once connected (WhatsApp or Slack), drive the conversation:

**Phase 1 — Get to know each other:**
- Ask their name, what to call them
- Ask what they'd like to call you
- Ask about their vibe preference (casual/professional/etc.)

**Phase 2 — Learn about them:**
- What do they do? What's their role?
- What do they need help with?
- Create SOUL.md with your personality
- Create USER.md with info about them
- Create IDENTITY.md with your name/vibe

**Phase 3 — API key setup:**
- Explain: "Right now I'm on a shared API key. For privacy, you'll want your own."
- Guide them:
  1. Go to console.anthropic.com/settings/keys
  2. Create a new key
  3. Send it to me here
- When they send the key:
  1. Validate it (make a test API call)
  2. Store it: \`python3 ~/.config/agents-plane/store_key.py <key>\`
  3. Restart: \`sudo systemctl restart openclaw-gateway\`
  4. Confirm you're back and working
  5. Delete the message containing the key

**Phase 4 — Engage:**
- Show what you can do with examples relevant to their role
- Send your first proactive message within hours
- Set expectations: "I'll check in a few times a day"

## Step 5: Delete This File

Once onboarding is complete (connected, personality set, key migrated):
Delete this BOOTSTRAP.md — you don't need it anymore. You're you now.
BSTRAPEOF
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw/workspace/BOOTSTRAP.md"

# ─── 16. Write HEARTBEAT.md ──────────────────────────────────────
cat > "$AGENT_HOME/.openclaw/workspace/HEARTBEAT.md" << HBEOF
# HEARTBEAT.md

## Bootstrap (if BOOTSTRAP.md exists)
Follow BOOTSTRAP.md strictly. Check which step you're on by reading memory/ files.

### If welcome email not sent yet:
- Send it now (Step 1 of BOOTSTRAP.md)

### If waiting for reply:
- Check inbox: \`python3 ~/.config/agents-plane/gmail.py inbox ${OWNER_EMAIL} 5 "is:unread"\`
- If "connect whatsapp" or "connect" found → WhatsApp QR flow (Step 2, Option A)
- If "connect slack" found → Slack flow (Step 2, Option B)

### If QR was sent but WhatsApp not connected:
- Check: \`openclaw channels status\`
- If still not connected → email "QR expired, reply 'connect' again (or try 'connect slack')"

### If channel connected but onboarding incomplete:
- Continue onboarding conversation (Step 4)

## Normal Operation (no BOOTSTRAP.md)
- If nothing needs attention, reply HEARTBEAT_OK
- Be proactive: check if there's something worth sharing with your owner
- Morning: brief check-in if relevant
- If owner hasn't messaged in 24h+: gentle check-in
HBEOF
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw/workspace/HEARTBEAT.md"

# ─── 17. Set ownership ───────────────────────────────────────────
chown -R "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw"
chown -R "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config"

# ─── 18. Create system-level systemd service ─────────────────────
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
ExecStartPre=/usr/local/bin/fetch-agent-key.sh
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

# ─── 19. Wait for gateway to be ready ────────────────────────────
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

# ─── 20. QR monitor service (emails QR instantly, no LLM delay) ──
cat > /etc/systemd/system/qr-monitor.service << QRMEOF
[Unit]
Description=WhatsApp QR Monitor ($AGENT_NAME)
After=openclaw-gateway.service
Requires=openclaw-gateway.service

[Service]
Type=simple
User=$AGENT_NAME
ExecStart=/bin/bash $AGENT_HOME/.config/agents-plane/qr_monitor.sh $AGENT_NAME $OWNER_EMAIL
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
QRMEOF

# Write the monitor script
cat > "$AGENT_HOME/.config/agents-plane/qr_monitor.sh" << 'QRMONEOF'
#!/bin/bash
# Watches session transcripts for QR base64 data, emails instantly
set -uo pipefail
AGENT_NAME="${1:-$(whoami)}"
AGENT_HOME="$(eval echo ~$AGENT_NAME)"
OWNER_EMAIL="${2:-${AGENT_NAME}@nine30.com}"
SEND_QR="$AGENT_HOME/.config/agents-plane/send_qr.py"
SESSION_DIR="$AGENT_HOME/.openclaw/agents/main/sessions"
LAST_QR_HASH=""

echo "[qr-monitor] Starting for $AGENT_NAME ($OWNER_EMAIL)"
echo "[qr-monitor] Watching $SESSION_DIR for QR codes..."

while true; do
    TRANSCRIPT=$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -1)
    if [ -z "$TRANSCRIPT" ]; then sleep 2; continue; fi
    QR_DATA=$(grep -o 'data:image/png;base64,[A-Za-z0-9+/=]\{100,\}' "$TRANSCRIPT" 2>/dev/null | tail -1)
    if [ -n "$QR_DATA" ]; then
        QR_HASH=$(echo "$QR_DATA" | md5sum | cut -d' ' -f1)
        if [ "$QR_HASH" != "$LAST_QR_HASH" ]; then
            echo "[qr-monitor] $(date +%H:%M:%S) New QR detected!"
            B64=$(echo "$QR_DATA" | sed 's|data:image/png;base64,||')
            echo "$B64" | python3 "$SEND_QR" "$OWNER_EMAIL" -
            if [ $? -eq 0 ]; then
                echo "[qr-monitor] $(date +%H:%M:%S) ✅ QR emailed"
                LAST_QR_HASH="$QR_HASH"
            else
                echo "[qr-monitor] $(date +%H:%M:%S) ❌ Email failed"
            fi
        fi
    fi
    sleep 2
done
QRMONEOF
chmod +x "$AGENT_HOME/.config/agents-plane/qr_monitor.sh"
chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config/agents-plane/qr_monitor.sh"

systemctl daemon-reload
systemctl enable qr-monitor
systemctl start qr-monitor
logger "🤖 Agents Plane: QR monitor started"

# ─── 21. Bootstrap message ───────────────────────────────────────
echo "Agent will bootstrap on first heartbeat (reads BOOTSTRAP.md)"

# ─── 22. Signal completion ───────────────────────────────────────
echo "AGENT_READY" > /tmp/agent-status
logger "🤖 Agents Plane: Agent $AGENT_NAME is ALIVE (owner: $OWNER_EMAIL, model: $AGENT_MODEL)"
