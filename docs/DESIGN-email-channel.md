# Design: Agent ↔ User Communication via WhatsApp

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        PROVISIONING                              │
│                                                                  │
│  setup.sh → Cloud Function → VM boots → startup-script.sh       │
│    → installs OpenClaw, configures WhatsApp channel              │
│    → starts gateway (WhatsApp NOT YET LINKED)                    │
│    → agent boots, sends welcome email with WhatsApp instructions │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      QR PAIRING FLOW                             │
│                                                                  │
│  Agent:  starts `openclaw channels login --channel whatsapp`     │
│          captures QR as terminal text / base64 image             │
│          emails QR to user                                       │
│                                                                  │
│  User:   opens email on phone                                    │
│          opens WhatsApp → Linked Devices → Link a Device         │
│          scans QR from email                                     │
│                                                                  │
│  Agent:  detects link → sends first WhatsApp message             │
│          begins onboarding conversation                          │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                     ONGOING COMMUNICATION                        │
│                                                                  │
│  User ←→ WhatsApp ←→ OpenClaw Gateway ←→ Agent (Claude)         │
│                                                                  │
│  Native OpenClaw channel — real-time, two-way, zero custom code  │
└─────────────────────────────────────────────────────────────────┘
```

## The Phone Number Problem

WhatsApp Web (Baileys) is a **linked device** — it piggybacks on an existing WhatsApp account. It doesn't create a new number. So:

**Option A: Agent uses the USER's WhatsApp (linked device)**
- The user scans a QR → their WhatsApp is now linked to the agent VM
- Agent reads/sends messages AS the user
- Problem: agent sees ALL the user's WhatsApp messages, not just ones to the agent
- Problem: agent sends messages FROM the user's number
- This is how OpenClaw already works for personal use — NOT suitable for org-provisioned agents

**Option B: Dedicated WhatsApp number per agent**
- Org provides a pool of phone numbers (SIMs, virtual numbers, or VoIP)
- Each agent gets its own number with its own WhatsApp account
- User adds the agent's number as a contact and chats with it
- Clean separation — agent has its own identity
- Challenge: acquiring and managing phone numbers at scale

**Option C: WhatsApp Business API (Cloud API)**
- Official API from Meta — no QR, no Baileys, no linked devices
- Virtual phone numbers, API-based messaging
- $0.005-0.08 per conversation (24h window)
- Requires Meta Business verification
- Most scalable, most professional, but most setup overhead

**Recommendation: Option B for MVP, Option C for scale**

For the current test (3 agents), Option B works — buy 3 prepaid SIMs or use virtual numbers (e.g., TextNow, Google Voice). Each agent registers WhatsApp on its number, then the user just messages that number.

For production at scale, Option C (WhatsApp Business API) eliminates all the QR/SIM complexity.

## Detailed Flow

### Phase 0: Provisioning (startup-script.sh)

Changes to startup script:

1. **Pre-configure WhatsApp channel** in `openclaw.json`:
```json
{
  "channels": {
    "whatsapp": {
      "dmPolicy": "allowlist",
      "allowFrom": ["<OWNER_PHONE_NUMBER>"],
      "sendReadReceipts": true,
      "ackReaction": {
        "emoji": "👀",
        "direct": true
      }
    }
  }
}
```

2. **Store agent's WhatsApp phone number** in config:
   - `agent-{name}-config` secret gets a `whatsappNumber` field
   - Startup script reads it and configures

3. **Write BOOTSTRAP.md** with WhatsApp pairing instructions

**New config secret schema:**
```json
{
  "user": "allison@nine30.com",
  "userPhone": "+15551234567",
  "model": "claude-opus-4-6",
  "budget": 50,
  "whatsappNumber": "+15559876543"
}
```

### Phase 1: Welcome Email + QR Pairing

When the agent first boots and runs BOOTSTRAP.md:

1. **Send welcome email** via `gmail.py`:
   - Subject: "Your AI assistant is ready! 🤖"
   - Body explains:
     - What the agent can do
     - How to connect via WhatsApp
     - "Save this number: +1 (555) 987-6543 — that's me on WhatsApp"
     - "Message me there to get started!"

2. **If using linked-device model (Option A):**
   - Agent starts WhatsApp pairing
   - Captures QR output (terminal text or base64)
   - Emails QR image to user
   - User scans → linked
   - ⚠️ QR expires in ~60s — agent must detect failure and regenerate

3. **If using dedicated-number model (Option B):**
   - WhatsApp is already registered on the agent's number during provisioning
   - No QR needed from the user
   - User just sends a message to the agent's WhatsApp number
   - Agent receives it via OpenClaw → responds

### Phase 2: Onboarding Conversation (Over WhatsApp)

Agent-driven, conversational, NOT a checklist dump:

```
Agent: "Hey! 👋 I'm your new AI assistant. We're connected on WhatsApp now — 
        this is how we'll talk from now on. What should I call you?"

User:  "I'm Allison"

Agent: "Nice to meet you, Allison! A couple things to get you set up:
        
        First — what vibe do you want from me? I can be:
        • Casual & friendly (like texting a smart friend)
        • Professional & concise (just the facts)
        • Somewhere in between
        
        What feels right?"

User:  "Casual is good"

Agent: "Love it. OK one important setup thing — right now I'm on a shared 
        API key from your org. For privacy (so our conversations stay between 
        us), you'll want your own. Takes 2 minutes:
        
        1. Go to console.anthropic.com/settings/keys
        2. Create a new key (copy it)
        3. Send it to me right here
        
        I'll configure it and delete the message immediately. 🔒"

User:  "sk-ant-api03-..."

Agent: [validates key]
       [stores in Secret Manager as agent-allison-api-key]
       [restarts gateway — pulls new key via ExecStartPre]
       [deletes user's message containing the key]
       
       "All set! You're on your own key now. Our conversations are private. 🔐
        
        So tell me about your work — what do you do and how can I help?"
```

### Phase 3: API Key Storage (Secret Manager)

**On receiving key from user:**

```python
# Agent runs via exec tool:
python3 ~/.config/agents-plane/store_key.py <api-key>
```

`store_key.py` (installed by startup script):
- Creates `agent-{name}-api-key` secret in GCP Secret Manager
- Adds version with the key value
- Uses VM metadata token for auth (no local credentials needed)

**On gateway restart:**

`fetch-agent-key.sh` runs as `ExecStartPre`:
- Checks `agent-{name}-api-key` in Secret Manager (per-agent key)
- Falls back to `agents-plane-api-key` (shared key)
- Writes ephemeral `auth-profiles.json` (overwritten every boot)
- Key never persists on disk between restarts

**systemd service update:**
```ini
[Service]
ExecStartPre=/usr/local/bin/fetch-agent-key.sh
ExecStart=...
```

### Phase 4: Proactive Behavior

Once bootstrapped, the agent's HEARTBEAT.md drives proactive behavior:

```markdown
# HEARTBEAT.md

## Proactive Checks (every heartbeat)
- If BOOTSTRAP.md still exists → continue onboarding
- Check if user has messaged since last heartbeat → respond if needed
- Check user's calendar (if available) for upcoming events
- Check for anything interesting to share

## Engagement Rules
- Morning: send brief check-in if there's something worth sharing
- Don't spam — quality over quantity
- If user hasn't responded in 24h+, gentle check-in
- Learn what they care about, surface relevant info
- Adapt tone and frequency based on their responses
```

The agent writes to its own `memory/` files, builds `SOUL.md` and `USER.md`, and becomes more useful over time — exactly like how Rye works.

### Phase 5: Channel Upgrade Path

After a week or so of WhatsApp use, agent can suggest:
- "Hey, I can also work on Telegram/Discord/Signal if you prefer"
- Guides through setup of additional channels
- Multiple channels coexist — OpenClaw routes automatically

## File Changes Summary

| File | Change |
|------|--------|
| `startup-script.sh` | Add WhatsApp channel config, fetch-agent-key.sh, store_key.py, HEARTBEAT.md |
| `setup.sh` | Accept whatsappNumber in agent config, add secretVersionManager IAM |
| `openclaw.json` template | Add channels.whatsapp block |
| `BOOTSTRAP.md` template | Full onboarding journey with WhatsApp pairing + personality + key |
| NEW: `fetch-agent-key.sh` | ExecStartPre — pull key from SM on every boot |
| NEW: `store_key.py` | Agent writes key to SM when user sends it |
| Cloud Function `index.js` | Accept whatsappNumber + userPhone in provision request |

## IAM Changes

| Principal | Role | Purpose |
|-----------|------|---------|
| Compute SA | `secretmanager.secretVersionManager` | Agent creates/writes per-agent key secrets |
| Compute SA | `secretmanager.secretAccessor` | Agent reads keys (already have this) |

## Open Questions

1. **Phone number acquisition**: How to get dedicated WhatsApp numbers for agents?
   - Prepaid SIMs (manual, doesn't scale)
   - Virtual numbers (TextNow, Google Voice — may not work with WhatsApp)
   - WhatsApp Business API (scalable, no SIM needed, but setup overhead)
   
2. **WhatsApp registration on headless VM**: Even with a dedicated number, initial WhatsApp registration needs SMS verification. Options:
   - Register on a phone first, then link the VM as a device
   - Use WhatsApp Business API (no registration needed)
   
3. **QR expiry handling**: If using QR-based linking, need retry mechanism when QR expires before user scans

4. **User phone number**: Where does `userPhone` come from? Admin console custom field? Asked during provisioning?

## Security Notes

- API keys **never** persist on disk — written by ExecStartPre, overwritten every boot
- Email containing key is deleted immediately after processing
- WhatsApp message containing key is deleted immediately
- SA key file is the only persistent credential on disk
- Per-agent secrets in SM are scoped by IAM
- WhatsApp channel uses `allowlist` policy — only the owner can message the agent
