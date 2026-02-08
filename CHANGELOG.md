# Changelog

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
