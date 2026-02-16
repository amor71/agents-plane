# Requirements: Agent ↔ User Communication

## Problem
Agents can send welcome emails but have no two-way communication channel with their user. Without this, agents are useless.

## Goal
Every provisioned agent has a fully functional real-time communication channel with its user. Email is the bootstrap medium (one-way welcome), then the user connects via a native OpenClaw channel (Telegram, WhatsApp, etc.) for ongoing two-way chat.

## User Flow
1. Agent VM boots → sends **welcome email** with instructions to connect via chat
2. User clicks link / scans QR → connects to agent on Telegram or WhatsApp
3. Agent introduces itself, onboards user (name, vibe, API key)
4. Ongoing: user chats with agent in real-time — like texting a friend
5. Agent is proactive — sends updates, reminders, insights without being asked

## Requirements

### R1: Welcome Email (One-Way Bootstrap)
- Agent sends welcome email via Gmail API (already works)
- Email contains:
  - Warm introduction
  - Clear instructions to connect via chat (Telegram link or WhatsApp QR)
  - Why chat is better: "real-time, mobile, like texting — way better than email back-and-forth"
- This is the ONLY use of email — everything else happens over chat

### R2: Telegram as Primary Channel
- Telegram is the easiest to set up programmatically:
  - Create bot via BotFather (can be automated or pre-provisioned)
  - User just clicks a `t.me/BotName` link and hits Start
  - No QR scanning, no browser needed on VM
- Each agent gets its own Telegram bot (or shared bot with routing)
- OpenClaw natively supports Telegram — zero custom code for messaging

### R3: WhatsApp as Alternative Channel
- WhatsApp requires QR pairing (needs terminal/browser access)
- Offer as upgrade path for users who prefer WhatsApp
- Agent guides user through the process when ready
- Lower priority than Telegram for initial setup

### R4: API Key Onboarding (Over Chat)
- Once connected via Telegram/WhatsApp, agent asks for API key
- User sends key in chat
- Agent validates (test API call)
- If valid: stores in GCP Secret Manager as `agent-{name}-api-key` (NOT locally)
- Restarts gateway with new key
- Confirms and deletes the message containing the key
- **Keys must never be stored in local files** — always in Secret Manager

### R5: Proactive Agent Behavior
- Once bootstrapped (channel connected, API key set), agent is proactive
- Checks user's calendar, emails, relevant data on heartbeat
- Sends unprompted messages when something matters
- Develops personality and relationship with user over time
- Real assistant — not a chatbot waiting to be poked

### R6: Startup Script Changes
- Pre-configure OpenClaw gateway with Telegram channel
- Either: pre-create Telegram bot per agent, or include bot creation in bootstrap
- Write BOOTSTRAP.md that tells agent to send welcome email with Telegram connect link
- HEARTBEAT.md for proactive behavior after bootstrap

### R7: Channel Upgrade Path
- Agent naturally promotes additional channels once user is comfortable
- WhatsApp, Discord, Signal — whatever the user prefers
- Agent guides step-by-step through connecting each one
- Multiple channels can coexist — OpenClaw handles routing

## Architecture
```
Welcome Email (Gmail API, one-way)
  → User clicks Telegram link
    → OpenClaw Telegram channel (native, real-time, two-way)
      → All communication happens here
```

## Non-Requirements (for now)
- Email as a two-way channel — email is bootstrap only
- Real-time email polling — not needed
- Attachments — text only for now
- Custom email handling code — leverage OpenClaw native channels

## Success Criteria
- User receives welcome email with Telegram connect link
- User clicks link → connected to agent in Telegram
- Agent onboards user (name, vibe, API key) via chat
- Agent is proactive — sends first unprompted message within 24h
- All of this happens without admin intervention
