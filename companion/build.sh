#!/bin/bash
# Build AI Monitor Companion macOS app
# Usage: ./build.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="AIMonitorCompanion"
BUNDLE="${APP_NAME}.app"
BUILD_DIR="build"

echo "Building ${APP_NAME}..."

# Clean
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/${BUNDLE}/Contents/MacOS"
mkdir -p "${BUILD_DIR}/${BUNDLE}/Contents/Resources"

# Copy Info.plist
cp Resources/Info.plist "${BUILD_DIR}/${BUNDLE}/Contents/"

# Compile
swiftc \
    -o "${BUILD_DIR}/${BUNDLE}/Contents/MacOS/${APP_NAME}" \
    -framework Cocoa \
    -framework Security \
    -target arm64-apple-macosx12.0 \
    -O \
    Sources/main.swift

echo "Build complete: ${BUILD_DIR}/${BUNDLE}"
echo ""
echo "Install:"
echo "  cp -r ${BUILD_DIR}/${BUNDLE} /Applications/"
echo "  open /Applications/${BUNDLE}"
echo ""
echo "Auto-start at login:"
echo "  osascript -e 'tell application \"System Events\" to make login item at end with properties {path:\"/Applications/${BUNDLE}\", hidden:true}'"
