---
name: clawdtalk-client
version: 1.4.0
description: ClawdTalk — Voice calls and SMS for Clawdbot
metadata: {"clawdbot":{"emoji":"📞","requires":{"bins":["bash","node","jq"]}}}
---

# ClawdTalk

Voice calling and SMS messaging for Clawdbot. Call your bot by phone or send texts — powered by Telnyx.

## Quick Start

1. **Sign up** at [clawdtalk.com](https://clawdtalk.com)
2. **Add your phone** in Settings
3. **Get API key** from Dashboard
4. **Run setup**: `./setup.sh`
5. **Start connection**: `./scripts/connect.sh start`

## Voice Calls

The WebSocket client routes calls to your gateway's main agent session, giving full access to memory, tools, and context.

```bash
./scripts/connect.sh start     # Start connection
./scripts/connect.sh stop      # Stop
./scripts/connect.sh status    # Check status
```

### Outbound Calls

Have the bot call you or others:

```bash
./scripts/call.sh                              # Call your phone
./scripts/call.sh "Hey, what's up?"            # Call with greeting
./scripts/call.sh --to +15551234567            # Call external number*
./scripts/call.sh --to +15551234567 "Hello!"   # External with greeting
./scripts/call.sh status <call_id>             # Check call status
./scripts/call.sh end <call_id>                # End call
```

*External calls require a paid account with a dedicated number. The AI will operate in privacy mode when calling external numbers (won't reveal your private info).

## SMS

Send and receive text messages:

```bash
./scripts/sms.sh send +15551234567 "Hello!"
./scripts/sms.sh list
./scripts/sms.sh conversations
```

## Missions

AI-powered outreach — have your assistant make calls or send texts to a list of targets on your behalf.

Missions require a paid account (Starter or Pro).

### When to Create a Mission

Use your judgement: if the user's request involves **multiple targets** or requires **multi-step work per target**, create a mission instead of handling it manually.

**Just do it directly** (no mission needed):
- "What time is it?" — answer immediately
- "Call mom" — single outbound call via `call.sh`
- "Text John that I'm running late" — single SMS via `sms.sh`

**Create a mission** when the request involves:
- **Multiple people to contact** — "Call these 5 plumbers and get quotes"
- **Research across targets** — "Find me the cheapest electrician in Austin"
- **Actions after each call** — "Call each vendor, ask about availability, and compare prices"
- **Batch outreach** — "Remind all my clients about tomorrow's meeting"
- **Multi-step workflows** — "Call these restaurants, ask if they have a table for 4 tonight, and book the first one that does"

In short: one person, one simple thing → handle it directly. Multiple people, or complex instructions that the AI should follow autonomously for each target → create a mission.

### Commands

```bash
./scripts/missions.sh create '<json>'      # Create and run a mission
./scripts/missions.sh list                  # List all missions
./scripts/missions.sh get <id>             # Get mission details
./scripts/missions.sh events <id>          # Show event timeline
./scripts/missions.sh status <id>          # Status summary
./scripts/missions.sh cancel <id>          # Cancel a running mission
```

### Create a Mission

Pass a JSON body with these fields:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Mission name (e.g., "Get plumber quotes") |
| `instructions` | Yes | What the AI should do on each call/SMS |
| `targets` | Yes | Array of `{phone, name?, message?}` objects (E.164 format) |
| `channel` | No | `"voice"` (default), `"sms"`, or `"both"` |
| `assistant_config` | No | `{greeting?, model?}` overrides |
| `schedule` | No | `"now"` (default), `"business_hours"`, or ISO datetime |
| `metadata` | No | Any extra data to attach |

### Examples

```bash
# Voice mission — call plumbers for quotes
./scripts/missions.sh create '{
  "name": "Get plumber quotes",
  "instructions": "Call each plumber. Ask about hourly rates, availability this week, and whether they are licensed and insured. Be polite and professional.",
  "targets": [
    {"name": "ABC Plumbing", "phone": "+15125551234"},
    {"name": "Quick Fix Pipes", "phone": "+15125555678"}
  ],
  "channel": "voice"
}'

# SMS mission — send appointment reminders
./scripts/missions.sh create '{
  "name": "Appointment reminders",
  "instructions": "Remind each person about their appointment tomorrow at 2pm.",
  "targets": [
    {"name": "Alice", "phone": "+15125551111"},
    {"name": "Bob", "phone": "+15125552222"}
  ],
  "channel": "sms"
}'

# Check how it's going
./scripts/missions.sh status 42

# See full event details
./scripts/missions.sh events 42
```

### Mission Statuses

| Status | Meaning |
|--------|---------|
| `pending` | Created, not yet started |
| `running` | Actively making calls/sending texts |
| `succeeded` | All targets reached |
| `failed` | Execution failed |
| `cancelled` | Cancelled by user |

### Quotas

| Plan | Missions/month | Events/month |
|------|---------------|--------------|
| Free | 0 | 0 |
| Starter | 20 | 50 |
| Pro | 100 | 200 |

Each target counts as 1 event per channel. Using `"both"` doubles the event count.

## Configuration

Edit `skill-config.json`:

| Option | Description |
|--------|-------------|
| `api_key` | API key from clawdtalk.com |
| `server` | Server URL (default: `https://clawdtalk.com`) |
| `owner_name` | Your name (auto-detected from USER.md) |
| `agent_name` | Agent name (auto-detected from IDENTITY.md) |
| `greeting` | Custom greeting for inbound calls |

## Troubleshooting

- **Auth failed**: Regenerate API key at clawdtalk.com
- **Empty responses**: Run `./setup.sh` and restart gateway
- **Slow responses**: Try a faster model in your gateway config
- **Debug mode**: `DEBUG=1 ./scripts/connect.sh restart`
