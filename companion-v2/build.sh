#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="/tmp/aimonitor-build"
APP="$BUILD_DIR/AI Monitor.app"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

APP_VERSION="1.8.0"
echo "Compiling AI Monitor v${APP_VERSION}..."

# Baue .app Bundle Struktur zuerst
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Kompiliere mit swiftc — mehrere Swift-Dateien
swiftc \
  Sources/main.swift \
  Sources/CodexBarSource.swift \
  Sources/SettingsWindow.swift \
  -framework Cocoa \
  -framework Security \
  -framework ServiceManagement \
  -target arm64-apple-macosx13.0 \
  -O \
  -o "$APP/Contents/MacOS/AIMonitor"

# Info.plist + Resources
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
# Menubar-Icons werden ab v1.8.0 nicht mehr verwendet (LSUIElement unsichtbar),
# bleiben aber im Repo fuer den Fall, dass wir die Entscheidung revidieren.
cp Resources/MenuBarIconTemplate.png "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/MenuBarIconTemplate@2x.png "$APP/Contents/Resources/" 2>/dev/null || true

# Bundle esptool from PlatformIO (full package with dependencies)
ESPTOOL_DIR="$HOME/.platformio/packages/tool-esptoolpy"
if [ -d "$ESPTOOL_DIR" ]; then
  mkdir -p "$APP/Contents/Resources/esptool-pkg"
  cp "$ESPTOOL_DIR/esptool.py" "$APP/Contents/Resources/esptool-pkg/"
  cp -R "$ESPTOOL_DIR/esptool" "$APP/Contents/Resources/esptool-pkg/"
  cp -R "$ESPTOOL_DIR/_contrib" "$APP/Contents/Resources/esptool-pkg/" 2>/dev/null || true
  echo "Bundled esptool package from PlatformIO"
else
  echo "WARNING: PlatformIO esptool not found at $ESPTOOL_DIR"
  echo "  Firmware flashing will use system-installed esptool (pip3 install esptool)"
fi

# Code-Sign (kein iCloud = keine xattr-Probleme)
codesign --force --deep --sign - "$APP"

# Kopiere zurueck ins Projekt
rm -rf "$SCRIPT_DIR/build"
cp -R "$BUILD_DIR" "$SCRIPT_DIR/build"

# Create release ZIP for app auto-update distribution
cd "$SCRIPT_DIR/build"
zip -r -q "AIMonitor.zip" "AI Monitor.app"
echo "Release ZIP: $SCRIPT_DIR/build/AIMonitor.zip"

echo "Build complete: $SCRIPT_DIR/build/AI Monitor.app"
echo ""
echo "=== Release Workflow ==="
echo "1. Update kAppVersion in Sources/main.swift"
echo "2. Update CFBundleVersion + CFBundleShortVersionString in Resources/Info.plist"
echo "3. Update APP_VERSION in build.sh (this file)"
echo "4. Run: ./build.sh"
echo "5. Create GitHub Release with tag 'app-vX.Y.Z'"
echo "6. Upload build/AIMonitor.zip as release asset"
