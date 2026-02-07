# ClawdTalk Client

Voice calling and SMS messaging for [Clawdbot](https://clawdbot.com). Talk to your bot by phone or exchange texts.

Powered by [Telnyx](https://telnyx.com).

## Features

- **Voice calls** — Real-time conversations with your bot via phone
- **SMS messaging** — Send and receive text messages
- **Missions** — Dispatch AI assistants to make calls on your behalf
- **Tool integration** — Your bot's full capabilities, accessible by voice

## Requirements

- Clawdbot or OpenClaw with gateway running
- Node.js, bash, jq
- ClawdTalk account ([clawdtalk.com](https://clawdtalk.com))

## Installation

```bash
# Clone or download to your skills directory
cd ~/clawd/skills/clawdtalk-client

# Run setup
./setup.sh

# Start the WebSocket connection
./scripts/connect.sh start
```

The setup script will:
- Ask for your API key
- Configure the voice agent in your gateway
- Create `skill-config.json`

## Usage

### Voice Calls

Start the connection, then call your ClawdTalk number:

```bash
./scripts/connect.sh start      # Start (run in background or via cron)
./scripts/connect.sh stop       # Stop
./scripts/connect.sh status     # Check status
./scripts/connect.sh restart    # Restart
```

**Keep it running:**
```bash
# Add to crontab (crontab -e):
@reboot cd ~/clawd/skills/clawdtalk-client && ./scripts/connect.sh start
```

### SMS

```bash
./scripts/sms.sh send +15551234567 "Hello from ClawdTalk!"
./scripts/sms.sh send +15551234567 "With image" --media https://example.com/photo.jpg
./scripts/sms.sh list
./scripts/sms.sh list --contact +15551234567
./scripts/sms.sh conversations
```

### Missions

Missions dispatch AI assistants to make calls or send SMS to a list of targets:

```bash
# Create a mission
./scripts/missions.sh create '{
  "name": "Get quotes",
  "instructions": "Call and ask about pricing and availability.",
  "targets": [
    {"name": "ABC Corp", "phone": "+15551234567"},
    {"name": "XYZ Inc", "phone": "+15559876543"}
  ],
  "channel": "voice"
}'

# Monitor
./scripts/missions.sh list
./scripts/missions.sh status <mission_id>
./scripts/missions.sh events <mission_id>
./scripts/missions.sh cancel <mission_id>
```

## Configuration

`skill-config.json`:

```json
{
  "api_key": "cc_live_xxx",
  "server": "https://clawdtalk.com"
}
```

| Option | Description |
|--------|-------------|
| `api_key` | Your API key from clawdtalk.com |
| `server` | ClawdTalk server URL (default: `https://clawdtalk.com`) |

## How It Works

**Voice:** Phone calls connect via Telnyx to the ClawdTalk server. The WebSocket client (`ws-client.js`) routes transcribed speech to your gateway's `/v1/chat/completions` endpoint. Your bot processes it like any other message — same tools, same context. The response is converted to speech and played back.

**SMS:** Messages route through the ClawdTalk API. Inbound messages can trigger your bot via webhooks.

**Missions:** You define targets and instructions. ClawdTalk creates a Telnyx AI Assistant that makes the calls, following your script.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Auth failed | Regenerate API key at clawdtalk.com |
| Empty responses | Run `./setup.sh`, then `clawdbot gateway restart` |
| Connection drops | Check `tail -f .connect.log` for errors |
| Debug mode | `DEBUG=1 ./scripts/connect.sh restart` |

## License

MIT

## Links

- [ClawdTalk](https://clawdtalk.com) — Sign up and manage your account
- [Clawdbot](https://clawdbot.com) — AI assistant framework
- [Telnyx](https://telnyx.com) — Voice and messaging infrastructure
