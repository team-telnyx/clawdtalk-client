# Local Development Setup

Test ClawdTalk client against a local backend without needing production credentials.

## Prerequisites

1. **Backend running locally** with ngrok tunnel:
   ```bash
   cd ~/clawd/projects/clawd-talk-backend/server
   npm run dev
   # In another terminal:
   ngrok http 3000
   ```

2. **Test user created** in local database with hashed API key:
   ```sql
   -- API key: cc_test_localdevkey123
   -- Hash: a7a9983a8b11c580c1687bb580a3eeee87a81dd390691d5be776939fd09dfd67
   INSERT INTO users (id, clawdbot_instance_id, phone_e164, phone_verified, pin_hash, bot_callback_url)
   VALUES (
     'test-user-1',
     'test-instance',
     '+15551234567',
     1,  -- phone_verified = true (required for WebRTC)
     'test',
     'http://localhost:18789'
   );
   
   INSERT INTO api_keys (id, user_id, key_prefix, key_hash)
   VALUES (
     'test-key-1',
     'test-user-1',
     'cc_test_',
     'a7a9983a8b11c580c1687bb580a3eeee87a81dd390691d5be776939fd09dfd67'
   );
   ```

## Quick Start

```bash
# 1. Copy local config template
cp skill-config.local.example.json skill-config.json

# 2. Update your ngrok URL in skill-config.json
#    Replace YOUR-NGROK-URL with your actual ngrok subdomain

# 3. Install deps
npm install

# 4. Start the client
./scripts/connect.sh start

# Or with server override (no config edit needed):
./scripts/connect.sh start --server https://your-ngrok-url.ngrok-free.dev
```

## Test Credentials

| Field | Value |
|-------|-------|
| API Key | `cc_test_localdevkey123` |
| API Key Hash | `a7a9983a8b11c580c1687bb580a3eeee87a81dd390691d5be776939fd09dfd67` |
| Test Phone | `+15551234567` |

## What This Tests

1. **WebSocket connection** - Client connects to local backend
2. **Authentication** - API key validation against hashed credentials
3. **Voice call routing** - STT → Gateway → TTS pipeline
4. **Tool execution** - Agent tool calls via /tools/invoke
5. **Session routing** - Calls routed to main Clawdbot session

## Troubleshooting

### Connection refused
- Check backend is running: `curl http://localhost:3000/health`
- Check ngrok is active: `curl https://your-url.ngrok-free.dev/health`

### Auth failed
- Verify API key hash in database matches expected value
- Check `hashApiKey()` function uses SHA-256

### No gateway token
- Ensure your local Clawdbot/OpenClaw gateway is running
- Check `~/.clawdbot/clawdbot.json` or `~/.openclaw/openclaw.json` exists with auth token

## Debug Mode

```bash
DEBUG=1 node scripts/ws-client.js --server https://your-ngrok-url.ngrok-free.dev
```

Logs all incoming WebSocket messages for debugging.
