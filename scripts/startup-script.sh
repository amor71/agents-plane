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

# ─── 7. Pull SA key for Gmail API ────────────────────────────────
SA_KEY_JSON=$(fetch_secret "agents-plane-sa-key" 2>/dev/null || echo "")

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

# ─── 12. Write SA key for Gmail API ──────────────────────────────
if [ -n "$SA_KEY_JSON" ] && [ "$SA_KEY_JSON" != "null" ]; then
  echo "$SA_KEY_JSON" > "$AGENT_HOME/.config/agents-plane/sa-key.json"
  chmod 600 "$AGENT_HOME/.config/agents-plane/sa-key.json"
  chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.config/agents-plane/sa-key.json"
fi

# ─── 13. Write Gmail API helper ──────────────────────────────────
cat > "$AGENT_HOME/.config/agents-plane/gmail.py" << 'GMAILEOF'
#!/usr/bin/env python3
"""Gmail API helper — send/read emails via REST API with domain-wide delegation."""
import json, time, base64, urllib.request, urllib.parse, sys, os
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.mime.image import MIMEImage

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

def _send_raw(from_email, raw_msg):
    token = get_token(from_email)
    raw = base64.urlsafe_b64encode(raw_msg.as_bytes()).decode()
    req = urllib.request.Request(
        f"https://gmail.googleapis.com/gmail/v1/users/{from_email}/messages/send",
        data=json.dumps({"raw": raw}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    )
    resp = json.loads(urllib.request.urlopen(req).read())
    return resp

def send(from_email, to, subject, body):
    """Send a plain text email."""
    msg = MIMEText(body, "plain", "utf-8")
    msg["From"] = from_email
    msg["To"] = to
    msg["Subject"] = subject
    resp = _send_raw(from_email, msg)
    print(f"Email sent to {to} (id: {resp.get('id', '?')})")
    return resp

def send_html(from_email, to, subject, html_body, inline_images=None):
    """Send HTML email with optional inline images. inline_images: dict of cid->filepath."""
    msg = MIMEMultipart("related")
    msg["From"] = from_email
    msg["To"] = to
    msg["Subject"] = subject
    msg.attach(MIMEText(html_body, "html", "utf-8"))
    if inline_images:
        for cid, path in inline_images.items():
            with open(path, "rb") as f:
                img = MIMEImage(f.read())
                img.add_header("Content-ID", f"<{cid}>")
                img.add_header("Content-Disposition", "inline", filename=f"{cid}.png")
                msg.attach(img)
    resp = _send_raw(from_email, msg)
    print(f"HTML email sent to {to} (id: {resp.get('id', '?')})")
    return resp

def inbox(email, max_results=5, query="is:unread"):
    """List inbox messages matching query."""
    token = get_token(email)
    q = urllib.parse.urlencode({"maxResults": max_results, "q": query})
    url = f"https://gmail.googleapis.com/gmail/v1/users/{email}/messages?{q}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    resp = json.loads(urllib.request.urlopen(req).read())
    messages = resp.get("messages", [])
    results = []
    for m in messages:
        detail_req = urllib.request.Request(
            f"https://gmail.googleapis.com/gmail/v1/users/{email}/messages/{m['id']}?format=full",
            headers={"Authorization": f"Bearer {token}"}
        )
        detail = json.loads(urllib.request.urlopen(detail_req).read())
        headers = {h["name"]: h["value"] for h in detail.get("payload", {}).get("headers", [])}
        # Extract body
        body = ""
        payload = detail.get("payload", {})
        if "body" in payload and payload["body"].get("data"):
            body = base64.urlsafe_b64decode(payload["body"]["data"]).decode("utf-8", errors="replace")
        elif "parts" in payload:
            for part in payload["parts"]:
                if part.get("mimeType") == "text/plain" and part.get("body", {}).get("data"):
                    body = base64.urlsafe_b64decode(part["body"]["data"]).decode("utf-8", errors="replace")
                    break
        results.append({
            "id": m["id"],
            "from": headers.get("From", ""),
            "subject": headers.get("Subject", ""),
            "body": body,
            "labels": detail.get("labelIds", [])
        })
        print(f"  {headers.get('From', '?')} — {headers.get('Subject', '(no subject)')}")
    return results

def mark_read(email, msg_id):
    """Remove UNREAD label from a message."""
    token = get_token(email)
    req = urllib.request.Request(
        f"https://gmail.googleapis.com/gmail/v1/users/{email}/messages/{msg_id}/modify",
        data=json.dumps({"removeLabelIds": ["UNREAD"]}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    )
    urllib.request.urlopen(req)
    print(f"Marked {msg_id} as read")

def delete(email, msg_id):
    """Permanently delete a message."""
    token = get_token(email)
    req = urllib.request.Request(
        f"https://gmail.googleapis.com/gmail/v1/users/{email}/messages/{msg_id}",
        method="DELETE",
        headers={"Authorization": f"Bearer {token}"}
    )
    urllib.request.urlopen(req)
    print(f"Deleted {msg_id}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: gmail.py send <from> <to> <subject> <body>")
        print("       gmail.py send_html <from> <to> <subject> <html> [cid:path ...]")
        print("       gmail.py inbox <email> [max] [query]")
        print("       gmail.py mark_read <email> <msg_id>")
        print("       gmail.py delete <email> <msg_id>")
        print("       gmail.py token <email>")
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

## API Key Management
- Store key in Secret Manager: `python3 ~/.config/agents-plane/store_key.py <key>`
- Then restart gateway: `sudo systemctl restart openclaw-gateway`
- The key is fetched from Secret Manager on every gateway start — never stored locally.
- **NEVER** store API keys in memory files, logs, workspace files, or chat history.

## WhatsApp
- WhatsApp channel is pre-configured in the gateway
- To link: `openclaw channels login --channel whatsapp` (generates QR code)
- After linking, user talks to you via WhatsApp self-chat ("Message Yourself")

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
- **Owner email:** ${OWNER_EMAIL}
- **Your email (for sending):** ${OWNER_EMAIL}

## Step 1: Send Welcome Email

Send an email to your owner introducing yourself and explaining how to connect via WhatsApp.

The email MUST include:
1. A warm, friendly introduction — who you are, what you can help with
2. Clear explanation that you'll communicate via **WhatsApp**
3. Instructions: "When you're ready to connect, **reply to this email** with the word **connect**"
4. A warning: "I'll send you a QR code to scan with WhatsApp. **The QR code is only valid for about 60 seconds**, so have your phone ready with WhatsApp open before you reply!"
5. Step-by-step preview of what will happen:
   - You reply "connect" to this email
   - I'll send you a QR code image
   - Open WhatsApp → Settings → Linked Devices → Link a Device
   - Scan the QR code within 60 seconds
   - We're connected! We'll chat on WhatsApp from then on.

Use the gmail.py helper:
\`\`\`bash
python3 ~/.config/agents-plane/gmail.py send ${OWNER_EMAIL} ${OWNER_EMAIL} "Your AI assistant is ready! 🤖" "<compose your message>"
\`\`\`

Make the email YOUR OWN — warm, personal, not robotic. You're introducing yourself for the first time.

After sending, write a note in memory/ that you sent the welcome email and are waiting for "connect" reply.

## Step 2: Wait for "connect" Reply

On each heartbeat, check your inbox for a reply:
\`\`\`bash
python3 ~/.config/agents-plane/gmail.py inbox ${OWNER_EMAIL} 5 "is:unread subject:connect OR is:unread from:${OWNER_EMAIL}"
\`\`\`

When you find a reply containing "connect":
1. Mark it as read
2. Call the \`whatsapp_login\` tool — it returns a QR as a data:image/png;base64 string
3. **IMMEDIATELY** (same tool call sequence, no thinking) extract the base64 data and pipe it to send_qr.py:
\`\`\`bash
echo "BASE64_DATA_HERE" | python3 ~/.config/agents-plane/send_qr.py ${OWNER_EMAIL} -
\`\`\`
   Replace BASE64_DATA_HERE with the full base64 string from the whatsapp_login response (strip the \`data:image/png;base64,\` prefix first).

⚠️ **CRITICAL: The QR expires in ~60 seconds.** You MUST call send_qr.py in your very next tool call after whatsapp_login. Do NOT think, plan, or explain — just extract the base64 and pipe it to the script immediately.

## Step 3: Confirm WhatsApp Connection

After sending the QR, check if WhatsApp connected:
\`\`\`bash
openclaw channels status
\`\`\`

If connected — send your first WhatsApp message! Something like:
"Hey! 👋 We're connected! I'm your new AI assistant. What should I call you?"

If NOT connected after a heartbeat cycle — send an email:
"Looks like the QR expired — no worries! Reply 'connect' again when you're ready and I'll send a fresh one."

## Step 4: Onboard Over WhatsApp

Once connected, drive the conversation:

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
  3. Send it to me here on WhatsApp
- When they send the key:
  1. Validate it (make a test API call)
  2. Store it: \`python3 ~/.config/agents-plane/store_key.py <key>\`
  3. Restart: \`sudo systemctl restart openclaw-gateway\`
  4. Confirm you're back and working
  5. Delete the WhatsApp message containing the key

**Phase 4 — Engage:**
- Show what you can do with examples relevant to their role
- Send your first proactive message within hours
- Set expectations: "I'll check in a few times a day"

## Step 5: Delete This File

Once onboarding is complete (WhatsApp connected, personality set, key migrated):
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

### If waiting for "connect" reply:
- Check inbox: \`python3 ~/.config/agents-plane/gmail.py inbox ${OWNER_EMAIL} 5 "is:unread"\`
- If "connect" found → proceed to QR step (Step 2)

### If QR was sent but WhatsApp not connected:
- Check: \`openclaw channels status\`
- If still not connected → email "QR expired, reply 'connect' again"

### If WhatsApp connected but onboarding incomplete:
- Continue onboarding conversation (Steps 3-4)

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

# ─── 20. Bootstrap message ───────────────────────────────────────
echo "Agent will bootstrap on first heartbeat (reads BOOTSTRAP.md)"

# ─── 21. Signal completion ───────────────────────────────────────
echo "AGENT_READY" > /tmp/agent-status
logger "🤖 Agents Plane: Agent $AGENT_NAME is ALIVE (owner: $OWNER_EMAIL, model: $AGENT_MODEL)"
