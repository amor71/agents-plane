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

### R3: Onboarding Journey (Agent-Driven, Over WhatsApp)
The agent drives the entire onboarding — proactively, conversationally, step by step. Not a checklist dump — a real conversation.

**Phase 1: First Contact**
- Agent detects WhatsApp link → sends first message: "We're connected! 🎉"
- Introduces itself warmly, explains what it can do
- Asks: "What should I call you? And what would you like to call me?"

**Phase 2: Personality Setup**
- Agent asks about vibe: "How do you want me to talk? Casual? Professional? Somewhere in between?"
- Asks about their work, role, what they need help with
- Offers suggestions if user is unsure: "Most people like casual — like texting a smart friend"
- Creates SOUL.md, IDENTITY.md, USER.md based on conversation
- Confirms: "OK here's what I got — [summary]. Sound right?"

**Phase 3: API Key Migration**
- Agent explains WHY they need their own key: privacy, independence, their conversations stay theirs
- Walks them through step by step:
  1. "Go to console.anthropic.com/settings/keys"
  2. "Create a new key"
  3. "Send it to me here — I'll set it up and delete the message"
- When key arrives: validate → store in Secret Manager → restart → confirm → delete message
- **Keys must never be stored in local files** — always in Secret Manager

**Phase 4: Teach & Engage**
- Agent explains what it can do: "Ask me anything, I can research, write, analyze, remind you of things"
- Gives examples relevant to their role
- Sends a first proactive message within hours: "Hey, I noticed [something relevant] — thought you'd want to know"
- Sets expectations: "I'll check in a few times a day. If I'm ever too chatty or too quiet, just tell me"

**Phase 5: Ongoing Relationship**
- Agent doesn't wait to be asked — it reaches out
- Morning check-in, relevant updates, reminders
- Learns preferences over time and adapts
- Periodically asks: "Is this working for you? Anything you want me to do differently?"

### R4: Proactive Behavior (Post-Onboarding)
- Agent is proactive from day one — not a chatbot waiting to be poked
- Checks user's calendar, emails, relevant data on heartbeat
- Sends unprompted WhatsApp messages when something matters:
  - Upcoming meetings
  - Urgent emails
  - Reminders they set
  - Interesting things the agent found
- Develops deeper personality and relationship over time
- Tracks what the user cares about and surfaces relevant info
- If user goes quiet for 24h+, checks in: "Hey, everything good? Anything I can help with?"
- **Engage, engage, engage** — the agent's job is to be useful AND present

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
