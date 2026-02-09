#!/bin/bash
#
# ClawdTalk Client Update Script
# Downloads and installs the latest version from GitHub
#

set -e

REPO_URL="https://github.com/team-telnyx/clawdtalk-client"
RAW_URL="https://raw.githubusercontent.com/team-telnyx/clawdtalk-client/main"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="${SKILL_DIR}/.backup"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}ClawdTalk Client Updater${NC}"
echo "========================="
echo

# Get current version
CURRENT_VERSION=$(grep '"version"' "$SKILL_DIR/package.json" 2>/dev/null | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')
echo "Current version: ${CURRENT_VERSION:-unknown}"

# Check latest version from GitHub
echo "Checking for updates..."
LATEST_VERSION=$(curl -s "${RAW_URL}/package.json" | grep '"version"' | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

if [ -z "$LATEST_VERSION" ]; then
  echo -e "${RED}Error: Could not fetch latest version from GitHub${NC}"
  exit 1
fi

echo "Latest version:  ${LATEST_VERSION}"
echo

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
  echo -e "${GREEN}✓ Already up to date!${NC}"
  exit 0
fi

echo -e "${YELLOW}Update available: ${CURRENT_VERSION} → ${LATEST_VERSION}${NC}"
echo

# Confirm update
read -p "Do you want to update? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Update cancelled."
  exit 0
fi

# Stop the client if running
echo "Stopping ClawdTalk client..."
"$SKILL_DIR/scripts/connect.sh" stop 2>/dev/null || true

# Backup current installation
echo "Backing up current installation..."
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/backup-${CURRENT_VERSION:-old}-$(date +%Y%m%d%H%M%S).tar.gz"
tar -czf "$BACKUP_FILE" -C "$SKILL_DIR" \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='.backup' \
  --exclude='skill-config.json' \
  . 2>/dev/null || true
echo "Backup saved to: $BACKUP_FILE"

# Download latest
echo "Downloading latest version..."
TEMP_DIR=$(mktemp -d)
curl -sL "${RAW_URL}/dist/clawdtalk-client-latest.zip" -o "${TEMP_DIR}/latest.zip"

if [ ! -f "${TEMP_DIR}/latest.zip" ] || [ ! -s "${TEMP_DIR}/latest.zip" ]; then
  echo -e "${RED}Error: Download failed${NC}"
  rm -rf "$TEMP_DIR"
  exit 1
fi

# Extract and update
echo "Installing update..."
cd "$TEMP_DIR"
unzip -q latest.zip

# Copy new files (preserve skill-config.json)
cp -r clawdtalk-client/* "$SKILL_DIR/" 2>/dev/null || true

# Restore config if it was overwritten
if [ -f "$SKILL_DIR/skill-config.json.bak" ]; then
  mv "$SKILL_DIR/skill-config.json.bak" "$SKILL_DIR/skill-config.json"
fi

# Cleanup
rm -rf "$TEMP_DIR"

# Install dependencies if needed
if [ -f "$SKILL_DIR/package.json" ]; then
  echo "Installing dependencies..."
  cd "$SKILL_DIR"
  npm install --production 2>/dev/null || true
fi

# Make scripts executable
chmod +x "$SKILL_DIR"/*.sh "$SKILL_DIR/scripts"/*.sh 2>/dev/null || true

echo
echo -e "${GREEN}✓ Updated to version ${LATEST_VERSION}!${NC}"
echo
echo "To start the client:"
echo "  ./scripts/connect.sh start"
echo
echo "To restore previous version:"
echo "  tar -xzf $BACKUP_FILE -C $SKILL_DIR"
