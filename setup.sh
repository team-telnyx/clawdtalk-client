#!/bin/bash
#
# ClawdTalk - Setup Script (v1.1)
#
# Interactive setup for voice calling integration.
# Asks for API key, auto-detects names, and configures gateway connection details and tools policy.
# Uses jq for all JSON manipulation (no python3 dependency).
#
# Usage: ./setup.sh
#
# Env vars: none directly
# Endpoints: none
# Reads: ~/.openclaw/openclaw.json, ~/.clawdbot/clawdbot.json, USER.md, IDENTITY.md
# Writes: skill-config.json, gateway config (tools policy only)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/skill-config.json"

echo ""
echo "📞 ClawdTalk Setup"
echo "==================="
echo ""
echo "This will configure gateway connection details and tools policy for Clawdbot/OpenClaw."
echo ""

# Check for required tools
echo "📋 Checking requirements..."
for tool in node jq; do
    if ! command -v "$tool" &> /dev/null; then
        echo "❌ Required tool '$tool' is not installed."
        exit 1
    fi
done
echo "   ✓ All required tools found"

# Check if already configured
if [ -f "$CONFIG_FILE" ]; then
    echo ""
    echo "⚠️  Configuration already exists!"
    echo ""
    echo "Current config: $CONFIG_FILE"
    echo ""
    read -p "Do you want to reconfigure? (y/N): " reconfigure
    if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Setup cancelled. Run './status.sh' to see current configuration."
        exit 0
    fi
    echo ""
fi

# Ask for API key
echo "🔑 API Key"
echo "==========="
echo ""
echo "You need an API key from ClawdTalk."
echo ""
echo "  1. Go to https://clawdtalk.com and sign in with Google"
echo "  2. Set up your phone number in Settings"
echo "  3. Generate an API key from the Dashboard"
echo ""
read -s -p "Enter your API key (or press Enter to skip for now): " api_key
echo ""

if [ -n "$api_key" ]; then
    echo "   ✓ API key saved"
else
    echo "   ⚠️  No API key entered — you can add it to skill-config.json later"
fi

# Auto-detect gateway config (support both clawdbot and openclaw)
echo ""
echo "🔧 Configuring gateway connection..."

GATEWAY_CONFIG=""
CLI_NAME=""

if [ -f "${HOME}/.clawdbot/clawdbot.json" ]; then
    GATEWAY_CONFIG="${HOME}/.clawdbot/clawdbot.json"
    CLI_NAME="clawdbot"
elif [ -f "${HOME}/.openclaw/openclaw.json" ]; then
    GATEWAY_CONFIG="${HOME}/.openclaw/openclaw.json"
    CLI_NAME="openclaw"
fi

# Auto-detect CLI name
if [ -z "$CLI_NAME" ]; then
    if command -v clawdbot &> /dev/null; then
        CLI_NAME="clawdbot"
    elif command -v openclaw &> /dev/null; then
        CLI_NAME="openclaw"
    else
        CLI_NAME="clawdbot"
    fi
fi

main_agent_workspace=""

if [ -n "$GATEWAY_CONFIG" ] && [ -f "$GATEWAY_CONFIG" ]; then
    # Read the main agent's workspace using jq
    main_agent_workspace=$(jq -r '(.agents.list[]? | select(.default == true or .id == "main") | .workspace) // .agents.defaults.workspace // "/home/node/clawd"' "$GATEWAY_CONFIG" 2>/dev/null || echo "/home/node/clawd")

    # Extract gateway connection details for skill-config.json (so ws-client doesn't need to read gateway config at runtime)
    gateway_port=$(jq -r '.gateway.port // 18789' "$GATEWAY_CONFIG" 2>/dev/null || echo "18789")
    gateway_token=$(jq -r '.gateway.auth.token // ""' "$GATEWAY_CONFIG" 2>/dev/null || echo "")
    gateway_url="http://127.0.0.1:${gateway_port}"
    main_agent_id=$(jq -r '(.agents.list[]? | select(.default == true) | .id) // (.agents.list[0]?.id) // "main"' "$GATEWAY_CONFIG" 2>/dev/null || echo "main")
else
    echo "   ⚠️  Gateway config not found — connection details will be blank"
    echo "   Checked: ~/.clawdbot/clawdbot.json and ~/.openclaw/openclaw.json"
fi

# Install Node dependencies
echo ""
echo "📦 Installing dependencies..."
if [ -f "$SCRIPT_DIR/package.json" ]; then
    (cd "$SCRIPT_DIR" && npm install --production 2>/dev/null) && echo "   ✓ Dependencies installed" || echo "   ⚠️  npm install failed — run 'npm install' manually in the skill directory"
else
    echo "   ⚠️  No package.json found"
fi

# Detect user and agent names
echo ""
echo "👤 Setting up names..."

WORKSPACE="${main_agent_workspace:-$HOME/.openclaw/workspace}"
owner_name=""
agent_name=""

# Offer to auto-detect from workspace files (opt-in to address security scanner flag)
auto_detect="y"
if [ -f "$WORKSPACE/USER.md" ] || [ -f "$WORKSPACE/IDENTITY.md" ]; then
    read -p "   Auto-detect names from workspace? (Y/n): " auto_detect
    auto_detect="${auto_detect:-y}"
fi

if [[ "$auto_detect" =~ ^[Yy]$ ]]; then
    # Try to get owner name from USER.md ("What to call them:" or "Name:")
    if [ -f "$WORKSPACE/USER.md" ]; then
        owner_name=$(grep -i "what to call them:" "$WORKSPACE/USER.md" 2>/dev/null | head -1 | sed 's/.*:\s*//' | tr -d '*' | sed 's/^ *//;s/ *$//')
        if [ -z "$owner_name" ]; then
            owner_name=$(grep -i "^- \*\*Name:" "$WORKSPACE/USER.md" 2>/dev/null | head -1 | sed 's/.*:\s*//' | tr -d '*' | sed 's/^ *//;s/ *$//')
            owner_name=$(echo "$owner_name" | awk '{print $1}')
        fi
    fi

    # Try to get agent name from IDENTITY.md
    if [ -f "$WORKSPACE/IDENTITY.md" ]; then
        agent_name=$(grep -i "^- \*\*Name:" "$WORKSPACE/IDENTITY.md" 2>/dev/null | head -1 | sed 's/.*:\s*//' | tr -d '*' | sed 's/^ *//;s/ *$//')
    fi
fi

# If auto-detect didn't find names (or was skipped), ask manually
if [ -z "$owner_name" ]; then
    read -p "   Your name (for greeting): " owner_name
fi
if [ -z "$agent_name" ]; then
    read -p "   Agent name (optional, press Enter to skip): " agent_name
fi

if [ -n "$owner_name" ]; then
    echo "   ✓ Owner name: $owner_name"
fi

if [ -n "$agent_name" ]; then
    echo "   ✓ Agent name: $agent_name"
fi

# Create skill-config.json
echo ""
echo "💾 Creating skill configuration..."

# Build values
if [ -n "$api_key" ]; then
    api_key_json="\"$api_key\""
else
    api_key_json="null"
fi

owner_name_json="null"
agent_name_json="null"
if [ -n "$owner_name" ]; then
    owner_name_json="\"$owner_name\""
fi
if [ -n "$agent_name" ]; then
    agent_name_json="\"$agent_name\""
fi

# Build greeting with name if available
if [ -n "$owner_name" ]; then
    greeting="Hey $owner_name, what's up?"
else
    greeting="Hey, what's up?"
fi

gateway_url_json="null"
gateway_token_json="null"
agent_id_json="null"
if [ -n "$gateway_url" ]; then
    gateway_url_json="\"$gateway_url\""
fi
if [ -n "$gateway_token" ]; then
    gateway_token_json="\"$gateway_token\""
fi
if [ -n "$main_agent_id" ]; then
    agent_id_json="\"$main_agent_id\""
fi

cat > "$CONFIG_FILE" << EOF
{
  "api_key": $api_key_json,
  "server": "https://clawdtalk.com",
  "owner_name": $owner_name_json,
  "agent_name": $agent_name_json,
  "greeting": "$greeting",
  "gateway_url": $gateway_url_json,
  "gateway_token": $gateway_token_json,
  "agent_id": $agent_id_json
}
EOF

echo "   ✓ Configuration saved to: $CONFIG_FILE"
echo "   ⚠️  Note: If you change your gateway token or port later, re-run setup.sh to update."

# Display next steps
echo ""
echo "🎉 Setup Complete!"
echo "=================="
echo ""

if [ -z "$api_key" ]; then
    echo "Next steps:"
    echo ""
    echo "1. Get your API key from https://clawdtalk.com"
    echo "   • Sign in with Google"
    echo "   • Set up your phone number in Settings"
    echo "   • Generate an API key from the Dashboard"
    echo ""
    echo "2. Add it to skill-config.json:"
    echo "   Set the api_key field"
    echo ""
    echo "3. Start the connection:"
    echo "   ./scripts/connect.sh start"
else
    echo "Next steps:"
    echo ""
    echo "1. Make sure your phone number is set up at https://clawdtalk.com → Settings"
    echo ""
    echo "2. Start the connection:"
    echo "   ./scripts/connect.sh start"
fi
echo ""

# Check gateway.tools.allow for sessions_send
echo ""
echo "🔐 Checking gateway tools policy..."
sessions_send_allowed=false
if [ -n "$GATEWAY_CONFIG" ] && [ -f "$GATEWAY_CONFIG" ]; then
    has_allow=$(jq -r '(.gateway.tools.allow // []) | map(select(. == "sessions_send")) | length > 0' "$GATEWAY_CONFIG" 2>/dev/null || echo "false")
    if [ "$has_allow" = "true" ]; then
        echo "   ✓ sessions_send is allowed on the Gateway HTTP tools API"
        sessions_send_allowed=true
    else
        echo ""
        echo "   ⚠️  sessions_send is NOT allowed on the Gateway HTTP tools API"
        echo ""
        echo "   Voice calls route requests to your main agent via sessions_send."
        echo "   OpenClaw blocks this tool over HTTP by default for security."
        echo "   Without it, voice calls connect but the AI can't process any requests —"
        echo "   it hears you, but can't act (all tool calls silently fail with 404)."
        echo ""
        read -p "   Add sessions_send to gateway.tools.allow? (Y/n): " add_allow
        if [[ ! "$add_allow" =~ ^[Nn]$ ]]; then
            tmp_config=$(mktemp)
            if jq '.gateway.tools.allow = ((.gateway.tools.allow // []) + ["sessions_send"] | unique)' "$GATEWAY_CONFIG" > "$tmp_config" 2>/dev/null; then
                mv "$tmp_config" "$GATEWAY_CONFIG"
                echo "   ✓ Added sessions_send to gateway.tools.allow"
                sessions_send_allowed=true
                echo "   ⚠️  Run '$CLI_NAME gateway restart' to apply changes"
            else
                rm -f "$tmp_config"
                echo "   ⚠️  Could not auto-configure — add it manually (see below)"
            fi
        else
            echo "   ⚠️  Skipped — voice call requests won't work until this is added"
        fi
    fi
fi

if [ "$sessions_send_allowed" != true ]; then
    echo ""
    echo "⚠️  Gateway tools policy: sessions_send must be allowed for voice calls."
    echo ""
    echo "   Voice calls work by routing your spoken requests to the main agent session"
    echo "   via the Gateway HTTP tools API (/tools/invoke → sessions_send). OpenClaw"
    echo "   blocks sessions_send over HTTP by default as a security measure. Without"
    echo "   this, the AI connects to your call but can't do anything — all requests"
    echo "   silently fail."
    echo ""
    config_path="~/.openclaw/openclaw.json"
    if [ "$CLI_NAME" = "clawdbot" ]; then
        config_path="~/.clawdbot/clawdbot.json"
    fi
    echo "   Add to $config_path:"
    echo '   { "gateway": { "tools": { "allow": ["sessions_send"] } } }'
    echo ""
    echo "   Or via CLI:"
    echo "   $CLI_NAME config patch '{\"gateway\":{\"tools\":{\"allow\":[\"sessions_send\"]}}}'"
fi

echo ""
echo "📋 Voice calls use your main agent's full context and memory."
echo "   All tools available to your agent work on voice calls too."
echo ""
echo "To check status: ./status.sh"
echo ""
