# Requirements: Agent ↔ User Communication

## Problem
Agents can send welcome emails but have no two-way communication channel with their user. Without this, agents are useless.

## Goal
Every provisioned agent connects with its user via WhatsApp — real-time, mobile, native OpenClaw channel. Email is used only for the initial welcome and WhatsApp QR code delivery.

## User Flow
1. Agent VM boots → starts WhatsApp pairing → generates QR code
2. Agent sends **welcome email** with QR code image to user
3. User scans QR with WhatsApp on their phone → connected
4. Agent introduces itself via WhatsApp, onboards user (name, vibe, API key)
5. Ongoing: real-time chat via WhatsApp
6. Agent is proactive — sends updates, reminders, insights without being asked

## Requirements

### R1: WhatsApp Channel Pre-Configuration
- Startup script configures OpenClaw gateway with WhatsApp channel enabled
- Gateway config includes:
  - `dmPolicy: "allowlist"` with owner's number (from config)
  - WhatsApp channel ready to pair
- Agent needs a **dedicated phone number** for WhatsApp
  - Option A: Org provides pool of numbers, assigned per agent during provisioning
  - Option B: User provides their own number (less clean)
  - Option C: WhatsApp Business API with virtual numbers (scalable, no QR needed)

### R2: QR Code Delivery via Email
- After gateway starts, agent initiates WhatsApp pairing (`openclaw channels login --channel whatsapp`)
- Captures the QR code output
- Renders QR as an image
- Sends welcome email with QR image embedded/attached
- Email says: "Scan this QR code with WhatsApp to connect with your AI assistant"
- QR expires after ~60 seconds — email should explain urgency, and agent should be able to regenerate on request

### R3: WhatsApp Pairing Confirmation
- Once user scans QR → WhatsApp is linked
- Agent detects the link and sends first WhatsApp message: "We're connected! 🎉"
- Begins onboarding conversation via WhatsApp

### R4: API Key Onboarding (Over WhatsApp)
- Agent asks for Anthropic API key via WhatsApp chat
- User sends key in message
- Agent validates (test API call)
- If valid: stores in GCP Secret Manager as `agent-{name}-api-key` (NOT locally)
- Restarts gateway with new key
- Confirms via WhatsApp and deletes the message containing the key
- **Keys must never be stored in local files** — always in Secret Manager

### R5: Proactive Agent Behavior
- Once bootstrapped (WhatsApp connected, API key set), agent is proactive
- Checks user's calendar, emails, relevant data on heartbeat
- Sends unprompted WhatsApp messages when something matters
- Develops personality and relationship with user over time
- Real assistant — not a chatbot waiting to be poked

### R6: Startup Script Changes
- Pre-configure OpenClaw gateway with WhatsApp channel settings
- Include WhatsApp pairing + QR capture in bootstrap flow
- Write BOOTSTRAP.md that tells agent to:
  1. Start WhatsApp pairing
  2. Capture QR
  3. Email QR to user
  4. Wait for connection
  5. Onboard via WhatsApp

### R7: Channel Upgrade Path
- Agent can suggest additional channels (Telegram, Discord, Signal) once comfortable
- Multiple channels can coexist — OpenClaw handles routing

## Open Questions
- **Phone numbers**: Where do WhatsApp numbers come from? Pool? User-provided? Virtual?
- **QR expiry**: QR codes expire quickly (~60s). If user misses it, agent needs to regenerate and re-email. How to handle this gracefully?
- **WhatsApp Business API**: Would eliminate QR entirely (API-based, virtual numbers, scalable). Worth exploring for production, but adds complexity + cost.

## Non-Requirements (for now)
- Email as a two-way channel — email is bootstrap only
- Telegram — WhatsApp first, Telegram as future option
- Attachments — text only for now
- Group chats — 1:1 only

## Success Criteria
- User receives welcome email with WhatsApp QR code
- User scans QR → connected to agent on WhatsApp
- Agent onboards user (name, vibe, API key) via WhatsApp
- Agent is proactive — sends first unprompted message within 24h
- All of this happens without admin intervention after VM boots
