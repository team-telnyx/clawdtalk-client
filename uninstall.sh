#!/bin/bash
#
# ClawdTalk - Uninstall Script (v1.0)
#
# Removes the voice agent from gateway config, stops the WebSocket connection,
# and optionally deletes the skill-config.json.
#
# Usage: ./uninstall.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/skill-config.json"

echo ""
echo "📞 ClawdTalk Uninstall"
echo "======================"
echo ""

# Auto-detect gateway config
GATEWAY_CONFIG=""
CLI_NAME=""

if [ -f "${HOME}/.clawdbot/clawdbot.json" ]; then
    GATEWAY_CONFIG="${HOME}/.clawdbot/clawdbot.json"
    CLI_NAME="clawdbot"
elif [ -f "${HOME}/.openclaw/openclaw.json" ]; then
    GATEWAY_CONFIG="${HOME}/.openclaw/openclaw.json"
    CLI_NAME="openclaw"
fi

if [ -z "$CLI_NAME" ]; then
    if command -v clawdbot &> /dev/null; then
        CLI_NAME="clawdbot"
    elif command -v openclaw &> /dev/null; then
        CLI_NAME="openclaw"
    else
        CLI_NAME="clawdbot"
    fi
fi

# 1. Stop WebSocket connection
echo "🔌 Stopping WebSocket connection..."
if [ -f "$SCRIPT_DIR/scripts/connect.sh" ]; then
    bash "$SCRIPT_DIR/scripts/connect.sh" stop 2>/dev/null || true
    echo "   ✓ Connection stopped"
else
    echo "   ⚠️  connect.sh not found, skipping"
fi
echo ""

# 2. Remove voice agent from gateway config
echo "🔧 Removing voice agent from gateway config..."
gateway_changed=false

if [ -n "$GATEWAY_CONFIG" ] && [ -f "$GATEWAY_CONFIG" ]; then
    if ! command -v jq &> /dev/null; then
        echo "   ⚠️  jq not found — please remove the voice agent manually from $GATEWAY_CONFIG"
    else
        has_voice=$(jq -r '[.agents.list[]? | select(.id == "voice")] | length > 0' "$GATEWAY_CONFIG" 2>/dev/null || echo "false")

        if [ "$has_voice" = "true" ]; then
            tmp_config=$(mktemp)
            if jq '.agents.list = [.agents.list[]? | select(.id != "voice")]' "$GATEWAY_CONFIG" > "$tmp_config" 2>/dev/null; then
                mv "$tmp_config" "$GATEWAY_CONFIG"
                echo "   ✓ Voice agent removed from gateway config"
                gateway_changed=true
            else
                rm -f "$tmp_config"
                echo "   ⚠️  Could not update gateway config — remove voice agent manually"
            fi
        else
            echo "   ✓ No voice agent found (already clean)"
        fi
    fi
else
    echo "   ⚠️  Gateway config not found"
fi
echo ""

# 3. Restart gateway if we changed the config
if [ "$gateway_changed" = true ]; then
    echo "↻ Restarting gateway to apply changes..."
    if command -v "$CLI_NAME" &> /dev/null; then
        $CLI_NAME gateway restart 2>/dev/null && echo "   ✓ Gateway restarted" || echo "   ⚠️  Restart failed — run '$CLI_NAME gateway restart' manually"
    else
        echo "   ⚠️  Run '$CLI_NAME gateway restart' to apply changes"
    fi
    echo ""
fi

# 4. Clean up local files
echo "🗑️  Cleaning up..."
rm -f "$SCRIPT_DIR/.connect.pid"
rm -f "$SCRIPT_DIR/.connect.log"
echo "   ✓ Removed PID and log files"

read -p "Delete skill-config.json (contains your API key)? (y/N): " delete_config
if [[ "$delete_config" =~ ^[Yy]$ ]]; then
    rm -f "$CONFIG_FILE"
    echo "   ✓ skill-config.json deleted"
else
    echo "   ✓ skill-config.json kept"
fi
echo ""

echo "✅ ClawdTalk uninstalled."
echo ""
echo "To reinstall later, run: ./setup.sh"
echo ""
