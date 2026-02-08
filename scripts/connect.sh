#!/bin/bash
#
# ClawdTalk - WebSocket Connection Manager
#
# Manages the WebSocket connection to ClawdTalk server for receiving
# voice transcriptions and sending responses.
# Works with both Clawdbot and OpenClaw.
#
# Usage: ./connect.sh {start|stop|status|restart} [--server <url>]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SKILL_DIR/skill-config.json"
PID_FILE="$SKILL_DIR/.connect.pid"
LOG_FILE="$SKILL_DIR/.connect.log"

# Parse server override from args
SERVER_FLAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)
            SERVER_FLAG="--server $2"
            shift 2
            ;;
        *)
            CMD="${CMD:-$1}"
            shift
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}📞 Clawd Talk Connection Manager${NC}"
    echo "================================="
    echo ""
}

check_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}❌ Configuration not found. Run './setup.sh' first.${NC}"
        exit 1
    fi
    
    # Check if we have API key
    local api_key=$(jq -r '.api_key // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -z "$api_key" ] || [ "$api_key" = "null" ] || [ "$api_key" = "YOUR_API_KEY_HERE" ]; then
        echo -e "${RED}❌ No API key configured.${NC}"
        echo ""
        echo "Get your API key from https://clawdtalk.com → Dashboard"
        echo "Then add it to skill-config.json"
        exit 1
    fi
}

check_dependencies() {
    for tool in node jq; do
        if ! command -v "$tool" &> /dev/null; then
            echo -e "${RED}❌ Required tool '$tool' is not installed.${NC}"
            exit 1
        fi
    done
    
    # Check node_modules exist
    if [ ! -d "$SKILL_DIR/node_modules/ws" ]; then
        echo -e "${YELLOW}📦 Installing dependencies...${NC}"
        (cd "$SKILL_DIR" && npm install --production 2>/dev/null)
        if [ ! -d "$SKILL_DIR/node_modules/ws" ]; then
            echo -e "${RED}❌ Failed to install dependencies. Run 'npm install' in $SKILL_DIR${NC}"
            exit 1
        fi
        echo -e "   ${GREEN}✓ Dependencies installed${NC}"
    fi
}

is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" &> /dev/null; then
            return 0
        else
            # Stale PID file
            rm -f "$PID_FILE"
            return 1
        fi
    fi
    return 1
}

start_connection() {
    if is_running; then
        echo -e "${YELLOW}⚠️  Connection already running (PID: $(cat "$PID_FILE"))${NC}"
        return 0
    fi
    
    echo "🚀 Starting WebSocket connection..."
    
    # Source .env files for environment variable resolution
    # Supports both OpenClaw and Clawdbot paths
    [ -f "$HOME/.openclaw/.env" ] && . "$HOME/.openclaw/.env"
    [ -f "$HOME/.clawdbot/.env" ] && . "$HOME/.clawdbot/.env"
    [ -f "$SKILL_DIR/.env" ] && . "$SKILL_DIR/.env"
    
    # Rotate log if it's too big (> 1MB)
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 1048576 ]; then
        echo "🔄 Rotating large log file..."
        mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    fi
    
    # Start the WebSocket client in background (append to log)
    nohup node "$SCRIPT_DIR/ws-client.js" $SERVER_FLAG >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo $pid > "$PID_FILE"
    
    # Give it a moment to start
    sleep 2
    
    # Check if it's still running
    if ps -p "$pid" &> /dev/null; then
        echo -e "   ✓ ${GREEN}WebSocket client started (PID: $pid)${NC}"
        echo ""
        echo "Use './scripts/connect.sh status' to check connection health"
        echo "Logs: $LOG_FILE"
    else
        rm -f "$PID_FILE"
        echo -e "   ❌ ${RED}Failed to start WebSocket client${NC}"
        echo ""
        echo "Check logs: $LOG_FILE"
        exit 1
    fi
}

stop_connection() {
    if ! is_running; then
        echo -e "${YELLOW}⚠️  Connection not running${NC}"
        return 0
    fi
    
    local pid=$(cat "$PID_FILE")
    echo "🛑 Stopping WebSocket connection (PID: $pid)..."
    
    # Try graceful shutdown first
    if kill "$pid" 2>/dev/null; then
        # Wait up to 5 seconds for graceful shutdown
        for i in {1..5}; do
            if ! ps -p "$pid" &> /dev/null; then
                break
            fi
            sleep 1
        done
        
        # Force kill if still running
        if ps -p "$pid" &> /dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    
    rm -f "$PID_FILE"
    echo -e "   ✓ ${GREEN}WebSocket client stopped${NC}"
}

show_status() {
    print_status
    
    if is_running; then
        local pid=$(cat "$PID_FILE")
        echo -e "Status: ${GREEN}CONNECTED${NC} (PID: $pid)"
        
        # Show recent log lines
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo "Recent activity:"
            echo "================"
            tail -n 5 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
                echo "  $line"
            done
        fi
    else
        echo -e "Status: ${RED}DISCONNECTED${NC}"
        
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo "Last error (if any):"
            echo "==================="
            tail -n 3 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
                if [[ "$line" =~ (ERROR|Error|error|FAILED|Failed|failed) ]]; then
                    echo -e "  ${RED}$line${NC}"
                else
                    echo "  $line"
                fi
            done
        fi
    fi
    
    echo ""
    echo "Configuration:"
    echo "============="
    local server_url=$(jq -r '.server // "https://clawdtalk.com"' "$CONFIG_FILE" 2>/dev/null)
    
    echo "  Server: $server_url"
    echo ""
    echo "Commands:"
    echo "========="
    echo "  start    - Start WebSocket connection"
    echo "  stop     - Stop WebSocket connection"  
    echo "  restart  - Restart WebSocket connection"
    echo "  status   - Show this status"
    echo "  watchdog - Check if running and restart if needed"
    echo ""
    echo "Flags:"
    echo "  --server <url>  - Override server URL"
    echo ""
}

restart_connection() {
    echo "🔄 Restarting WebSocket connection..."
    stop_connection
    sleep 1
    start_connection
}

watchdog_check() {
    # Silent watchdog - only log when taking action
    if ! is_running; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCHDOG: Process not running, restarting..." >> "$SKILL_DIR/.watchdog.log"
        check_config 2>/dev/null || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCHDOG: Config check failed, skipping restart" >> "$SKILL_DIR/.watchdog.log"
            return 1
        }
        check_dependencies 2>/dev/null || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCHDOG: Dependencies check failed, skipping restart" >> "$SKILL_DIR/.watchdog.log"
            return 1
        }
        start_connection >> "$SKILL_DIR/.watchdog.log" 2>&1
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCHDOG: Restart completed" >> "$SKILL_DIR/.watchdog.log"
    fi
}

# Main command handling
case "${CMD:-}" in
    start)
        print_status
        check_config
        check_dependencies
        start_connection
        ;;
    stop)
        print_status
        stop_connection
        ;;
    restart)
        print_status
        check_config
        check_dependencies
        restart_connection
        ;;
    status)
        check_config
        show_status
        ;;
    watchdog)
        # Silent watchdog mode - used by cron
        watchdog_check
        ;;
    *)
        print_status
        echo -e "${RED}❌ Invalid command${NC}"
        echo ""
        echo "Usage: $0 {start|stop|status|restart|watchdog} [--server <url>]"
        echo ""
        echo "Commands:"
        echo "  start    - Start WebSocket connection to ClawdTalk server"
        echo "  stop     - Stop WebSocket connection"
        echo "  restart  - Restart WebSocket connection"
        echo "  status   - Show connection status and configuration"
        echo "  watchdog - Check if running and restart if needed (for cron)"
        echo ""
        echo "Flags:"
        echo "  --server <url>  - Override server URL"
        exit 1
        ;;
esac
