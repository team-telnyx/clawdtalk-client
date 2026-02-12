#!/usr/bin/env bash
# ClawdTalk Missions CLI — Create and manage AI missions via ClawdTalk API
# Usage: ./scripts/missions.sh <command> [args...]
#
# Commands:
#   create   — Create and run a mission (JSON body on stdin or as argument)
#   list     — List your missions
#   get <id> — Get mission details
#   events <id> — Get mission event timeline
#   cancel <id> — Cancel a running mission
#   status <id> — Poll and show current status

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# ── Load config ─────────────────────────────────────────────────

CONFIG_FILE="$SKILL_DIR/skill-config.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found. Run ./setup.sh first." >&2
  exit 1
fi

API_KEY=$(jq -r '.api_key // empty' "$CONFIG_FILE")
SERVER=$(jq -r '.server // "https://clawdtalk.com"' "$CONFIG_FILE")

if [[ -z "$API_KEY" || "$API_KEY" == "YOUR_API_KEY_HERE" ]]; then
  echo "ERROR: No API key configured. Set api_key in skill-config.json" >&2
  exit 1
fi

if [[ -z "$SERVER" ]]; then
  SERVER="https://clawdtalk.com"
fi

# ── HTTP helper ─────────────────────────────────────────────────

clawdtalk_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local args=(
    -s -w "\n%{http_code}"
    -H "Authorization: Bearer $API_KEY"
    -H "Content-Type: application/json"
    -X "$method"
  )

  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi

  local response
  response=$(curl "${args[@]}" "${SERVER}${path}")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body_text
  body_text=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 400 ]]; then
    echo "ERROR: HTTP $http_code" >&2
    echo "$body_text" | jq . 2>/dev/null || echo "$body_text" >&2
    exit 1
  fi

  echo "$body_text"
}

# ── Commands ────────────────────────────────────────────────────

cmd_create() {
  local body="${1:-}"

  # Read from stdin if no argument
  if [[ -z "$body" ]]; then
    body=$(cat)
  fi

  if [[ -z "$body" ]]; then
    cat >&2 <<'EOF'
Usage: ./scripts/missions.sh create '<json>'
       echo '<json>' | ./scripts/missions.sh create

Required JSON fields:
  name          — Mission name (e.g., "Find plumbers in Austin")
  instructions  — What the AI assistant should do on each call/SMS
  targets       — Array of {name, phone} objects

Optional fields:
  channel         — "voice" (default), "sms", or "both"
  assistant_config — {greeting, model} overrides
  schedule        — "now" (default), ISO datetime, or "business_hours"
  metadata        — Any extra data to attach

Example:
  ./scripts/missions.sh create '{
    "name": "Get plumber quotes",
    "instructions": "Call each plumber. Ask about hourly rates, availability this week, and whether they are licensed and insured. Be polite and professional.",
    "targets": [
      {"name": "ABC Plumbing", "phone": "+15125551234"},
      {"name": "Quick Fix Pipes", "phone": "+15125555678"}
    ],
    "channel": "voice"
  }'
EOF
    exit 1
  fi

  echo "Creating mission..." >&2
  local result
  result=$(clawdtalk_api POST /v1/missions "$body")
  echo "$result" | jq .

  local mission_id
  mission_id=$(echo "$result" | jq -r '.mission.id // empty')
  if [[ -n "$mission_id" ]]; then
    echo "" >&2
    echo "✅ Mission created: $mission_id" >&2
    echo "   View in portal: ${SERVER}/dashboard/missions/${mission_id}" >&2
    echo "   Check status:   ./scripts/missions.sh status $mission_id" >&2
  fi
}

cmd_list() {
  local result
  result=$(clawdtalk_api GET /v1/missions)

  local count
  count=$(echo "$result" | jq '.missions | length')

  if [[ "$count" == "0" ]]; then
    echo "No missions yet."
    return
  fi

  echo "$result" | jq -r '.missions[] | "\(.id)  \(.status | if . == "running" then "🔵" elif . == "succeeded" then "🟢" elif . == "failed" then "🔴" elif . == "cancelled" then "⚪" else "🟡" end) \(.status | ascii_upcase)  \(.channel)  \(.name)  [\(.events_used)/\(.target_count) events]"'
}

cmd_get() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    echo "Usage: ./scripts/missions.sh get <mission_id>" >&2
    exit 1
  fi

  clawdtalk_api GET "/v1/missions/$id" | jq .
}

cmd_events() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    echo "Usage: ./scripts/missions.sh events <mission_id>" >&2
    exit 1
  fi

  local result
  result=$(clawdtalk_api GET "/v1/missions/$id/events")

  echo "$result" | jq -r '.events[]? | "\(.type | ascii_upcase)  \(.target_name // "unknown") (\(.target_phone))  \(.status)  \(if .insight_summary then "→ " + .insight_summary else "" end)"'
}

cmd_cancel() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    echo "Usage: ./scripts/missions.sh cancel <mission_id>" >&2
    exit 1
  fi

  clawdtalk_api POST "/v1/missions/$id/cancel" | jq .
  echo "✅ Mission cancelled." >&2
}

cmd_status() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    echo "Usage: ./scripts/missions.sh status <mission_id>" >&2
    exit 1
  fi

  local result
  result=$(clawdtalk_api GET "/v1/missions/$id")

  local name status channel targets events
  name=$(echo "$result" | jq -r '.mission.name')
  status=$(echo "$result" | jq -r '.mission.status')
  channel=$(echo "$result" | jq -r '.mission.channel')
  targets=$(echo "$result" | jq -r '.mission.target_count')
  events=$(echo "$result" | jq -r '.mission.events_used')

  echo "Mission: $name"
  echo "Status:  $status"
  echo "Channel: $channel"
  echo "Targets: $targets ($events events used)"
  echo ""

  # Show events summary
  local event_list
  event_list=$(echo "$result" | jq -r '.mission.events[]? | "  \(if .status == "completed" then "✅" elif .status == "failed" then "❌" elif .status == "in_progress" then "🔵" elif .status == "scheduled" then "⏰" else "⏳" end) \(.target_name // .target_phone) — \(.status)\(if .insight_summary then "\n     💡 " + .insight_summary else "" end)"')

  if [[ -n "$event_list" ]]; then
    echo "Events:"
    echo "$event_list"
  fi
}

# ── Main ────────────────────────────────────────────────────────

CMD="${1:-help}"
shift || true

case "$CMD" in
  create)  cmd_create "$@" ;;
  list)    cmd_list ;;
  get)     cmd_get "$@" ;;
  events)  cmd_events "$@" ;;
  cancel)  cmd_cancel "$@" ;;
  status)  cmd_status "$@" ;;
  help|--help|-h)
    cat <<'EOF'
ClawdTalk Missions — AI-powered outreach via voice calls and SMS

Commands:
  create [json]    Create and run a mission (pipe JSON or pass as argument)
  list             List all your missions
  get <id>         Get full mission details
  events <id>      Show event timeline for a mission
  cancel <id>      Cancel a running mission
  status <id>      Show mission status summary

Examples:
  # Create a voice mission
  ./scripts/missions.sh create '{"name":"Get quotes","instructions":"Ask about rates and availability","targets":[{"name":"ABC Co","phone":"+15125551234"}],"channel":"voice"}'

  # List all missions
  ./scripts/missions.sh list

  # Check status
  ./scripts/missions.sh status 42
EOF
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    echo "Run: ./scripts/missions.sh help" >&2
    exit 1
    ;;
esac
