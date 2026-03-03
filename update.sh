#!/bin/bash
#
# ClawdTalk Client Update Script
# Downloads and installs the latest version from GitHub
#
# Endpoints: https://api.github.com, https://github.com
# Reads: package.json
# Writes: skill files (overwrites on update)

set -e

REPO_URL="https://github.com/team-telnyx/clawdtalk-client"
API_URL="https://api.github.com/repos/team-telnyx/clawdtalk-client"
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

# Check latest version from GitHub releases
echo "Checking for updates..."
RELEASE_JSON=$(curl -s "${API_URL}/releases/latest")
LATEST_TAG=$(jq -r '.tag_name // ""' <<<"$RELEASE_JSON" 2>/dev/null || true)
LATEST_VERSION="${LATEST_TAG#v}"

if [ -z "$LATEST_TAG" ] || [ -z "$LATEST_VERSION" ]; then
  echo -e "${RED}Error: Could not fetch latest release from GitHub${NC}"
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
ARCHIVE_NAME="clawdtalk-client-${LATEST_VERSION}.zip"
ARCHIVE_ZIP="${TEMP_DIR}/${ARCHIVE_NAME}"
CHECKSUM_FILE="${TEMP_DIR}/clawdtalk-client-${LATEST_VERSION}.sha256"

ZIP_INFO=$(jq -r '
  def valid_asset: (.name != null and .browser_download_url != null);
  def is_zip: (.name | endswith(".zip")) and (.name | endswith(".sha256") | not) and (.name | endswith(".sha256sum") | not);
  def pick_preferred($items):
    ($items | map(select(.name | ascii_downcase | contains("clawdtalk")))) as $preferred
    | if ($preferred | length) > 0 then $preferred[-1] else ($items[0] // null) end;
  (.assets // []) | map(select(valid_asset and is_zip)) as $zips
  | (pick_preferred($zips)) as $zip
  | if $zip == null then "" else "\($zip.browser_download_url)|\($zip.name)" end
' <<<"$RELEASE_JSON" 2>/dev/null || true)
ZIP_URL="${ZIP_INFO%%|*}"
if [ "$ZIP_INFO" != "$ZIP_URL" ]; then
  ARCHIVE_NAME="${ZIP_INFO#*|}"
  ARCHIVE_ZIP="${TEMP_DIR}/${ARCHIVE_NAME}"
fi
CHECKSUM_URL=$(jq -r '
  def valid_asset: (.name != null and .browser_download_url != null);
  def is_sha: (.name | endswith(".sha256")) or (.name | endswith(".sha256sum")) or (.name | ascii_upcase == "SHA256SUMS");
  def pick_preferred($items):
    ($items | map(select(.name | ascii_downcase | contains("clawdtalk")))) as $preferred
    | if ($preferred | length) > 0 then $preferred[-1] else ($items[0] // null) end;
  (.assets // []) | map(select(valid_asset and is_sha)) as $shas
  | (pick_preferred($shas)) as $sha
  | if $sha == null then "" else $sha.browser_download_url end
' <<<"$RELEASE_JSON" 2>/dev/null || true)

if [ -z "$ZIP_URL" ]; then
  echo -e "${RED}Error: No release zip asset found.${NC}"
  echo "Publish a release zip with a checksum asset."
  rm -rf "$TEMP_DIR"
  exit 1
fi

curl -sL "$ZIP_URL" -o "$ARCHIVE_ZIP"

if [ ! -f "$ARCHIVE_ZIP" ] || [ ! -s "$ARCHIVE_ZIP" ]; then
  echo -e "${RED}Error: Download failed${NC}"
  rm -rf "$TEMP_DIR"
  exit 1
fi

EXPECTED_SHA=""
if [ -n "${CHECKSUM_URL:-}" ]; then
  curl -sL "$CHECKSUM_URL" -o "$CHECKSUM_FILE"
  if [ -s "$CHECKSUM_FILE" ]; then
    if grep -q "$(basename "$ARCHIVE_ZIP")" "$CHECKSUM_FILE"; then
      EXPECTED_SHA=$(grep "$(basename "$ARCHIVE_ZIP")" "$CHECKSUM_FILE" | head -1 | awk '{print $1}')
    else
      EXPECTED_SHA=$(head -1 "$CHECKSUM_FILE" | awk '{print $1}')
    fi
  fi
fi

if [ -z "$EXPECTED_SHA" ]; then
  echo -e "${RED}Error: Missing SHA256 checksum for the release archive.${NC}"
  rm -rf "$TEMP_DIR"
  exit 1
fi

if ! echo "$EXPECTED_SHA" | grep -Eq '^[a-fA-F0-9]{64}$'; then
  echo -e "${RED}Error: Invalid SHA256 checksum format.${NC}"
  rm -rf "$TEMP_DIR"
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA=$(shasum -a 256 "$ARCHIVE_ZIP" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA=$(sha256sum "$ARCHIVE_ZIP" | awk '{print $1}')
else
  echo -e "${RED}Error: sha256 tool not found (need shasum or sha256sum).${NC}"
  rm -rf "$TEMP_DIR"
  exit 1
fi

if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  echo -e "${RED}Error: SHA256 checksum mismatch. Aborting update.${NC}"
  rm -rf "$TEMP_DIR"
  exit 1
fi

# Extract and update
echo "Installing update..."
cd "$TEMP_DIR"
unzip -q "$ARCHIVE_ZIP"

# Copy new files (preserve skill-config.json)
if [ -d "clawdtalk-client" ]; then
  cp -r clawdtalk-client/* "$SKILL_DIR/" 2>/dev/null || true
else
  ARCHIVE_BASENAME=$(basename "$ARCHIVE_ZIP")
  CHECKSUM_BASENAME=$(basename "$CHECKSUM_FILE")
  shopt -s dotglob nullglob
  for item in *; do
    case "$item" in
      "$ARCHIVE_BASENAME"|"${CHECKSUM_BASENAME}")
        continue
        ;;
    esac
    cp -r "$item" "$SKILL_DIR/" 2>/dev/null || true
  done
  shopt -u dotglob nullglob
fi

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
