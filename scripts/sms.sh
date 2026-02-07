#!/bin/bash
#
# ClawdTalk SMS — Send and list SMS messages
#
# Usage:
#   sms.sh send +1234567890 "Hello, world!"
#   sms.sh send +1234567890 "Message" --media https://example.com/image.jpg
#   sms.sh list [--limit 20] [--contact +1234567890]
#   sms.sh conversations
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SKILL_DIR/skill-config.json"

# ─── Load config ────────────────────────────────────────────────────────────

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: skill-config.json not found. Run setup.sh first." >&2
  exit 1
fi

API_KEY=$(jq -r '.api_key // empty' "$CONFIG_FILE")
SERVER=$(jq -r '.server // "https://clawdtalk.com"' "$CONFIG_FILE")

if [[ -z "$API_KEY" || "$API_KEY" == "null" ]]; then
  echo "Error: No API key configured. Add api_key to skill-config.json" >&2
  exit 1
fi

# ─── Helper functions ───────────────────────────────────────────────────────

api_call() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  
  local url="${SERVER}${endpoint}"
  local args=(
    -s -S
    -X "$method"
    -H "Authorization: Bearer $API_KEY"
    -H "Content-Type: application/json"
  )
  
  if [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi
  
  curl "${args[@]}" "$url"
}

show_help() {
  cat << 'EOF'
ClawdTalk SMS — Send and receive text messages

USAGE:
  sms.sh send <to> <message> [--media <url>]
  sms.sh list [--limit N] [--contact +1xxx]
  sms.sh conversations

COMMANDS:
  send          Send an SMS/MMS message
  list          List message history
  conversations List conversation threads

EXAMPLES:
  # Send a text
  sms.sh send +13125551234 "Hey, what's up?"

  # Send with image (MMS)
  sms.sh send +13125551234 "Check this out" --media https://example.com/photo.jpg

  # List recent messages
  sms.sh list --limit 10

  # List messages with a specific contact
  sms.sh list --contact +13125551234

  # Get conversation threads
  sms.sh conversations
EOF
}

# ─── Commands ───────────────────────────────────────────────────────────────

cmd_send() {
  local to=""
  local message=""
  local media_urls=()
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --media)
        media_urls+=("$2")
        shift 2
        ;;
      *)
        if [[ -z "$to" ]]; then
          to="$1"
        elif [[ -z "$message" ]]; then
          message="$1"
        else
          message="$message $1"
        fi
        shift
        ;;
    esac
  done
  
  if [[ -z "$to" || -z "$message" ]]; then
    echo "Usage: sms.sh send <to> <message> [--media <url>]" >&2
    exit 1
  fi
  
  # Build JSON payload
  local payload
  if [[ ${#media_urls[@]} -gt 0 ]]; then
    local media_json
    media_json=$(printf '%s\n' "${media_urls[@]}" | jq -R . | jq -s .)
    payload=$(jq -n --arg to "$to" --arg msg "$message" --argjson media "$media_json" \
      '{to: $to, message: $msg, media_urls: $media}')
  else
    payload=$(jq -n --arg to "$to" --arg msg "$message" '{to: $to, message: $msg}')
  fi
  
  local response
  response=$(api_call POST "/v1/messages/send" "$payload")
  
  # Check for error
  if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    local err_msg
    err_msg=$(echo "$response" | jq -r '.error.message // .error')
    echo "Error: $err_msg" >&2
    exit 1
  fi
  
  # Success output
  local msg_id from_num
  msg_id=$(echo "$response" | jq -r '.id // "unknown"')
  from_num=$(echo "$response" | jq -r '.from // "unknown"')
  
  echo "✓ Message sent"
  echo "  ID: $msg_id"
  echo "  From: $from_num"
  echo "  To: $to"
}

cmd_list() {
  local limit=20
  local contact=""
  local direction=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)
        limit="$2"
        shift 2
        ;;
      --contact)
        contact="$2"
        shift 2
        ;;
      --direction)
        direction="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  
  local query="?limit=$limit"
  [[ -n "$contact" ]] && query="$query&contact=$contact"
  [[ -n "$direction" ]] && query="$query&direction=$direction"
  
  local response
  response=$(api_call GET "/v1/messages$query")
  
  if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    echo "Error: $(echo "$response" | jq -r '.error.message // .error')" >&2
    exit 1
  fi
  
  # Format output
  echo "$response" | jq -r '.messages[] | "\(.direction | if . == "inbound" then "←" else "→" end) \(.created_at | split("T")[0]) \(if .direction == "inbound" then .from else .to end): \(.body[:60])\(if (.body | length) > 60 then "..." else "" end)"'
  
  local total
  total=$(echo "$response" | jq -r '.pagination.total')
  echo ""
  echo "Total: $total messages"
}

cmd_conversations() {
  local response
  response=$(api_call GET "/v1/messages/conversations")
  
  if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    echo "Error: $(echo "$response" | jq -r '.error.message // .error')" >&2
    exit 1
  fi
  
  echo "$response" | jq -r '.conversations[] | "\(.contact): \(.last_message[:50])\(if (.last_message | length) > 50 then "..." else "" end)"'
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
  if [[ $# -eq 0 ]]; then
    show_help
    exit 0
  fi
  
  local cmd="$1"
  shift
  
  case "$cmd" in
    send)
      cmd_send "$@"
      ;;
    list)
      cmd_list "$@"
      ;;
    conversations)
      cmd_conversations "$@"
      ;;
    -h|--help|help)
      show_help
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      echo "Run 'sms.sh --help' for usage." >&2
      exit 1
      ;;
  esac
}

main "$@"
