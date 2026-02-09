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
echo "📞 ClawdTalk Status (v1.2.4)"
echo "============================"
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
api_key=$(jq -r '.api_key // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
server=$(jq -r '.server // "https://clawdtalk.com"' "$CONFIG_FILE" 2>/dev/null || echo "https://clawdtalk.com")

# Display config summary
echo "📋 Configuration"
echo "----------------"
echo "Server: $server"

if [ -z "$api_key" ] || [ "$api_key" = "null" ] || [ "$api_key" = "YOUR_API_KEY_HERE" ]; then
    echo "API Key: ❌ NOT SET"
    echo ""
    echo "Get your API key from https://clawdtalk.com → Dashboard"
    echo "Then add it to skill-config.json"
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

# Try multiple detection methods
gateway_running=false

# Method 1: Check for gateway process directly
if pgrep -f "clawdbot.*gateway" &>/dev/null || pgrep -f "openclaw.*gateway" &>/dev/null; then
    gateway_running=true
fi

# Method 2: Check for node process with gateway in cwd
if ! $gateway_running && pgrep -f "node.*clawd" &>/dev/null; then
    gateway_running=true
fi

# Method 3: Try the CLI status command
if ! $gateway_running; then
    gateway_status=$($CLI_NAME gateway status 2>/dev/null || echo "")
    if [[ "$gateway_status" =~ "running" ]] || [[ "$gateway_status" =~ "Gateway" ]] || [[ "$gateway_status" =~ "pid" ]]; then
        gateway_running=true
    fi
fi

if $gateway_running; then
    echo "Status: ✅ RUNNING"
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
