# ClawdTalk Skill — Agent Setup Guide

This document tells you (the agent) how to configure the `clawdtalk-client` skill after installation. The goal: get the user's ClawdTalk working with zero manual config from them beyond providing an API key.

**Important:** After running `clawdhub install`, the output tells you where the skill was installed (e.g. `Installed clawdtalk-client -> /path/to/skills/clawdtalk-client`). Use that exact path for all subsequent commands. This document uses `<skill_directory>` as a placeholder for that path.

## Setup Steps (Summary)

| # | What | How | Notes |
|---|------|-----|-------|
| 1 | Install the skill | `clawdhub install clawdtalk-client --registry https://clawhub.ai` | User triggers this. You run the command. |
| 2 | Get the API key | Ask the user if they didn't provide one | **Mandatory. Do not proceed without it.** |
| 3 | Validate the API key | `python3 scripts/telnyx_api.py check-key` | Confirms the key is valid before proceeding. |
| 4 | Run `setup.sh` | `bash ./setup.sh` (interactive, needs PTY) | Handles config, gateway, deps, names. |
| 5 | Trim agent name | Edit `skill-config.json` if name has extra text | `setup.sh` sometimes pulls full IDENTITY.md line. |
| 6 | Start the WebSocket | `bash ./scripts/connect.sh start` | Enables voice calls. |
| 7 | Verify | `bash ./status.sh` | Confirm everything is green. |

---

## Step 1: Install the Skill

The user will ask you to run:

```bash
clawdhub install clawdtalk-client --registry https://clawhub.ai
```

This installs the skill into your workspace at `skills/clawdtalk-client/`. Note the exact install path from the output. Once installed, read this document before doing anything else.

## Step 2: Get the API Key

**You cannot proceed without an API key.** If the user did not include their API key in the install message, you MUST stop and ask them for it now. Do not skip this step. Do not attempt setup without a key.

Ask something like: *"I need your ClawdTalk API key to finish setup. You can get one from clawdtalk.com → Dashboard. Paste it here when you have it."*

The key looks like `cc_live_...` (a long hex string). Once you have it, move to step 3.

## Step 3: Validate the API Key

Before running setup, verify the key actually works:

```bash
cd <skill_directory>
CLAWDTALK_API_KEY="<the_key>" python3 scripts/telnyx_api.py check-key
```

You should see: `API key configured: cc_live_...xxx`

If it fails or returns an auth error, the key is invalid. Ask the user to regenerate it at [clawdtalk.com](https://clawdtalk.com) → Dashboard. **Do not proceed with setup until the key validates.**

## Step 4: Run `setup.sh` (Interactive)

**This is the main setup script. Use it. Do not write `skill-config.json` manually.**

The script handles:
- Saving the API key
- Auto-detecting gateway config (port, token, agent ID)
- Adding a `voice` agent to the gateway config
- Installing Node.js dependencies
- Auto-detecting owner and agent names from `USER.md` / `IDENTITY.md`
- Checking `sessions_send` is in `gateway.tools.allow`
- Writing `skill-config.json` with all the correct values

### How to Run It

The script uses `read -p` for interactive prompts. **It must run under `bash` with a PTY**, not `zsh`:

```bash
cd <skill_directory>
bash ./setup.sh
# Must use: pty=true, background=true
```

### Interactive Prompts (In Order)

The script will ask these questions. Here's how to answer each:

| Prompt | What to answer | Notes |
|--------|---------------|-------|
| `Do you want to reconfigure? (y/N):` | `y` | Only appears if `skill-config.json` already exists. |
| `Enter your API key:` | Paste the user's API key | The `cc_live_...` key from the user. |
| `Auto-detect names from workspace? (Y/n):` | `Y` | Pulls owner name from `USER.md`, agent name from `IDENTITY.md`. |
| `Add sessions_send to gateway.tools.allow? (Y/n):` | `Y` | Only appears if not already allowed. Required for voice calls. |

If the script asks for a name manually (auto-detect failed), use the owner's name from `USER.md` and your agent name from `IDENTITY.md`.

### What Can Go Wrong

| Problem | Symptom | Fix |
|---------|---------|-----|
| Ran with `zsh` instead of `bash` | `read:XX: -p: no coprocess` error | Re-run with `bash ./setup.sh` |
| No PTY | Script exits immediately or hangs | Use `pty=true` when spawning the process |
| No API key provided | Setup completes but key is `null` | Edit `skill-config.json` and add the key, or re-run setup |
| Gateway config not found | Warning about manual steps | Check `~/.openclaw/openclaw.json` or `~/.clawdbot/clawdbot.json` exists |
| `jq` not installed | Script fails at requirements check | Install jq: `brew install jq` (macOS) or `apt install jq` (Linux) |
| `node` not installed | Script fails at requirements check | Install Node.js |

## Step 5: Verify and Clean Up `skill-config.json`

After setup completes, read `skill-config.json` and check:

1. **`api_key`** — should be the user's key (not `null`, not `YOUR_API_KEY_HERE`)
2. **`agent_name`** — should be clean (e.g. `"PAL-01"`, not `"PAL-01 (some extra description)"`)
3. **`gateway_url`** — should be `http://127.0.0.1:<port>` matching the gateway config
4. **`gateway_token`** — should be populated
5. **`agent_id`** — should be `"main"` (or the default agent's ID)

If `agent_name` has extra text from IDENTITY.md, trim it to just the name. The setup script's grep can be greedy.

### Example of a Clean Config

```json
{
  "api_key": "cc_live_xxxxxxxxxxxxxxxxxxxx",
  "server": "https://clawdtalk.com",
  "owner_name": "Ciaran",
  "agent_name": "PAL-01",
  "greeting": "Hey Ciaran, what's up?",
  "gateway_url": "http://127.0.0.1:18789",
  "gateway_token": "xxxxxxxxxxxxxxxxxxxxxxxx",
  "agent_id": "main"
}
```

## Step 6: Start the WebSocket Connection

```bash
cd <skill_directory>
bash ./scripts/connect.sh start
```

This starts a background Node.js process that maintains a WebSocket connection to the ClawdTalk server. It enables:
- **Inbound voice calls** — user calls their ClawdTalk number, speech is transcribed and routed to your main agent session
- **Outbound voice calls** — you can initiate calls via the scripts
- **Approval requests** — biometric/push approvals during voice calls

The process runs in the background and writes logs to `.connect.log` in the skill directory.

### What Can Go Wrong

| Problem | Symptom | Fix |
|---------|---------|-----|
| Config missing | `❌ Configuration not found. Run './setup.sh' first.` | Run setup.sh first |
| API key invalid | Connection drops immediately, auth errors in `.connect.log` | User needs to regenerate key at clawdtalk.com |
| `sessions_send` not allowed | Voice calls connect but agent can't process requests (silent 404s) | Add `sessions_send` to `gateway.tools.allow` and restart gateway |
| Port/token changed | Connection fails or agent responses don't work | Re-run `setup.sh` to update config |
| Node modules missing | `Cannot find module 'ws'` in logs | Run `npm install --production` in the skill directory |
| Already running | `⚠️ Connection already running` | That's fine, it's idempotent. Use `restart` if you need to refresh. |

## Step 7: Verify Everything

Run the status script:

```bash
cd <skill_directory>
bash ./status.sh
```

You should see:
- **API Key**: ✅ with a masked key
- **WebSocket Connection**: ✅ CONNECTED with a PID
- **Gateway Status**: ✅ RUNNING

If anything shows ❌, check the troubleshooting table above for that component.

---

## Troubleshooting: "Bot not connected" / Connection Errors

If the user reports a connection error from the ClawdTalk portal (e.g. "Bot not connected. Make sure your Clawdbot is running with the ClawdTalk skill installed and your API key configured."), the problem is almost always the WebSocket connection.

### Step 1: Check WebSocket Status

```bash
cd <skill_directory>
bash ./scripts/connect.sh status
```

If it shows `DISCONNECTED` or a stale PID, restart it:

```bash
bash ./scripts/connect.sh restart
```

### Step 2: Check WebSocket Logs

The logs are the single best source of truth for connection issues:

```bash
# Last 30 lines
tail -30 <skill_directory>/.connect.log

# Follow live (useful during debugging)
tail -f <skill_directory>/.connect.log
```

### Common Log Errors and Fixes

| Log error | Cause | Fix |
|-----------|-------|-----|
| `Authentication failed` / `401` | API key is invalid or expired | User regenerates key at clawdtalk.com, re-run `setup.sh` |
| `ECONNREFUSED 127.0.0.1:<port>` | Gateway is not running | Start the gateway: `openclaw gateway start` |
| `Cannot find module 'ws'` | Node dependencies not installed | `cd <skill_dir> && npm install --production` |
| `Token mismatch` / `403` from gateway | Gateway token in config doesn't match actual token | Re-run `setup.sh` to refresh gateway details |
| `Connection closed` / repeated reconnects | Server-side issue or network instability | Check the backoff pattern in logs. If it stabilises, it's transient. If not, check the API key. |
| `sessions_send` 404 | Tool not allowed on gateway HTTP API | Add `sessions_send` to `gateway.tools.allow` and restart gateway |

### Step 3: Verify from the Portal

After fixing the issue and confirming `connect.sh status` shows `CONNECTED`, have the user go back to the ClawdTalk portal and click **Test Connection** (or **Retry**). It should go green.

---

## Gateway Requirements (Important)

The voice system works by routing transcribed speech to your main agent session via the Gateway HTTP tools API. Two things must be true:

### 1. `sessions_send` Must Be Allowed

The gateway blocks `sessions_send` over HTTP by default (security measure). Without it, voice calls connect but the AI hears you and can't do anything.

`setup.sh` handles this automatically. If it didn't (or was skipped), add it manually:

```bash
openclaw config patch '{"gateway":{"tools":{"allow":["sessions_send"]}}}'
openclaw gateway restart
```

**WARNING**: This goes under `gateway.tools.allow`, NOT top-level `tools.allow`. Putting it at the top level restricts your agent to ONLY that tool, breaking everything.

### 2. Voice Agent Must Exist

`setup.sh` adds a `voice` agent to the gateway's `agents.list`. If it wasn't added (check with `jq '.agents.list[] | select(.id == "voice")' ~/.openclaw/openclaw.json`), the gateway needs a restart after setup adds it.

---

## After Setup: What's Available

Once setup is complete and the WebSocket is connected, the user can:
- **Receive voice calls** on their ClawdTalk number (calls route to you, the agent)
- **Make outbound calls** via `./scripts/call.sh`
- **Send SMS** via `./scripts/sms.sh`
- **Run AI Missions** via `python3 scripts/telnyx_api.py` (multi-step outreach campaigns)

Full usage docs are in `SKILL.md` within the skill directory.

---

## Quick Reference: Key Paths

| What | Path |
|------|------|
| Skill directory | `<workspace>/skills/clawdtalk-client/` |
| Config | `<skill_dir>/skill-config.json` |
| Setup script | `<skill_dir>/setup.sh` |
| Connect script | `<skill_dir>/scripts/connect.sh` |
| Status script | `<skill_dir>/status.sh` |
| WebSocket logs | `<skill_dir>/.connect.log` |
| PID file | `<skill_dir>/.connect.pid` |
| Full skill docs | `<skill_dir>/SKILL.md` |
| Gateway config (OpenClaw) | `~/.openclaw/openclaw.json` |
| Gateway config (Clawdbot) | `~/.clawdbot/clawdbot.json` |
