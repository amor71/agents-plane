# Design: Agent ↔ User Communication via WhatsApp

## Architecture

```
User's WhatsApp ←──QR Link──→ Agent VM (OpenClaw Gateway)
       ↑                              ↑
  Self-chat                    Baileys linked device
  ("Message Yourself")         sees messages, responds
```

The agent links as a **device on the user's own WhatsApp** — same model OpenClaw uses for personal assistants. User talks to agent via WhatsApp self-chat ("Message Yourself"). No extra phone numbers, no WhatsApp Business API.

## QR Pairing Flow

### The Problem
`openclaw channels login --channel whatsapp` generates a QR code on the terminal. Agent VMs are headless — no screen. QR must reach the user somehow.

### The Solution
Agent captures QR → renders as image → emails to user → user scans with phone.

```
Agent VM boots
  → Gateway starts (WhatsApp NOT linked yet)
  → Agent runs BOOTSTRAP.md
  → Starts WhatsApp pairing, captures QR string
  → Renders QR as PNG image (using qrcode library or python3-qrcode)
  → Emails QR image to user via gmail.py
  → Email subject: "Scan this QR to connect with your AI assistant"
  → Email body explains:
    - "Open WhatsApp → Settings → Linked Devices → Link a Device"
    - "Scan the QR code below"
    - "⚠️ This code expires in 60 seconds — scan it right away!"
    - "If you miss it, I'll send a new one automatically."
  → Agent waits for connection event
  → If no connection after 90 seconds:
    - Generate new QR
    - Send new email: "Here's a fresh QR code — the last one expired"
    - Repeat up to 5 times (total ~8 minutes of attempts)
  → If still no connection:
    - Send final email: "No worries — whenever you're ready, just reply to 
      this email with 'connect' and I'll send a fresh QR code"
    - Agent enters waiting mode, checks email on heartbeat for "connect" trigger
```

### QR Capture Implementation

OpenClaw's `channels login` is interactive (TTY). For headless capture, the agent runs it via `exec` with PTY and parses the QR output. Alternatively, we write a small helper that:

1. Starts the gateway with WhatsApp channel enabled
2. Monitors the gateway log for the QR event
3. Extracts the QR string from the Baileys connection.update event
4. Renders it as PNG using `python3-qrcode`

**`capture-qr.py`:**
```python
#!/usr/bin/env python3
"""Watch gateway logs for WhatsApp QR string, render as PNG, email to user."""
import subprocess, time, re, sys, os, json, base64, io

def watch_for_qr(log_path="/tmp/openclaw/openclaw-*.log", timeout=30):
    """Tail gateway log for QR string."""
    import glob
    logs = sorted(glob.glob(log_path))
    if not logs:
        return None
    # Tail the latest log file watching for QR
    proc = subprocess.Popen(
        ["tail", "-f", logs[-1]], stdout=subprocess.PIPE, text=True)
    start = time.time()
    while time.time() - start < timeout:
        line = proc.stdout.readline()
        if "qr" in line.lower() or "QR" in line:
            # Extract QR data string
            # Baileys logs: [whatsapp] qr: <base64-encoded-qr-data>
            match = re.search(r'qr[:\s]+(\S+)', line)
            if match:
                proc.kill()
                return match.group(1)
    proc.kill()
    return None

def qr_to_png(qr_data, output_path="/tmp/whatsapp-qr.png"):
    """Render QR string as PNG image."""
    try:
        import qrcode
        img = qrcode.make(qr_data)
        img.save(output_path)
        return output_path
    except ImportError:
        # Fallback: use qrencode CLI
        subprocess.run(["qrencode", "-o", output_path, "-s", "10", qr_data], check=True)
        return output_path

if __name__ == "__main__":
    qr_data = watch_for_qr()
    if qr_data:
        path = qr_to_png(qr_data)
        print(f"QR saved to {path}")
    else:
        print("No QR found in logs", file=sys.stderr)
        sys.exit(1)
```

### Email with QR Image

Extend `gmail.py` to support HTML email with embedded image:

```python
def send_html(from_email, to, subject, html_body, attachments=None):
    """Send HTML email with optional inline attachments."""
    from email.mime.multipart import MIMEMultipart
    from email.mime.text import MIMEText
    from email.mime.image import MIMEImage
    
    msg = MIMEMultipart("related")
    msg["From"] = from_email
    msg["To"] = to
    msg["Subject"] = subject
    msg.attach(MIMEText(html_body, "html", "utf-8"))
    
    if attachments:
        for cid, path in attachments.items():
            with open(path, "rb") as f:
                img = MIMEImage(f.read())
                img.add_header("Content-ID", f"<{cid}>")
                img.add_header("Content-Disposition", "inline", filename=f"{cid}.png")
                msg.attach(img)
    
    # ... same send logic as existing send()
```

**Welcome email HTML:**
```html
<h2>Your AI assistant is ready! 🤖</h2>
<p>Hi! I'm your new AI assistant. To connect, scan this QR code with WhatsApp:</p>
<ol>
  <li>Open <b>WhatsApp</b> on your phone</li>
  <li>Go to <b>Settings → Linked Devices → Link a Device</b></li>
  <li>Point your camera at the QR code below</li>
</ol>
<p><img src="cid:qrcode" width="300" /></p>
<p>⚠️ <b>This code expires in about 60 seconds</b> — scan it right away!</p>
<p>If you miss it, I'll automatically send you a fresh one.</p>
<hr/>
<p><small>Once connected, open "Message Yourself" in WhatsApp to chat with me.</small></p>
```

## Gateway Configuration

Startup script writes WhatsApp config:

```json
{
  "agents": {
    "defaults": {
      "workspace": "/home/<agent>/.openclaw/workspace",
      "heartbeat": { "every": "30m" }
    },
    "list": [{
      "id": "main",
      "default": true,
      "model": "anthropic/claude-opus-4-6",
      "identity": { "name": "<agent>" }
    }]
  },
  "channels": {
    "whatsapp": {
      "dmPolicy": "allowlist",
      "allowFrom": ["<OWNER_PHONE>"],
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
      "token": "<generated>"
    }
  }
}
```

**Key settings:**
- `selfChatMode: true` — user talks to agent via self-chat
- `allowFrom` — only the owner's number
- `dmPolicy: "allowlist"` — no one else can message through

**Config secret schema update:**
```json
{
  "user": "allison@nine30.com",
  "userPhone": "+15551234567",
  "model": "claude-opus-4-6",
  "budget": 50
}
```
`userPhone` is required — used for `allowFrom` in WhatsApp config.

## API Key Storage (Secret Manager)

### On receiving key from user (via WhatsApp):

Agent extracts key → validates → stores in Secret Manager → restarts gateway.

**`store_key.py`** (installed by startup script):
```python
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
    except urllib.error.HTTPError as e:
        if e.code != 409: raise

    # Add version
    payload = base64.b64encode(api_key.encode()).decode()
    req = urllib.request.Request(
        f"https://secretmanager.googleapis.com/v1/projects/{project}/secrets/{secret_name}:addVersion",
        data=json.dumps({"payload": {"data": payload}}).encode(),
        headers=headers)
    resp = json.loads(urllib.request.urlopen(req).read())
    print(f"Stored in {secret_name}")

if __name__ == "__main__":
    store_key(sys.argv[1])
```

### On gateway boot (ExecStartPre):

**`/usr/local/bin/fetch-agent-key.sh`:**
```bash
#!/bin/bash
# Fetch API key from Secret Manager, write ephemeral auth-profiles.json
TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | jq -r '.access_token')
PROJECT=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")
AGENT=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/name" | sed 's/^agent-//')
HOME="/home/$AGENT"

# Per-agent key first, shared fallback
for secret in "agent-${AGENT}-api-key" "agents-plane-api-key"; do
  KEY=$(curl -sf "https://secretmanager.googleapis.com/v1/projects/${PROJECT}/secrets/${secret}/versions/latest:access" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.payload.data // empty' | base64 -d 2>/dev/null)
  [ -n "$KEY" ] && [ "$KEY" != "null" ] && break
done

if [ -n "$KEY" ] && [ "$KEY" != "null" ]; then
  MODEL=$(jq -r '.agents.list[0].model // "anthropic/claude-opus-4-6"' "$HOME/.openclaw/openclaw.json")
  PROVIDER="${MODEL%%/*}"
  jq -n --arg p "$PROVIDER" --arg k "$KEY" \
    '{version:1,profiles:{("\($p):default"):{type:"token",provider:$p,token:$k}},lastGood:{($p):"\($p):default"}}' \
    > "$HOME/.openclaw/agents/main/agent/auth-profiles.json"
  chown "$AGENT:$AGENT" "$HOME/.openclaw/agents/main/agent/auth-profiles.json"
fi
```

**systemd service:**
```ini
[Service]
ExecStartPre=/usr/local/bin/fetch-agent-key.sh
ExecStart=...
```

Key is fetched fresh from SM every boot. Never persists between restarts.

## Onboarding (BOOTSTRAP.md)

The agent drives this conversation over WhatsApp after QR pairing succeeds:

**Phase 1: First Contact**
- "Hey! 👋 We're connected! I'm your new AI assistant."
- "What should I call you? And what would you like to call me?"

**Phase 2: Personality**
- "What vibe do you want from me? Casual? Professional? Something else?"
- Asks about their work, role, what they need help with
- Creates SOUL.md, IDENTITY.md, USER.md
- Confirms: "Here's what I've got — [summary]. Sound right?"

**Phase 3: API Key**
- Explains why (privacy, independence)
- Step-by-step guide
- Receives key → validates → stores in SM → restarts → confirms → deletes message

**Phase 4: Engage**
- Shows what it can do with examples relevant to their role
- Sends first proactive message within hours
- Sets expectations: "I'll check in a few times a day"

**Phase 5: Ongoing**
- Morning check-ins, relevant updates, reminders
- Learns preferences, adapts frequency and tone
- Periodic: "Is this working? Anything you want different?"

## HEARTBEAT.md Template

```markdown
# HEARTBEAT.md

## Bootstrap Check
- If BOOTSTRAP.md exists and WhatsApp NOT linked:
  - Check if QR email was sent. If not, start pairing + email QR.
  - If QR was sent but expired (>90s, no connection), regenerate and re-email.
  - Track attempts in /tmp/qr-attempts.json
- If BOOTSTRAP.md exists and WhatsApp IS linked:
  - Continue onboarding conversation
- If no BOOTSTRAP.md: normal operation

## Email Check (bootstrap only)
- If waiting for "connect" trigger email, check inbox via gmail.py
- On "connect" reply → regenerate QR and email it

## Proactive (post-bootstrap)
- Check what's relevant to user and surface it
- Morning briefing if there's something worth sharing
- Respond to any unanswered messages
- If user quiet >24h, gentle check-in
```

## Retry Logic for QR Expiry

```
Attempt 1: Generate QR → email → wait 90s
  ↓ no connection
Attempt 2: Generate QR → email "Fresh code!" → wait 90s  
  ↓ no connection
Attempt 3: Generate QR → email → wait 90s
  ↓ no connection
Attempt 4: Generate QR → email → wait 90s
  ↓ no connection
Attempt 5: Generate QR → email → wait 90s
  ↓ no connection
Final: Email "No rush — reply 'connect' whenever you're ready and I'll send a new code"
  → Agent checks email on heartbeat for "connect" trigger
  → On trigger: restart QR flow
```

## Startup Script Changes

| Step | Change |
|------|--------|
| Config secret | Add `userPhone` field |
| Step 10 (auth-profiles) | Replace with `fetch-agent-key.sh` as ExecStartPre |
| Step 11 (gateway config) | Add `channels.whatsapp` block with allowFrom, selfChatMode |
| Step 13 (gmail.py) | Add `send_html()` for QR image emails |
| NEW: capture-qr.py | Watch gateway logs for QR, render as PNG |
| NEW: store_key.py | Agent writes key to Secret Manager |
| NEW: fetch-agent-key.sh | ExecStartPre — pull key from SM on boot |
| Step 15 (BOOTSTRAP.md) | Rewrite: QR pairing → onboarding → key → engage |
| NEW: HEARTBEAT.md | Bootstrap retry logic + proactive behavior |
| Step 17 (systemd) | Add ExecStartPre for key fetch |
| Dependencies | Add `python3-qrcode` or `qrencode` package |

## IAM Changes

| Principal | Role | Why |
|-----------|------|-----|
| Compute SA | `secretmanager.secretVersionManager` | Agent creates per-agent key secrets |
| Compute SA | `secretmanager.secretAccessor` | Read keys (already have) |

## Security

- API keys never persist on disk between restarts
- WhatsApp message containing key deleted immediately
- Email containing key deleted after processing
- `allowFrom` restricts WhatsApp to owner only
- `selfChatMode` prevents agent from responding to other people's messages
- SA key file is only persistent credential on disk
