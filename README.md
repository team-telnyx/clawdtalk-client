# ClawdTalk Client

Give your OpenClaw bot a phone number.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-2.0.1-green.svg)](https://github.com/team-telnyx/clawdtalk-client)

Voice calling and SMS messaging for [Clawdbot](https://clawdbot.com). Talk to your bot by phone or exchange texts. Powered by [Telnyx](https://telnyx.com).

## What's New in 2.0

- **Approval requests**: Voice callers can request bot approval for actions that require confirmation
- **Missions**: Configure AI-powered outbound call campaigns for automated outreach
- **Call control ID logging**: Track individual call legs with unique control IDs for better debugging

## Changelog

See [CHANGELOG.md](./CHANGELOG.md) for the full release history.

## Architecture

```
Phone → Telnyx (STT) → ClawdTalk Server → WebSocket → OpenClaw Gateway → Agent → TTS → Phone
          │                                      │
          └── Speech-to-text                     └── Routes to /v1/chat/completions
          │                                      │
          └── Text-to-speech                     └── Bot processes like any message
```

## Features

- **Voice calls**: Real-time conversations with your bot via phone
- **SMS messaging**: Send and receive text messages
- **Tool integration**: Your bot's full capabilities, accessible by voice
- **Approval requests**: Get caller confirmation for sensitive actions
- **Missions**: Run AI-driven outbound call campaigns
- **Call control IDs**: Debug calls with unique leg identifiers

## Updating

To update to the latest version, run:

```bash
./update.sh
```

Or just ask your bot to update by pasting the repo URL:

> Update clawdtalk to the latest version: https://github.com/team-telnyx/clawdtalk-client

The update script pulls the latest changes and restarts the connection if needed.

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

The setup script will ask for your API key, configure the voice agent in your gateway, and create `skill-config.json`.

## Usage

### Voice Calls

Start the connection, then call your ClawdTalk number:

```bash
./scripts/connect.sh start      # Start (run in background or via cron)
./scripts/connect.sh stop       # Stop
./scripts/connect.sh status     # Check status
./scripts/connect.sh restart    # Restart
```

Keep it running via crontab:

> **Note:** This keeps a persistent WebSocket connection to clawdtalk.com. Voice transcripts are transmitted in real-time when calls are active.

```bash
# Add to crontab (crontab -e):
@reboot cd ~/clawd/skills/clawdtalk-client && ./scripts/connect.sh start
```

### Outbound Calls

Have the bot call you:

```bash
./scripts/call.sh                    # Call with default greeting
./scripts/call.sh "Hey, what's up?"  # Custom greeting
./scripts/call.sh status <call_id>   # Check status
./scripts/call.sh end <call_id>      # End call
```

### SMS

```bash
./scripts/sms.sh send +15551234567 "Hello from ClawdTalk!"
./scripts/sms.sh send +15551234567 "With image" --media https://example.com/photo.jpg
./scripts/sms.sh list
./scripts/sms.sh list --contact +15551234567
./scripts/sms.sh conversations
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

### Environment Variable Support

Instead of storing credentials in plaintext, use `${ENV_VAR}` references:

```json
{
  "api_key": "${CLAWDTALK_API_KEY}",
  "server": "https://clawdtalk.com"
}
```

Set the variable in one of these locations (checked in order):
- `~/.openclaw/.env`
- `~/.clawdbot/.env`
- `<skill-dir>/.env`

Example `.env` file:

```bash
CLAWDTALK_API_KEY=cc_live_xxx
```

The gateway auth token in `openclaw.json`/`clawdbot.json` also supports this:

```json
{
  "gateway": {
    "auth": {
      "token": "${GATEWAY_TOKEN}"
    }
  }
}
```

### Gateway Tools (Required)

The voice assistant uses `sessions_send` to proxy questions to your Clawdbot. You must allow it on the gateway's `/tools/invoke` endpoint:

```json
{
  "gateway": {
    "tools": {
      "allow": ["sessions_send"]
    }
  }
}
```

Without this, the voice assistant will handle calls on its own but won't be able to forward questions to your bot (you'll see `sessions_send failed: 404` in the logs).

Run `./scripts/connect.sh status` to check if this is configured correctly.

## How It Works

**Voice:** Phone calls connect via Telnyx to the ClawdTalk server. The WebSocket client (`ws-client.js`) routes transcribed speech to your gateway's `/v1/chat/completions` endpoint. Your bot processes it like any other message with the same tools and context. The response is converted to speech and played back.

**SMS:** Messages route through the ClawdTalk API. Inbound messages can trigger your bot via webhooks.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Auth failed | Regenerate API key at clawdtalk.com |
| Empty responses | Run `./setup.sh`, then `clawdbot gateway restart` |
| `sessions_send failed: 404` | Add `sessions_send` to `gateway.tools.allow` in your OpenClaw config (see Gateway Tools above) |
| Connection drops | Check `tail -f .connect.log` for errors |
| Debug mode | `DEBUG=1 ./scripts/connect.sh restart` |

## License

MIT

## Links

- [ClawdTalk](https://clawdtalk.com) — Sign up and manage your account
- [Clawdbot](https://clawdbot.com) — AI assistant framework
- [Telnyx](https://telnyx.com) — Voice and messaging infrastructure
