# Changelog

## 1.2.9
- **Fix**: Use correct `/tools/invoke` endpoint for sessions_send
- Previous version used non-existent `/v1/sessions/send` (405 error)

## 1.2.8
- **Fix**: Use `sessions_send` to route call outcomes to main persistent session
- Call reports now appear in your Telegram/Discord/etc. session instead of ephemeral sessions

## 1.2.7
- **New**: `update.sh` script for easy self-updates from GitHub
- **New**: `dist/clawdtalk-client-latest.zip` in repo for direct downloads
- Run `./update.sh` to check for and install updates

## 1.2.6
- **Fix**: Route call outcomes to `main` agent instead of legacy `voice` agent
- Call reports now reach your primary session correctly

## 1.2.5
- **Call outcome reporting**: After calls end, skill reports what happened to the user
  - Voicemail left (with message preview)
  - Call completed (with duration)
  - No answer / silence detected
  - Fax machine detected
  - Voicemail failed (no beep)
- Enhanced call.ended event handling with detailed outcome info

## 1.2.2
- **Outbound calls**: New `call.sh` script to have your bot call you
- **Missions removed**: Batch outreach feature disabled (not ready for production)
- Updated docs and removed missions.sh

## 1.2.0
- **SMS Reply Support**: Incoming SMS messages now route to your main agent session
- Agent generates response and automatically sends reply via ClawdTalk
- SMS replies truncated to fit SMS limits

## 1.1.0
- Deep tool requests now route to main agent session for full context/memory access
- Auto-detect owner and agent names from USER.md and IDENTITY.md
- Personalized greetings using detected owner name
- Added "drip progress updates" - brief spoken updates during tool execution
- Added `--server <url>` flag to connect.sh for server override
- Removed hardcoded model - uses gateway's configured model
- Better timeout handling with specific error messages
- Sends owner/agent names during auth for assistant personalization

## 1.0.0
- Initial release
- Voice calling with full tool execution
- SMS messaging support
- Missions support
