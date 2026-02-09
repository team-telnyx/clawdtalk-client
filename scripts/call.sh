#!/usr/bin/env bash
#
# ClawdTalk Outbound Call Script
# Initiates an outbound call to user's phone or an external number
#
# Usage:
#   ./scripts/call.sh                                        # Call your phone
#   ./scripts/call.sh "Hey, what's up?"                      # Call with greeting
#   ./scripts/call.sh --to +15551234567                      # Call external (paid only)
#   ./scripts/call.sh --to +1555... --purpose "Schedule meeting"  # External with purpose
#   ./scripts/call.sh status <call_id>                       # Check call status
#   ./scripts/call.sh end <call_id>                          # End an active call
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
  local greeting=""
  local to_number=""
  local purpose=""
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        to_number="$2"
        shift 2
        ;;
      --purpose|--context)
        purpose="$2"
        shift 2
        ;;
      -*)
        error "Unknown option: $1"
        ;;
      *)
        greeting="$1"
        shift
        ;;
    esac
  done
  
  # Build payload
  local payload='{}'
  
  # Smart detection: if greeting looks like a phone number and no --to provided, treat it as --to
  if [[ -z "$to_number" && -n "$greeting" && "$greeting" =~ ^\+?[0-9]{10,15}$ ]]; then
    warn "Detected phone number in greeting, treating as --to target"
    to_number="$greeting"
    greeting=""
  fi
  
  # Start with base object
  if [[ -n "$to_number" ]]; then
    payload=$(jq -n --arg t "$to_number" '{to: $t}')
  fi
  
  # Add greeting if provided
  if [[ -n "$greeting" ]]; then
    payload=$(echo "$payload" | jq --arg g "$greeting" '. + {greeting: $g}')
  fi
  
  # Add context with purpose for external calls
  if [[ -n "$purpose" ]]; then
    payload=$(echo "$payload" | jq --arg p "$purpose" '. + {context: {purpose: $p}}')
  fi
  
  if [[ -n "$to_number" ]]; then
    info "Initiating outbound call to $to_number..."
  else
    info "Initiating outbound call to your phone..."
  fi
  
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
  $0                                           Call your own phone (default)
  $0 "Hello!"                                  Call with custom greeting
  $0 --to +15551234567                         Call an external number (paid only)
  $0 --to +1555... --purpose "Schedule mtg"   Call external with purpose
  $0 --to +1555... "Hi!" --purpose "..."      External + greeting + purpose
  $0 status <call_id>                          Check call status
  $0 end <call_id>                             End an active call

Options:
  --to <number>      Call external number instead of your own
  --purpose <text>   Tell the AI why you're calling (critical for external calls)

Without --to: calls your verified phone number.
With --to: calls the specified number (requires paid account with dedicated number).
The --purpose flag tells the AI what the call is about so it knows what to do.
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
    cmd_call "$@"
    ;;
esac
