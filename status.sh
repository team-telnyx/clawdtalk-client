#!/bin/bash
#
# ClawdTalk - Status Script
#
# Shows connection status, gateway status, and config summary.
#
# Usage: ./status.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/skill-config.json"

# Auto-detect CLI name
CLI_NAME="clawdbot"
if command -v openclaw &> /dev/null && ! command -v clawdbot &> /dev/null; then
    CLI_NAME="openclaw"
fi

echo ""
echo "📞 ClawdTalk Status"
echo "===================="
echo ""

# Check if configuration exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ No configuration found."
    echo ""
    echo "Run './setup.sh' to set up ClawdTalk for the first time."
    echo ""
    exit 1
fi

# Check for jq
if ! command -v jq &> /dev/null; then
    echo "⚠️  'jq' not found - showing raw config instead of parsed status"
    echo ""
    cat "$CONFIG_FILE"
    echo ""
    exit 0
fi

# Parse configuration
environment=$(jq -r '.environment // "production"' "$CONFIG_FILE")
api_key=$(jq -r ".api_keys.${environment} // .api_key // empty" "$CONFIG_FILE" 2>/dev/null || echo "")
server=$(jq -r ".servers.${environment} // .clawd_talk_server // \"https://clawdtalk.com\"" "$CONFIG_FILE" 2>/dev/null || echo "https://clawdtalk.com")
voice_model=$(jq -r '.voice_agent_model // "not set"' "$CONFIG_FILE")
tools_note="gateway-managed"
greeting=$(jq -r '.greeting // "default"' "$CONFIG_FILE")

# Display config summary
echo "📋 Configuration"
echo "----------------"
echo "Environment: $environment"
echo "Server: $server"
echo "Model: $voice_model"
echo "Tools: $tools_note"
echo "Greeting: ${greeting:0:50}$([ ${#greeting} -gt 50 ] && echo '...')"

if [ -z "$api_key" ] || [ "$api_key" = "null" ] || [ "$api_key" = "YOUR_API_KEY_HERE" ]; then
    echo "API Key: ❌ NOT SET"
    echo ""
    echo "Get your API key from https://clawdtalk.com → Dashboard"
    echo "Then add it to skill-config.json under api_keys.$environment"
else
    masked_key="${api_key:0:6}...${api_key: -4}"
    echo "API Key: ✅ $masked_key"
fi
echo ""

# WebSocket connection status
echo "🔌 WebSocket Connection"
echo "----------------------"

if [ -f "$SCRIPT_DIR/.connect.pid" ]; then
    ws_pid=$(cat "$SCRIPT_DIR/.connect.pid")
    if ps -p "$ws_pid" &> /dev/null; then
        echo "Status: ✅ CONNECTED (PID: $ws_pid)"
        if [ -f "$SCRIPT_DIR/.connect.log" ]; then
            echo ""
            echo "Recent activity:"
            tail -n 3 "$SCRIPT_DIR/.connect.log" 2>/dev/null | while IFS= read -r line; do
                echo "  $line"
            done
        fi
    else
        echo "Status: ❌ DISCONNECTED (stale PID)"
        rm -f "$SCRIPT_DIR/.connect.pid"
        echo "Start with: ./scripts/connect.sh start"
    fi
else
    echo "Status: ❌ NOT STARTED"
    echo "Start with: ./scripts/connect.sh start"
fi
echo ""

# Gateway status
echo "🌐 Gateway Status"
echo "----------------"
gateway_status=$($CLI_NAME gateway status 2>/dev/null || echo "error")
if [[ "$gateway_status" =~ "running" ]]; then
    echo "Status: ✅ RUNNING"
    if [[ "$gateway_status" =~ "http" ]]; then
        current_url=$(echo "$gateway_status" | grep -o 'https\?://[^[:space:]]*' | head -1)
        echo "URL: $current_url"
    fi
else
    echo "Status: ❌ NOT RUNNING"
    echo "Start with: $CLI_NAME gateway start"
fi
echo ""

# Management commands
echo "🔧 Commands"
echo "-----------"
echo "Reconfigure:     ./setup.sh"
echo "WebSocket:       ./scripts/connect.sh start|stop|status|restart"
echo "Gateway:         $CLI_NAME gateway status|start|stop|restart"
echo "Config:          cat $CONFIG_FILE"
echo "Logs:            tail -f .connect.log"
echo ""
