#!/usr/bin/env bash
#
# ClawdTalk Outbound Call Script
# Initiates an outbound call to the user's verified phone number
#
# Usage:
#   ./scripts/call.sh                    # Call with default greeting
#   ./scripts/call.sh "Hey, what's up?"  # Call with custom greeting
#   ./scripts/call.sh status <call_id>   # Check call status
#   ./scripts/call.sh end <call_id>      # End an active call
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SKILL_DIR/skill-config.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}Error:${NC} $1" >&2; exit 1; }
info() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }

# Load config
[[ -f "$CONFIG_FILE" ]] || error "Config not found. Run ./setup.sh first."

# Resolve env vars in config
resolve_config() {
  local config
  config=$(cat "$CONFIG_FILE")
  
  # Find .env files
  local env_files=(
    "$HOME/.openclaw/.env"
    "$HOME/.clawdbot/.env"
    "$SKILL_DIR/.env"
  )
  
  for env_file in "${env_files[@]}"; do
    if [[ -f "$env_file" ]]; then
      while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        value="${value%\"}"
        value="${value#\"}"
        config="${config//\$\{$key\}/$value}"
      done < "$env_file"
    fi
  done
  
  echo "$config"
}

CONFIG=$(resolve_config)
API_KEY=$(echo "$CONFIG" | jq -r '.api_key // empty')
SERVER=$(echo "$CONFIG" | jq -r '.server // "https://clawdtalk.com"')

[[ -n "$API_KEY" ]] || error "API key not configured. Run ./setup.sh"

# API helper
api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  
  local args=(-s -X "$method" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(-d "$data")
  
  curl "${args[@]}" "${SERVER}${endpoint}"
}

# Commands
cmd_call() {
  local greeting="${1:-}"
  local payload='{}'
  
  if [[ -n "$greeting" ]]; then
    payload=$(jq -n --arg g "$greeting" '{greeting: $g}')
  fi
  
  info "Initiating outbound call..."
  local result
  result=$(api POST "/v1/calls" "$payload")
  
  local status
  status=$(echo "$result" | jq -r '.status // .error.code // "unknown"')
  
  if [[ "$status" == "initiating" || "$status" == "ringing" ]]; then
    local call_id
    call_id=$(echo "$result" | jq -r '.call_id')
    info "Call initiated: $call_id"
    echo "$result" | jq .
  else
    error "Failed to initiate call: $(echo "$result" | jq -r '.error.message // .message // "Unknown error"')"
  fi
}

cmd_status() {
  local call_id="$1"
  [[ -n "$call_id" ]] || error "Usage: $0 status <call_id>"
  
  api GET "/v1/calls/$call_id" | jq .
}

cmd_end() {
  local call_id="$1"
  local reason="${2:-user_ended}"
  [[ -n "$call_id" ]] || error "Usage: $0 end <call_id> [reason]"
  
  local payload
  payload=$(jq -n --arg r "$reason" '{reason: $r}')
  
  info "Ending call $call_id..."
  api POST "/v1/calls/$call_id/end" "$payload" | jq .
}

cmd_help() {
  cat <<EOF
ClawdTalk Outbound Call

Usage:
  $0                      Initiate call with default greeting
  $0 "Hello!"             Initiate call with custom greeting
  $0 status <call_id>     Check call status
  $0 end <call_id>        End an active call

The call will be placed to your verified phone number.
Your bot will answer and you can have a voice conversation.
EOF
}

# Main
case "${1:-}" in
  status)
    cmd_status "${2:-}"
    ;;
  end)
    cmd_end "${2:-}" "${3:-}"
    ;;
  help|--help|-h)
    cmd_help
    ;;
  *)
    cmd_call "${1:-}"
    ;;
esac
