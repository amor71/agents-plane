# Requirements: Agent ↔ User Email Channel

## Problem
Agents can send welcome emails but cannot receive replies. Without two-way communication, agents are useless — they can't onboard users, receive API keys, or take instructions.

## Goal
Every provisioned agent has a fully functional email channel with its user from the moment it boots. The user's only interaction is through their regular email — no SSH, no CLI, no dashboards.

## User Flow
1. Agent VM boots → sends welcome email to user's Workspace email
2. User replies to the email (with API key, questions, instructions, etc.)
3. Agent reads the reply, processes it, and responds via email
4. Ongoing: user emails agent, agent emails back — like texting

## Requirements

### R1: Gmail API Read Access
- Service account must have `https://www.googleapis.com/auth/gmail.readonly` scope via domain-wide delegation (in addition to existing `gmail.send`)
- Startup script must configure the agent to check inbox

### R2: Inbox Monitoring
- Agent checks inbox on every heartbeat (default ~30 min)
- Reads unread messages from the agent's owner (identified by `OWNER_EMAIL` from config)
- Marks processed messages as read
- Supports plain text and HTML email bodies

### R3: API Key Onboarding
- When agent detects a message containing an API key pattern (`sk-ant-*`):
  - Validates the key (test API call to Anthropic)
  - If valid: stores in GCP Secret Manager as `agent-{name}-api-key` (NOT locally on disk)
  - Updates gateway config to pull key from Secret Manager on startup
  - Restarts gateway
  - Sends confirmation email
  - Deletes the original email containing the key (security)
- If invalid: replies asking user to double-check
- **Keys must never be stored in local files** — always in Secret Manager. The `auth-profiles.json` should reference Secret Manager, not contain raw keys.

### R4: General Email Communication
- All non-key emails are fed to the agent as user messages
- Agent replies via email
- This is the agent's primary (and initially only) communication channel
- Agent should be conversational — not robotic auto-replies

### R5: Email Channel in OpenClaw Config
- Configure OpenClaw gateway with email as a channel
- Heartbeat triggers inbox check
- Agent responses route back through email

### R6: Startup Script Changes
- Add `gmail.readonly` scope to domain-wide delegation docs/setup
- Install `gmail_read.py` helper alongside existing `gmail.py`
- Write OpenClaw config that enables email-based heartbeat checking
- BOOTSTRAP.md instructions tell agent to check email on every heartbeat

### R7: Proactive Agent Behavior
- Once bootstrapped (API key set, email channel working), the agent should be proactive — not just reactive
- Agent checks user's calendar, emails, and relevant data on heartbeat
- Sends unprompted emails when something matters: upcoming meetings, urgent emails, reminders, insights
- Agent develops its own personality and relationship with the user over time (per BOOTSTRAP.md flow)
- The agent is a real assistant — not a chatbot waiting to be poked

## Non-Requirements (for now)
- Real-time email (push notifications / pub-sub) — polling on heartbeat is fine
- Multiple email threads — single thread per user is fine
- Attachments — text only for now
- WhatsApp/Telegram — email first, other channels later

## Success Criteria
- User receives welcome email ✅ (already works)
- User replies with API key → agent swaps key, confirms via email
- User sends "what can you do?" → agent replies helpfully via email
- All of this happens without admin intervention
