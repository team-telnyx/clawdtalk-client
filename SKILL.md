---
name: clawdtalk-client
version: 1.0.0
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

The WebSocket client routes calls to your gateway's `/v1/chat/completions` endpoint. Your bot answers the phone and can use all its tools.

```bash
./scripts/connect.sh start     # Start connection
./scripts/connect.sh stop      # Stop
./scripts/connect.sh status    # Check status
```

## SMS

Send and receive text messages:

```bash
./scripts/sms.sh send +15551234567 "Hello!"
./scripts/sms.sh list
./scripts/sms.sh conversations
```

## Missions

Dispatch AI assistants to make calls or send SMS on your behalf:

```bash
./scripts/missions.sh create '{"name": "...", "instructions": "...", "targets": [...]}'
./scripts/missions.sh list
./scripts/missions.sh status <id>
```

## Configuration

Edit `skill-config.json`:

| Option | Description |
|--------|-------------|
| `api_key` | API key from clawdtalk.com |
| `server` | Server URL (default: `https://clawdtalk.com`) |

## Troubleshooting

- **Auth failed**: Regenerate API key at clawdtalk.com
- **Empty responses**: Run `./setup.sh` and restart gateway
- **Debug mode**: `DEBUG=1 ./scripts/connect.sh restart`
