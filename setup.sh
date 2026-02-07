#!/bin/bash
#
# ClawdTalk - Setup Script (v1.0)
#
# Interactive setup for voice calling integration.
# Asks for API key, model preference, and auto-configures the gateway.
# Uses jq for all JSON manipulation (no python3 dependency).
#
# Usage: ./setup.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/skill-config.json"

echo ""
echo "📞 ClawdTalk Setup"
echo "==================="
echo ""
echo "This will set up voice calling for your Clawdbot/OpenClaw instance."
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
echo "🔧 Configuring voice agent..."

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

voice_agent_added=false

if [ -n "$GATEWAY_CONFIG" ] && [ -f "$GATEWAY_CONFIG" ]; then
    # Check if voice agent already exists (using jq)
    has_voice=$(jq -r '[.agents.list[]? | select(.id == "voice")] | length > 0' "$GATEWAY_CONFIG" 2>/dev/null || echo "false")

    if [ "$has_voice" = "true" ]; then
        echo "   ✓ Voice agent already configured in gateway"
        voice_agent_added=true
    else
        # Read the main agent's name and workspace using jq
        main_agent_name=$(jq -r '(.agents.list[]? | select(.default == true or .id == "main") | .name) // "Assistant"' "$GATEWAY_CONFIG" 2>/dev/null || echo "Assistant")
        main_agent_workspace=$(jq -r '(.agents.list[]? | select(.default == true or .id == "main") | .workspace) // .agents.defaults.workspace // "/home/node/clawd"' "$GATEWAY_CONFIG" 2>/dev/null || echo "/home/node/clawd")

        # Build the voice agent object (no systemPrompt — injected by ws-client via messages)
        # Keeping it minimal for compatibility with both Clawdbot and OpenClaw
        voice_agent=$(jq -n \
            --arg name "${main_agent_name} Voice" \
            --arg workspace "$main_agent_workspace" \
            '{
                id: "voice",
                name: $name,
                workspace: $workspace
            }')

        # Add voice agent to agents.list and enable chatCompletions endpoint
        # Use a temp file for atomic write
        tmp_config=$(mktemp)
        if jq --argjson agent "$voice_agent" '
            .agents.list = (.agents.list // []) + [$agent] |
            .gateway.http.endpoints.chatCompletions.enabled = true
        ' "$GATEWAY_CONFIG" > "$tmp_config" 2>/dev/null; then
            mv "$tmp_config" "$GATEWAY_CONFIG"
            echo "   ✓ Added '${main_agent_name} Voice' agent to gateway config"
            echo "   ✓ Enabled /v1/chat/completions endpoint"
            voice_agent_added=true

            # Restart gateway to pick up new agent
            if command -v "$CLI_NAME" &> /dev/null; then
                echo "   ↻ Restarting gateway to apply changes..."
                $CLI_NAME gateway restart 2>/dev/null && echo "   ✓ Gateway restarted" || echo "   ⚠️  Restart failed — run '$CLI_NAME gateway restart' manually"
            else
                echo "   ⚠️  Run '$CLI_NAME gateway restart' to apply the new agent config"
            fi
        else
            rm -f "$tmp_config"
            echo "   ⚠️  Could not auto-configure — see manual steps below"
        fi
    fi
else
    echo "   ⚠️  Gateway config not found — see manual steps below"
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

# Create skill-config.json
echo ""
echo "💾 Creating skill configuration..."

# Build the API key value
if [ -n "$api_key" ]; then
    api_key_json="\"$api_key\""
else
    api_key_json="null"
fi

cat > "$CONFIG_FILE" << EOF
{
  "api_key": $api_key_json,
  "server": "https://clawdtalk.com"
}
EOF

echo "   ✓ Configuration saved to: $CONFIG_FILE"

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

if [ "$voice_agent_added" = true ]; then
    echo "✅ Voice agent is configured and ready."
else
    echo "⚠️  Voice agent not auto-configured. Add it manually:"
    echo ""
    config_path="~/.clawdbot/clawdbot.json"
    if [ "$CLI_NAME" = "openclaw" ]; then
        config_path="~/.openclaw/openclaw.json"
    fi
    echo "   Edit $config_path and add to agents.list[]:"
    echo '   { "id": "voice", "name": "Voice", "systemPrompt": "You are a voice assistant. Keep responses short." }'
    echo ""
    echo "   Also ensure chatCompletions is enabled:"
    echo '   "gateway": { "http": { "endpoints": { "chatCompletions": { "enabled": true } } } }'
    echo ""
    echo "   Then restart: $CLI_NAME gateway restart"
fi

echo ""
echo "📋 Tools: The voice agent uses the same tools as your gateway agent."
echo "   Add skills to the voice agent's workspace to give it capabilities."
echo ""
echo "To check status: ./status.sh"
echo ""
