# Design: Agent ↔ User Email Channel

## Architecture Overview

```
User (Gmail)  ←→  Gmail API (REST)  ←→  Agent VM (OpenClaw)
                      ↑
              Service Account (JWT)
              Domain-Wide Delegation
              Scopes: gmail.send + gmail.readonly + gmail.modify
```

The agent uses the existing service account with domain-wide delegation to both send AND read the user's Gmail. No new infrastructure — just expanded scopes and a smarter `gmail.py`.

## Components

### 1. Gmail Helper (`gmail.py`) — Enhanced

Extend the existing `gmail.py` with:

| Function | Purpose |
|----------|---------|
| `send(from, to, subject, body)` | Send email (already exists) |
| `inbox(email, query, max)` | List messages matching query |
| `read(email, msg_id)` | Get full message body (plain text) |
| `mark_read(email, msg_id)` | Remove UNREAD label |
| `delete(email, msg_id)` | Permanently delete (for key emails) |
| `reply(email, msg_id, body)` | Reply to a thread (preserves threading) |

All functions use the same JWT/SA auth flow. The `gmail.modify` scope covers both `gmail.send` and label modifications (mark as read), and `gmail.readonly` covers reading.

**Simplified scope:** Use `https://mail.google.com/` (full access) since we need send + read + modify + delete. This is a single scope vs managing 4 separate ones.

### 2. Email Polling (Heartbeat-Based)

On every heartbeat, the agent runs a check-email flow:

```
Heartbeat fires
  → Agent reads HEARTBEAT.md
  → HEARTBEAT.md says: check email
  → Agent runs: python3 gmail.py inbox <owner_email> --unread
  → For each unread message:
      → Read full body
      → If contains API key pattern → R3 key onboarding flow
      → Otherwise → feed to agent as user message
      → Agent generates response
      → Agent sends reply via gmail.py
      → Mark original as read
```

This is identical to how Rye checks email on heartbeat — no new mechanism needed.

### 3. API Key Onboarding Flow

```
User sends email with sk-ant-api03-... key
  → Agent extracts key (regex: sk-ant-[a-zA-Z0-9_-]+)
  → Validates: curl -s https://api.anthropic.com/v1/messages with test payload
  → If valid:
      → Store in Secret Manager: agent-{name}-api-key
      → Write fetch-key-on-boot script that pulls from SM at startup
      → Restart gateway
      → Send confirmation email
      → Delete the email containing the key (gmail.py delete)
  → If invalid:
      → Reply: "That key didn't work — double check and resend?"
```

**Secret Manager storage:**
- Secret name: `agent-{name}-api-key`
- Agent's VM service account already has `secretmanager.secretAccessor` role
- On gateway restart, startup script pulls key from SM → writes ephemeral auth-profiles.json
- Key never persists on disk between restarts

**Key fetch on boot** — modify the systemd service `ExecStartPre` to:
```bash
ExecStartPre=/usr/local/bin/fetch-agent-key.sh
```

`fetch-agent-key.sh`:
```bash
#!/bin/bash
# Fetch API key from Secret Manager at boot, write ephemeral auth-profiles.json
TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | jq -r '.access_token')
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/name")
AGENT_NAME="${INSTANCE_NAME#agent-}"

# Try per-agent key first, fall back to shared
API_KEY=$(curl -s "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/agent-${AGENT_NAME}-api-key/versions/latest:access" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.payload.data // empty' | base64 -d 2>/dev/null)

if [ -z "$API_KEY" ]; then
  API_KEY=$(curl -s "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/agents-plane-api-key/versions/latest:access" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.payload.data // empty' | base64 -d 2>/dev/null)
fi

if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ]; then
  AGENT_HOME="/home/${AGENT_NAME}"
  # Detect provider from existing config
  MODEL=$(jq -r '.agents.list[0].model // "anthropic/claude-opus-4-6"' "$AGENT_HOME/.openclaw/openclaw.json")
  PROVIDER="${MODEL%%/*}"

  jq -n --arg provider "$PROVIDER" --arg key "$API_KEY" \
    '{version:1, profiles:{("\($provider):default"):{type:"token",provider:$provider,token:$key}}, lastGood:{($provider):"\($provider):default"}}' \
    > "$AGENT_HOME/.openclaw/agents/main/agent/auth-profiles.json"
  chown "$AGENT_NAME:$AGENT_NAME" "$AGENT_HOME/.openclaw/agents/main/agent/auth-profiles.json"
fi
```

### 4. Secret Manager Key Storage (from agent)

The agent needs to write to Secret Manager when receiving a key via email. Python helper `store_key.py`:

```python
#!/usr/bin/env python3
"""Store an API key in GCP Secret Manager."""
import json, sys, urllib.request

def get_token():
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"})
    return json.loads(urllib.request.urlopen(req).read())["access_token"]

def get_project():
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/project/project-id",
        headers={"Metadata-Flavor": "Google"})
    return urllib.request.urlopen(req).read().decode()

def get_agent_name():
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/instance/name",
        headers={"Metadata-Flavor": "Google"})
    name = urllib.request.urlopen(req).read().decode()
    return name.replace("agent-", "", 1)

def store_key(api_key):
    token = get_token()
    project = get_project()
    agent = get_agent_name()
    secret_name = f"agent-{agent}-api-key"
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

    # Create secret (ignore if exists)
    try:
        req = urllib.request.Request(
            f"https://secretmanager.googleapis.com/v1/projects/{project}/secrets",
            data=json.dumps({"secretId": secret_name, "replication": {"automatic": {}}}).encode(),
            headers=headers)
        urllib.request.urlopen(req)
    except urllib.error.HTTPError as e:
        if e.code != 409:  # 409 = already exists
            raise

    # Add version
    import base64
    payload = base64.b64encode(api_key.encode()).decode()
    req = urllib.request.Request(
        f"https://secretmanager.googleapis.com/v1/projects/{project}/secrets/{secret_name}:addVersion",
        data=json.dumps({"payload": {"data": payload}}).encode(),
        headers=headers)
    resp = json.loads(urllib.request.urlopen(req).read())
    print(f"Key stored as {secret_name} (version: {resp['name'].split('/')[-1]})")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: store_key.py <api-key>")
        sys.exit(1)
    store_key(sys.argv[1])
```

**IAM requirement:** The VM's service account needs `secretmanager.secretVersionManager` role (or `secretmanager.admin`) on the project to create secrets and add versions.

### 5. HEARTBEAT.md Template

Written by startup script, tells the agent what to check:

```markdown
# HEARTBEAT.md

## Email Check (every heartbeat)
- Run: python3 ~/.config/agents-plane/gmail.py inbox <owner_email> --unread
- Process each unread message:
  - If it contains an API key (sk-ant-*): run key onboarding
  - Otherwise: read it, respond via email
- Mark all processed messages as read

## Key Onboarding
If user sends an API key:
1. Validate: test call to Anthropic API
2. Store: python3 ~/.config/agents-plane/store_key.py <key>
3. Restart: sudo systemctl restart openclaw-gateway
4. Confirm via email
5. Delete the email with the key

## Proactive (after bootstrap complete)
- Check user's recent emails for anything urgent
- Check calendar if available
- Send daily briefing if there's something worth sharing
```

### 6. Domain-Wide Delegation Scope Update

In `setup.sh`, update the delegation scopes documentation/instructions:

Current: `https://www.googleapis.com/auth/gmail.send`
New: `https://mail.google.com/` (full Gmail access — covers send, read, modify, delete)

This is a one-time change in Google Workspace Admin Console → Security → API Controls → Domain-wide delegation.

### 7. Startup Script Changes

1. **Replace step 10** (write auth-profiles.json directly) with `fetch-agent-key.sh`
2. **Add `fetch-agent-key.sh`** to `/usr/local/bin/` — runs at gateway boot
3. **Add `store_key.py`** to `~/.config/agents-plane/` — used by agent to save keys
4. **Add `ExecStartPre`** to systemd service — fetches key before gateway starts
5. **Write HEARTBEAT.md** with email check instructions
6. **Update BOOTSTRAP.md** — remove local key storage instructions, use Secret Manager flow

### 8. Permissions

The VM service account needs:
- `roles/secretmanager.secretAccessor` — read secrets (already have this)
- `roles/secretmanager.secretVersionManager` — create secrets + add versions (NEW)

Grant in `setup.sh`:
```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/secretmanager.secretVersionManager"
```

## File Changes Summary

| File | Change |
|------|--------|
| `startup-script.sh` | Add fetch-agent-key.sh, store_key.py, HEARTBEAT.md, ExecStartPre |
| `gmail.py` | Add read, mark_read, delete, reply functions |
| `setup.sh` | Update scope docs, add secretVersionManager role |
| `BOOTSTRAP.md` template | Use Secret Manager for key storage |
| NEW: `fetch-agent-key.sh` | ExecStartPre — pull key from SM on boot |
| NEW: `store_key.py` | Agent writes key to SM |

## Security Notes

- API keys **never** persist on disk — `auth-profiles.json` is written by `ExecStartPre` and could be tmpfs-mounted for extra safety
- Email containing key is deleted immediately after processing
- SA key file on disk is the only persistent credential — same as current design
- Per-agent secrets in SM are only accessible by the project's compute SA (scoped by IAM)
