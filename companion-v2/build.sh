#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="/tmp/aimonitor-build"
APP="$BUILD_DIR/AI Monitor.app"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

APP_VERSION="1.16.1"

# Developer ID Signing (ab v1.13.0) — optional. Wenn die Identity nicht im
# Keychain ist (z.B. CI-Runner ohne Cert-Import), fallen wir auf Ad-hoc-Sign
# zurück, damit der lokale Build weiter funktioniert. Notarization/Stapling
# werden nur dann ausgeführt, wenn SIGN_IDENTITY gesetzt ist UND die Env-Var
# NOTARIZE=1 (oder das Keychain-Profil $NOTARY_PROFILE verfügbar) aktiv ist.
SIGN_IDENTITY_DEFAULT="Developer ID Application: Tobias Marks (7V4K87652E)"
SIGN_IDENTITY="${SIGN_IDENTITY:-$SIGN_IDENTITY_DEFAULT}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
ENTITLEMENTS_FILE="$SCRIPT_DIR/Resources/AIMonitor.entitlements"

# Prüfe, ob die Developer-ID-Identity im Keychain ist.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  HAS_DEVELOPER_ID=1
  echo "Developer ID available: $SIGN_IDENTITY"
else
  HAS_DEVELOPER_ID=0
  echo "Developer ID NOT found — falling back to ad-hoc signing (no notarization)."
fi

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
# bleiben aber im Repo für den Fall, dass wir die Entscheidung revidieren.
cp Resources/MenuBarIconTemplate.png "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/MenuBarIconTemplate@2x.png "$APP/Contents/Resources/" 2>/dev/null || true

# Bundle esptool from PlatformIO (full package with dependencies)
ESPTOOL_DIR="$HOME/.platformio/packages/tool-esptoolpy"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
if [ -d "$ESPTOOL_DIR" ]; then
  mkdir -p "$APP/Contents/Resources/esptool-pkg"
  cp "$ESPTOOL_DIR/esptool.py" "$APP/Contents/Resources/esptool-pkg/"
  cp -R "$ESPTOOL_DIR/esptool" "$APP/Contents/Resources/esptool-pkg/"
  cp -R "$ESPTOOL_DIR/_contrib" "$APP/Contents/Resources/esptool-pkg/" 2>/dev/null || true
  if [ -n "$PYTHON_BIN" ]; then
    "$PYTHON_BIN" -m pip install --disable-pip-version-check --no-compile --upgrade \
      --target "$APP/Contents/Resources/esptool-pkg" \
      "bitstring>=3.1.6,!=4.2.0" \
      "cryptography>=2.1.4" \
      "ecdsa>=0.16.0" \
      "pyserial>=3.3" \
      "reedsolo>=1.5.3,<1.8" \
      "PyYAML>=5.1" \
      "intelhex" \
      "argcomplete>=3"
    if "$PYTHON_BIN" "$APP/Contents/Resources/esptool-pkg/esptool.py" version >/dev/null 2>&1; then
      echo "Bundled esptool package from PlatformIO (dependencies verified)"
    else
      echo "ERROR: Bundled esptool verification failed"
      exit 1
    fi
  else
    echo "WARNING: python3 not found, cannot vendor esptool dependencies"
  fi
else
  echo "WARNING: PlatformIO esptool not found at $ESPTOOL_DIR"
  echo "  Firmware flashing will use system-installed esptool (pip3 install esptool)"
fi

# =============================================================================
# Code-Signing
# =============================================================================
if [ "$HAS_DEVELOPER_ID" = "1" ]; then
  echo "Signing with Developer ID (Hardened Runtime + Timestamp)..."

  # Inside-Out-Signing: Zuerst alle eingebetteten Mach-O-Binaries (.so/.dylib)
  # im esptool-pkg/-Tree signieren, dann erst die .app selbst. --deep ist
  # deprecated für Distribution — wir machen es manuell.
  # Die Python-Extension-Binaries werden vom Python-Subprozess geladen (nicht
  # vom App-Prozess selbst), aber für Notarization müssen ALLE Mach-O-Dateien
  # im Bundle mit unserer Developer ID + Hardened Runtime + Timestamp signiert
  # sein.
  if [ -d "$APP/Contents/Resources/esptool-pkg" ]; then
    find "$APP/Contents/Resources/esptool-pkg" -type f \( -name "*.so" -o -name "*.dylib" \) -print0 | \
      while IFS= read -r -d '' lib; do
        codesign --force --timestamp --options runtime \
          --sign "$SIGN_IDENTITY" "$lib"
      done
    echo "Signed embedded Python extensions in esptool-pkg/"
  fi

  # Main app binary + Bundle. Mit --options runtime = Hardened Runtime.
  # Wenn Entitlements-Datei existiert, wird sie referenziert (aktuell NICHT
  # nötig — USB-Serial via open() auf /dev/cu.*, CodexBar liest aus User
  # Library, esptool läuft als separater Python-Prozess mit eigener Signatur).
  if [ -f "$ENTITLEMENTS_FILE" ]; then
    codesign --force --timestamp --options runtime \
      --entitlements "$ENTITLEMENTS_FILE" \
      --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/AIMonitor"
    codesign --force --timestamp --options runtime \
      --entitlements "$ENTITLEMENTS_FILE" \
      --sign "$SIGN_IDENTITY" "$APP"
  else
    codesign --force --timestamp --options runtime \
      --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/AIMonitor"
    codesign --force --timestamp --options runtime \
      --sign "$SIGN_IDENTITY" "$APP"
  fi

  # Sanity-Check
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "Developer ID signing complete."
else
  # Ad-hoc-Fallback (CI ohne Cert, lokal ohne Apple-Dev-Account)
  codesign --force --deep --sign - "$APP"
fi

# Kopiere zurück ins Projekt
rm -rf "$SCRIPT_DIR/build"
cp -R "$BUILD_DIR" "$SCRIPT_DIR/build"

# =============================================================================
# DMG-Build + Signing
# =============================================================================
# DMG aus dem (evtl. gestapelten) App-Bundle erzeugen. Reihenfolge:
#   1. DMG bauen
#   2. DMG signieren (Developer ID)
#   3. DMG bei Apple zur Notarization einreichen
#   4. Ticket an DMG stapeln
#   5. App einzeln stapeln (damit die ZIP-Version das Ticket enthält)
#   6. ZIP aus gestapelter .app erzeugen (ditto)
DMG_PATH="$SCRIPT_DIR/build/AIMonitor.dmg"
rm -f "$DMG_PATH"
DMG_STAGING="$(mktemp -d)"
cp -R "$SCRIPT_DIR/build/AI Monitor.app" "$DMG_STAGING/"
ln -sf /Applications "$DMG_STAGING/Applications"

if hdiutil create -volname "AI Monitor" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null 2>&1; then
  echo "Built DMG: $DMG_PATH"
else
  echo "WARNING: hdiutil DMG build failed — skipping notarization."
  DMG_PATH=""
fi
rm -rf "$DMG_STAGING"

# =============================================================================
# Notarization + Stapling (nur mit Developer ID + NOTARIZE=1)
# =============================================================================
NOTARIZE="${NOTARIZE:-0}"
if [ "$HAS_DEVELOPER_ID" = "1" ] && [ "$NOTARIZE" = "1" ] && [ -n "$DMG_PATH" ]; then
  echo "Signing DMG with Developer ID..."
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

  echo "Submitting DMG to Apple notarization (keychain-profile=$NOTARY_PROFILE)..."
  echo "  This typically takes 1-5 minutes."
  if xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait; then
    echo "Notarization ACCEPTED."

    echo "Stapling ticket to DMG and App..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler staple "$SCRIPT_DIR/build/AI Monitor.app"
    xcrun stapler validate "$SCRIPT_DIR/build/AI Monitor.app"
    xcrun stapler validate "$DMG_PATH"
    echo "Stapling complete."
  else
    echo "ERROR: Notarization failed. Run:"
    echo "  xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
    echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    exit 1
  fi
else
  if [ "$HAS_DEVELOPER_ID" = "1" ]; then
    echo "Skipping notarization (NOTARIZE=1 not set). DMG is signed but not notarized."
  fi
fi

# =============================================================================
# ZIP aus (gestapelter) .app erzeugen. ditto erhält die Signatur und
# Extended Attributes korrekt — besser als zip(1) für signierte Bundles.
# =============================================================================
cd "$SCRIPT_DIR/build"
rm -f AIMonitor.zip
ditto -c -k --keepParent "AI Monitor.app" AIMonitor.zip
echo "Release ZIP: $SCRIPT_DIR/build/AIMonitor.zip"

# =============================================================================
# Verifikation (nur bei Developer-ID-Build)
# =============================================================================
if [ "$HAS_DEVELOPER_ID" = "1" ] && [ "$NOTARIZE" = "1" ]; then
  echo ""
  echo "=== Gatekeeper-Verifikation ==="
  spctl -a -vvv -t install "$DMG_PATH" 2>&1 || true
  spctl -a -vvv -t execute "$SCRIPT_DIR/build/AI Monitor.app" 2>&1 || true
  xcrun stapler validate "$SCRIPT_DIR/build/AI Monitor.app" 2>&1 || true
  xcrun stapler validate "$DMG_PATH" 2>&1 || true
fi

echo ""
echo "Build complete: $SCRIPT_DIR/build/AI Monitor.app"
echo ""
echo "=== Release Workflow ==="
echo "1. Update kAppVersion in Sources/main.swift"
echo "2. Update CFBundleVersion + CFBundleShortVersionString in Resources/Info.plist"
echo "3. Update APP_VERSION in build.sh (this file)"
echo "4. Run: NOTARIZE=1 ./build.sh  (signed + notarized + stapled)"
echo "   oder: ./build.sh             (ad-hoc-signed, lokal testen)"
echo "5. Create GitHub Release with tag 'app-vX.Y.Z'"
echo "6. Upload build/AIMonitor.zip AND build/AIMonitor.dmg as release assets"
