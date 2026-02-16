#!/bin/bash
set -e

# This is the startup script extracted from the Cloud Function,
# adapted for Docker testing (no metadata server, no Secret Manager)
# Variables come from ENV instead of metadata/Secret Manager

echo "🤖 Agents Plane: Starting provisioning for $AGENT_NAME ($OWNER_EMAIL)"

# --- Install Node.js 22 ---
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
echo "✅ Node $(node --version) installed"

# --- Install OpenClaw ---
npm install -g openclaw 2>&1 | tail -3
echo "✅ OpenClaw installed at $(which openclaw || echo 'NOT FOUND')"

# --- Install python3-cryptography ---
apt-get install -y -qq python3-cryptography
echo "✅ python3-cryptography installed"

# --- Install himalaya ---
HIMALAYA_VERSION="v1.1.0"
curl -sL "https://github.com/pimalaya/himalaya/releases/download/${HIMALAYA_VERSION}/himalaya.x86_64-linux.tgz" | tar xz -C /usr/local/bin/
chmod +x /usr/local/bin/himalaya
echo "✅ himalaya $(himalaya --version 2>&1 | head -1) installed"

# --- Create workspace with BOOTSTRAP.md and AGENTS.md ---
su - agent -c "mkdir -p ~/.openclaw/workspace ~/.openclaw/agents/main/agent"

# Write BOOTSTRAP.md (simplified for test)
cat > /home/agent/.openclaw/workspace/BOOTSTRAP.md << 'BSEOF'
# BOOTSTRAP.md - Hello, World
You just woke up. Send a welcome email to your owner, then get to know each other.
BSEOF
chown agent:agent /home/agent/.openclaw/workspace/BOOTSTRAP.md

# Write AGENTS.md (simplified for test)
cat > /home/agent/.openclaw/workspace/AGENTS.md << 'AGEOF'
# AGENTS.md
If BOOTSTRAP.md exists, follow it.
AGEOF
chown agent:agent /home/agent/.openclaw/workspace/AGENTS.md

# --- Write auth profile ---
cat > /home/agent/.openclaw/agents/main/agent/auth-profiles.json << AUTHEOF
{
  "version": 1,
  "profiles": {
    "anthropic:default": {
      "type": "token",
      "provider": "anthropic",
      "token": "$ANTHROPIC_KEY"
    }
  },
  "lastGood": {
    "anthropic": "anthropic:default"
  }
}
AUTHEOF
chown -R agent:agent /home/agent/.openclaw/agents/

# --- Write gateway config ---
GATEWAY_TOKEN=$(openssl rand -hex 32)
cat > /home/agent/.openclaw/openclaw.json << CFGEOF
{
  "agents": {
    "defaults": {
      "workspace": "/home/agent/.openclaw/workspace",
      "models": {
        "anthropic/$AGENT_MODEL": {}
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
          "name": "$AGENT_NAME"
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
      "token": "$GATEWAY_TOKEN"
    }
  }
}
CFGEOF
chown agent:agent /home/agent/.openclaw/openclaw.json

# --- Write Gmail OAuth2 token helper ---
su - agent -c "mkdir -p ~/.config/himalaya ~/.config/agents-plane"

echo "$SA_KEY_JSON" > /home/agent/.config/agents-plane/sa-key.json
chmod 600 /home/agent/.config/agents-plane/sa-key.json
chown agent:agent /home/agent/.config/agents-plane/sa-key.json

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

DOMAIN=$(echo "$OWNER_EMAIL" | cut -d@ -f2)
ACCT_NAME=$(echo "$DOMAIN" | cut -d. -f1)

cat > /home/agent/.config/himalaya/config.toml << EMAILEOF
[accounts.$ACCT_NAME]
default = true
display-name = "Agent $AGENT_NAME"
email = "$OWNER_EMAIL"
folder.alias.inbox = "INBOX"
folder.alias.sent = "[Gmail]/Sent Mail"
folder.alias.drafts = "[Gmail]/Drafts"
folder.alias.trash = "[Gmail]/Trash"

backend.type = "imap"
backend.host = "imap.gmail.com"
backend.port = 993
backend.encryption = "tls"
backend.login = "$OWNER_EMAIL"
backend.auth.type = "xoauth2"
backend.auth.access-token.cmd = "python3 /home/agent/.config/agents-plane/get-gmail-token.py $OWNER_EMAIL"

message.send.backend.type = "smtp"
message.send.backend.host = "smtp.gmail.com"
message.send.backend.port = 465
message.send.backend.encryption = "tls"
message.send.backend.login = "$OWNER_EMAIL"
message.send.backend.auth.type = "xoauth2"
message.send.backend.auth.access-token.cmd = "python3 /home/agent/.config/agents-plane/get-gmail-token.py $OWNER_EMAIL"

message.send.save-copy = false
EMAILEOF
chown -R agent:agent /home/agent/.config/himalaya/

# --- Find OpenClaw entry point ---
NODE_BIN=$(which node)
OPENCLAW_MAIN=$(node -e "console.log(require.resolve('openclaw/dist/index.js'))" 2>/dev/null || echo "/usr/lib/node_modules/openclaw/dist/index.js")
echo "✅ OpenClaw entry point: $OPENCLAW_MAIN"

# --- Write systemd service (for verification, can't actually run in Docker) ---
su - agent -c "mkdir -p ~/.config/systemd/user"
cat > /home/agent/.config/systemd/user/openclaw-gateway.service << SVCEOF
[Unit]
Description=OpenClaw Gateway ($AGENT_NAME)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$NODE_BIN $OPENCLAW_MAIN gateway --port 18789
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF
chown -R agent:agent /home/agent/.config/systemd/

echo "🤖 Agents Plane: Startup script completed"
