#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SRC="Sources/main.swift"
BUILD_DIR="/tmp/aimonitor-build"
APP="$BUILD_DIR/AI Monitor.app"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Compiling AI Monitor v1.4.1..."

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
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true

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

# Kopiere zurück ins Projekt
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
echo "3. Run: ./build.sh"
echo "4. Create GitHub Release with tag 'app-vX.Y.Z'"
echo "5. Upload build/AIMonitor.zip as release asset"
echo "6. Update installer/appcast.xml (for future Sparkle migration)"
echo ""
echo "=== Sparkle Migration (spaeter) ==="
echo "# Sparkle Framework herunterladen:"
echo "#   curl -L -o Sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.7.5/Sparkle-2.7.5.tar.xz"
echo "#   tar xf Sparkle.tar.xz"
echo "# EdDSA Keys generieren:"
echo "#   ./Sparkle.framework/Resources/bin/generate_keys"
echo "#   -> Private key wird in Keychain gespeichert"
echo "#   -> Public key in Info.plist als SUPublicEDKey eintragen"
echo "# Release signieren:"
echo "#   ./Sparkle.framework/Resources/bin/sign_update build/AIMonitor.zip"
echo "#   -> Signatur in installer/appcast.xml eintragen"
