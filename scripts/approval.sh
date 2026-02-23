#!/bin/bash
#
# ClawdTalk Approval Requests
#
# Request user approval for sensitive actions during voice calls.
# Sends push notification to user's phone and waits for response.
#
# Usage:
#   ./approval.sh request "Book flight LAX→JFK for $450"
#   ./approval.sh request "Send email to john@example.com" --details "Subject: Meeting tomorrow"
#   ./approval.sh request "Delete 50 files" --biometric --timeout 120
#   ./approval.sh status <request_id>
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SKILL_DIR/skill-config.json"

# Default timeout for waiting on approval (seconds)
DEFAULT_TIMEOUT=300
POLL_INTERVAL=2

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Error: Configuration not found. Run ./setup.sh first.${NC}" >&2
        exit 1
    fi
}

# Check if user has any registered devices (from ws-client cache)
check_devices() {
    local status_file="$SKILL_DIR/.device-status"
    if [ -f "$status_file" ]; then
        local has_devices
        has_devices=$(jq -r '.has_devices // false' "$status_file" 2>/dev/null)
        if [ "$has_devices" = "false" ]; then
            return 1  # No devices
        fi
    fi
    return 0  # Has devices (or unknown - assume yes)
}

get_config() {
    local key="$1"
    local value
    value=$(jq -r ".$key // empty" "$CONFIG_FILE" 2>/dev/null)
    
    # Resolve ${ENV_VAR} references
    if [[ "$value" =~ ^\$\{([A-Z_][A-Z0-9_]*)\}$ ]]; then
        local env_var="${BASH_REMATCH[1]}"
        value="${!env_var:-$value}"
    fi
    
    echo "$value"
}

request_approval() {
    local action=""
    local details=""
    local require_biometric=false
    local timeout=$DEFAULT_TIMEOUT
    local wait=true
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --details)
                details="$2"
                shift 2
                ;;
            --biometric)
                require_biometric=true
                shift
                ;;
            --timeout)
                timeout="$2"
                shift 2
                ;;
            --no-wait)
                wait=false
                shift
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                exit 1
                ;;
            *)
                if [ -z "$action" ]; then
                    action="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [ -z "$action" ]; then
        echo -e "${RED}Error: Action description required${NC}" >&2
        echo "Usage: $0 request \"Description of action\" [--details \"More info\"] [--biometric] [--timeout 300]" >&2
        exit 1
    fi
    
    # Check if user has devices - skip API call entirely if not
    if ! check_devices; then
        echo "no_devices"
        exit 0
    fi
    
    local api_key
    api_key=$(get_config "api_key")
    local server
    server=$(get_config "server")
    server="${server:-https://clawdtalk.com}"
    
    if [ -z "$api_key" ]; then
        echo -e "${RED}Error: No API key configured${NC}" >&2
        exit 1
    fi
    
    # Build request body
    local body
    body=$(jq -n \
        --arg action "$action" \
        --arg details "$details" \
        --argjson biometric "$require_biometric" \
        --argjson expires_in "$timeout" \
        '{
            action: $action,
            require_biometric: $biometric,
            expires_in: $expires_in
        } + (if $details != "" then {details: $details} else {} end)'
    )
    
    # Create approval request
    local response
    response=$(curl -s -X POST "$server/v1/approvals" \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -d "$body")
    
    local request_id
    request_id=$(echo "$response" | jq -r '.request_id // empty')
    
    if [ -z "$request_id" ]; then
        local error
        error=$(echo "$response" | jq -r '.message // .error // "Unknown error"')
        echo -e "${RED}Error creating approval request: $error${NC}" >&2
        exit 1
    fi
    
    local devices_notified
    devices_notified=$(echo "$response" | jq -r '.devices_notified // 0')
    
    if [ "$devices_notified" -eq 0 ]; then
        # No devices registered — return immediately
        echo "no_devices"
        exit 0
    fi
    
    if [ "$wait" = false ]; then
        # Just return the request ID, don't wait
        echo "$request_id"
        exit 0
    fi
    
    # Wait for response
    echo -e "Waiting for approval (timeout: ${timeout}s)..." >&2
    
    local start_time
    start_time=$(date +%s)
    local end_time=$((start_time + timeout))
    
    while true; do
        local current_time
        current_time=$(date +%s)
        
        if [ "$current_time" -ge "$end_time" ]; then
            echo "timeout"
            exit 0
        fi
        
        # Check status
        local status_response
        status_response=$(curl -s "$server/v1/approvals/$request_id" \
            -H "Authorization: Bearer $api_key")
        
        local status
        status=$(echo "$status_response" | jq -r '.status // "pending"')
        
        case "$status" in
            approved)
                echo "approved"
                exit 0
                ;;
            denied)
                echo "denied"
                exit 0
                ;;
            expired)
                echo "expired"
                exit 0
                ;;
            pending)
                # Still waiting
                sleep "$POLL_INTERVAL"
                ;;
            *)
                echo -e "${RED}Unexpected status: $status${NC}" >&2
                echo "error"
                exit 1
                ;;
        esac
    done
}

check_status() {
    local request_id="$1"
    
    if [ -z "$request_id" ]; then
        echo -e "${RED}Error: Request ID required${NC}" >&2
        echo "Usage: $0 status <request_id>" >&2
        exit 1
    fi
    
    local api_key
    api_key=$(get_config "api_key")
    local server
    server=$(get_config "server")
    server="${server:-https://clawdtalk.com}"
    
    local response
    response=$(curl -s "$server/v1/approvals/$request_id" \
        -H "Authorization: Bearer $api_key")
    
    local status
    status=$(echo "$response" | jq -r '.status // "unknown"')
    
    echo "$status"
}

list_approvals() {
    local status="${1:-pending}"
    
    local api_key
    api_key=$(get_config "api_key")
    local server
    server=$(get_config "server")
    server="${server:-https://clawdtalk.com}"
    
    curl -s "$server/v1/approvals?status=$status" \
        -H "Authorization: Bearer $api_key" | jq '.'
}

show_help() {
    cat << 'EOF'
ClawdTalk Approval Requests

Request user approval for sensitive actions. Sends a push notification
to the user's phone and waits for their response.

COMMANDS:
  request <action>    Create approval request and wait for response
  status <id>         Check status of an existing request
  list [status]       List approval requests (default: pending)

OPTIONS (for request):
  --details "text"    Additional details to show user
  --biometric         Require biometric auth (fingerprint/face) to approve
  --timeout <secs>    How long to wait for response (default: 300)
  --no-wait           Return request ID immediately, don't wait

EXAMPLES:
  # Simple approval
  ./approval.sh request "Send email to boss@company.com"

  # With details
  ./approval.sh request "Book flight" --details "Delta 123, LAX→JFK, $450, Feb 15"

  # Require biometric for sensitive action
  ./approval.sh request "Transfer $5000 to external account" --biometric

  # Quick check without waiting
  id=$(./approval.sh request "Delete files" --no-wait)
  # ... do other things ...
  status=$(./approval.sh status "$id")

OUTPUT:
  approved    - User approved the action
  denied      - User denied the action
  timeout     - No response within timeout period
  expired     - Request expired before user responded
  no_devices  - User has no mobile app installed (no registered devices)
  pending     - Still waiting (for status command)
EOF
}

# Main
check_config

case "${1:-}" in
    request)
        shift
        request_approval "$@"
        ;;
    status)
        shift
        check_status "$@"
        ;;
    list)
        shift
        list_approvals "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
