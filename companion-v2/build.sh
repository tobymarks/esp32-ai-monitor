#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SRC="Sources/main.swift"
BUILD_DIR="/tmp/aimonitor-build"
APP="$BUILD_DIR/AI Monitor.app"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Compiling AI Monitor v1.0.0..."

# Baue .app Bundle Struktur zuerst
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Kompiliere mit swiftc
swiftc "$SRC" \
  -framework Cocoa \
  -framework Security \
  -framework ServiceManagement \
  -target arm64-apple-macosx13.0 \
  -O \
  -o "$APP/Contents/MacOS/AIMonitor"

# Info.plist + Resources
cp Resources/Info.plist "$APP/Contents/"
cp Resources/MenuBarIconTemplate.png "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/MenuBarIconTemplate@2x.png "$APP/Contents/Resources/" 2>/dev/null || true

# Code-Sign (kein iCloud = keine xattr-Probleme)
codesign --force --deep --sign - "$APP"

# Kopiere zurück ins Projekt
rm -rf "$SCRIPT_DIR/build"
cp -R "$BUILD_DIR" "$SCRIPT_DIR/build"

echo "Build complete: $SCRIPT_DIR/build/AI Monitor.app"
