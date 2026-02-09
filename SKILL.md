---
name: clawdtalk-client
version: 1.3.0
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
