#!/bin/bash
# deploy.sh — rebuild ClaudeUsage and reinstall to /Applications
#
# Usage: ./deploy.sh
# Run this from Terminal whenever you make changes to the Swift source files.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ClaudeUsage"
BUILD_DIR="/tmp/claudeusage-release"
INSTALL_PATH="/Applications/${APP_NAME}.app"

echo "▶ Building ${APP_NAME}..."
xcodebuild \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    -quiet \
    build

echo "▶ Stopping running instance..."
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5

echo "▶ Installing to ${INSTALL_PATH}..."
rm -rf "${INSTALL_PATH}"
cp -R "${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app" "${INSTALL_PATH}"

echo "▶ Launching..."
open "${INSTALL_PATH}"

echo "✅ Done — ${APP_NAME} updated and running."
