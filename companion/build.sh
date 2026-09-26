#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="/tmp/aimonitor-build"
APP="$BUILD_DIR/AI Monitor.app"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

APP_VERSION="1.30.0"

# Developer ID Signing (ab v1.13.0) — optional. Wenn die Identity nicht im
# Keychain ist (z.B. CI-Runner ohne Cert-Import), fallen wir auf Ad-hoc-Sign
# zurück, damit der lokale Build weiter funktioniert. Notarization/Stapling
# werden nur dann ausgeführt, wenn SIGN_IDENTITY gesetzt ist UND die Env-Var
# NOTARIZE=1 (oder das Keychain-Profil $NOTARY_PROFILE verfügbar) aktiv ist.
SIGN_IDENTITY_DEFAULT="Developer ID Application: Tobias Marks (7V4K87652E)"
SIGN_IDENTITY="${SIGN_IDENTITY:-$SIGN_IDENTITY_DEFAULT}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"

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

# Universal Binary (ab v1.27.0): arm64 + x86_64.
#
# Intel wird bewusst weiter bedient — CodexBar, die Pflicht-Datenquelle, ist
# selbst universal und liefert eine x86_64-CLI. Ein Ausschluss waere allein
# ein Nebeneffekt des Build-Targets, kein technischer Zwang.
#
# MACOS_MIN richtet sich nach CodexBar (macOS 14+); tiefer brachte nichts,
# weil ohne CodexBar keine Daten kommen. Der Swift-Code selbst kompiliert
# auch gegen 13.0 — die frueheren 15.0 waren nicht durch APIs begruendet.
MACOS_MIN="14.0"
SWIFT_SOURCES=(
  Sources/main.swift
  Sources/CodexBarSource.swift
  Sources/StatusIndicator.swift
  Sources/NotificationBanner.swift
  Sources/Typography.swift
  Sources/Localization.swift
  Sources/SettingsWindow.swift
  Sources/SettingsWindow+Overview.swift
  Sources/SettingsWindow+Display.swift
  Sources/SettingsWindow+Views.swift
  Sources/SettingsWindow+Connection.swift
  Sources/SettingsWindow+Updates.swift
  Sources/SettingsWindow+Diagnostics.swift
)

SLICES=()
for ARCH in arm64 x86_64; do
  echo "Compiling slice: $ARCH (macOS $MACOS_MIN)"
  swiftc \
    "${SWIFT_SOURCES[@]}" \
    -framework Cocoa \
    -framework Security \
    -framework ServiceManagement \
    -target "$ARCH-apple-macosx$MACOS_MIN" \
    -O \
    -o "$BUILD_DIR/AIMonitor-$ARCH"
  SLICES+=("$BUILD_DIR/AIMonitor-$ARCH")
done

lipo -create -output "$APP/Contents/MacOS/AIMonitor" "${SLICES[@]}"
rm -f "${SLICES[@]}"

# Gegenprobe: beide Slices muessen drin sein, sonst waere der Universal-Build
# still zu einem Single-Arch-Build degradiert.
ARCHS_BUILT=$(lipo -archs "$APP/Contents/MacOS/AIMonitor")
echo "Universal binary: $ARCHS_BUILT"
for NEED in arm64 x86_64; do
  case " $ARCHS_BUILT " in
    *" $NEED "*) ;;
    *) echo "ERROR: slice $NEED fehlt im finalen Binary"; exit 1 ;;
  esac
done

# Info.plist + Resources
cp Resources/Info.plist "$APP/Contents/"

# -----------------------------------------------------------------------------
# App-Icon (ab v1.23.0)
# -----------------------------------------------------------------------------
# Resources/AppIcon.icon ist ein Icon-Composer-Dokument mit getrennten Ebenen.
# actool rendert daraus Assets.car (das geschichtete Icon, auf das macOS 26 die
# Liquid-Glass-Effekte anwendet) und ein AppIcon.icns als Fallback fuer aeltere
# Systeme. Die Quell-Ebenen liegen unter Resources/IconLayers/.
#
# Wichtig: das frueher hier kopierte, statische Resources/AppIcon.icns wird
# NICHT mehr ins Bundle gelegt — es bringt eine eingebackene Maske mit, die mit
# der Systemform von macOS 26 kollidiert.
# Ausserhalb von BUILD_DIR ablegen — der ganze BUILD_DIR wird spaeter nach
# build/ kopiert, die Zwischendatei hat dort nichts verloren.
ICON_PARTIAL_PLIST="$(mktemp -t aimonitor-icon).plist"
xcrun actool "$SCRIPT_DIR/Resources/AppIcon.icon" \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --include-all-app-icons \
  --output-partial-info-plist "$ICON_PARTIAL_PLIST" \
  --errors --warnings > /dev/null

if [ ! -f "$APP/Contents/Resources/Assets.car" ]; then
  echo "ERROR: actool hat kein Assets.car erzeugt — App-Icon fehlt."
  exit 1
fi

# Die von actool gemeldeten Schluessel in die Info.plist uebernehmen.
while IFS= read -r key; do
  value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$ICON_PARTIAL_PLIST")
  /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP/Contents/Info.plist"
done < <(/usr/libexec/PlistBuddy -c "Print" "$ICON_PARTIAL_PLIST" \
          | grep -oE '^ *[A-Za-z]+ = ' | tr -d ' =')
echo "App-Icon aus AppIcon.icon kompiliert (Assets.car + AppIcon.icns)"
# Menubar-Icons werden ab v1.8.0 nicht mehr verwendet (LSUIElement unsichtbar),
# bleiben aber im Repo für den Fall, dass wir die Entscheidung revidieren.
# Lokalisierung: de.lproj / en.lproj ins Bundle (App folgt der Systemsprache).
for lang in de en; do
  if [ -d "Resources/$lang.lproj" ]; then
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "Resources/$lang.lproj/Localizable.strings" "$APP/Contents/Resources/$lang.lproj/"
  fi
done

cp Resources/MenuBarIconTemplate.png "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/MenuBarIconTemplate@2x.png "$APP/Contents/Resources/" 2>/dev/null || true

# Bundle esptool als eigenstaendige Binaries (ab v1.27.1).
#
# Vorher lag hier das Python-Paket aus PlatformIO plus per pip gevendorte
# Abhaengigkeiten. Das hatte zwei Fehler, die erst mit dem Universal Build
# sichtbar wurden:
#   1. pip zieht Wheels fuer die Architektur des BUILD-Rechners. Auf einem
#      Apple-Silicon-Runner landeten arm64-only .so-Dateien im Bundle —
#      auf Intel waere das Flashen gescheitert.
#   2. Die Extensions sind an eine Python-Minor-Version gebunden
#      (cpython-314). Mit einem anderen python3 im PATH brach der Import.
#
# Espressif liefert esptool als eigenstaendige Binaries je Architektur.
# Damit entfaellt die Python-Abhaengigkeit fuer das Flashen komplett.
ESPTOOL_VERSION="${ESPTOOL_VERSION:-5.4.0}"
ESPTOOL_CACHE="${ESPTOOL_CACHE:-$HOME/.cache/aimonitor-esptool}"
ESPTOOL_DEST="$APP/Contents/Resources/esptool-bin"
mkdir -p "$ESPTOOL_DEST" "$ESPTOOL_CACHE"

# Espressif nennt die Intel-Variante "amd64"; im Bundle heisst sie wie die
# Swift-Architektur "x86_64", damit die App sie direkt adressieren kann.
for PAIR in "arm64:arm64" "amd64:x86_64"; do
  UP_ARCH="${PAIR%%:*}"
  OUT_ARCH="${PAIR##*:}"
  TARBALL="$ESPTOOL_CACHE/esptool-v$ESPTOOL_VERSION-macos-$UP_ARCH.tar.gz"
  if [ ! -f "$TARBALL" ]; then
    URL="https://github.com/espressif/esptool/releases/download/v$ESPTOOL_VERSION/esptool-v$ESPTOOL_VERSION-macos-$UP_ARCH.tar.gz"
    echo "Downloading esptool $ESPTOOL_VERSION ($UP_ARCH)..."
    # --retry/--continue-at: der Download ist ~60 MB und darf einen Abbruch
    # ueberleben. Erst nach vollstaendigem Transfer umbenennen, damit eine
    # abgebrochene .part nie als gueltiges Archiv missverstanden wird.
    curl -fL --retry 3 --retry-delay 2 --continue-at - \
      -o "$TARBALL.part" "$URL" \
      || { echo "ERROR: esptool download failed ($UP_ARCH)"; rm -f "$TARBALL.part"; exit 1; }
    tar -tzf "$TARBALL.part" >/dev/null 2>&1 \
      || { echo "ERROR: esptool archive corrupt ($UP_ARCH)"; rm -f "$TARBALL.part"; exit 1; }
    mv "$TARBALL.part" "$TARBALL"
  fi
  TMP_X=$(mktemp -d)
  tar -xzf "$TARBALL" -C "$TMP_X"
  # Nur das esptool-Binary uebernehmen — espefuse und esp_rfc2217_server
  # werden nicht gebraucht und wuerden das Bundle unnoetig aufblaehen.
  SRC_BIN=$(find "$TMP_X" -type f -name esptool -perm +111 | head -1)
  [ -n "$SRC_BIN" ] || { echo "ERROR: esptool binary not found in $UP_ARCH tarball"; exit 1; }
  cp "$SRC_BIN" "$ESPTOOL_DEST/esptool-$OUT_ARCH"
  chmod +x "$ESPTOOL_DEST/esptool-$OUT_ARCH"
  rm -rf "$TMP_X"

  # Gegenprobe: Slice muss zur erwarteten Architektur passen, sonst waere
  # genau der Fehler zurueck, den dieser Umbau beseitigt.
  GOT=$(lipo -archs "$ESPTOOL_DEST/esptool-$OUT_ARCH" 2>/dev/null)
  case " $GOT " in
    *" $OUT_ARCH "*) echo "Bundled esptool $ESPTOOL_VERSION ($OUT_ARCH)" ;;
    *) echo "ERROR: esptool-$OUT_ARCH hat Architektur '$GOT'"; exit 1 ;;
  esac
done

# =============================================================================
# Code-Signing
# =============================================================================
if [ "$HAS_DEVELOPER_ID" = "1" ]; then
  echo "Signing with Developer ID (Hardened Runtime + Timestamp)..."

  # Inside-Out-Signing: Zuerst die eingebetteten Mach-O-Binaries signieren,
  # dann erst die .app selbst. --deep ist fuer Distribution deprecated, wir
  # machen es manuell. Die esptool-Binaries laufen als eigener Prozess, aber
  # fuer die Notarisierung muessen ALLE Mach-O-Dateien im Bundle mit unserer
  # Developer ID + Hardened Runtime + Timestamp signiert sein — die Signatur
  # von Espressif wird dabei ersetzt.
  # Die esptool-Binaries werden BEWUSST NICHT neu signiert.
  #
  # Es sind PyInstaller-Bundles: sie entpacken zur Laufzeit ein eigenes
  # Python-Framework und laden es per dlopen. Signiert man nur die aeussere
  # Huelle mit unserer Developer ID, traegt die eingebettete Library weiter
  # Espressifs Team-ID — der Hardened Runtime bricht den Ladevorgang dann ab
  # ("mapping process and mapped file have different Team IDs") und das
  # Flashen scheitert. Espressif signiert die Binaries bereits selbst mit
  # Developer ID und Hardened Runtime; eingebettete Helfer duerfen fremd
  # signiert sein, solange die Signatur gueltig ist.
  if [ -d "$APP/Contents/Resources/esptool-bin" ]; then
    for TOOL in "$APP/Contents/Resources/esptool-bin/"esptool-*; do
      [ -f "$TOOL" ] || continue
      codesign --verify --strict "$TOOL" 2>/dev/null \
        || { echo "ERROR: $(basename "$TOOL") hat keine gueltige Signatur"; exit 1; }
    done
    echo "Verified vendor signatures of bundled esptool binaries"
  fi

  # Main app binary + Bundle. Mit --options runtime = Hardened Runtime.
  # Ohne Entitlements — werden nicht gebraucht: USB-Serial laeuft via open()
  # auf /dev/cu.*, CodexBar wird aus der User Library gelesen, und esptool
  # laeuft als separater Python-Prozess mit eigener Signatur.
  codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/AIMonitor"
  codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" "$APP"

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
echo "4. Run: ../scripts/sync_site_versions.sh   (Installer-Seite nachziehen)"
echo "5. Commit + push"
echo "6. git tag app-vX.Y.Z && git push origin app-vX.Y.Z"
echo "   -> CI baut signiert + notarisiert + gestapelt, legt das Release an"
echo "      und haengt ZIP + DMG an. Ein lokaler Build ist dafuer nicht noetig."
echo ""
echo "Eigene Release-Notes? Vorher ein Release (auch Draft) mit dem Tag"
echo "anlegen — CI laesst vorhandene Notes unveraendert und ergaenzt nur"
echo "die Assets."
echo ""
echo "Lokaler Build hier: ./build.sh zum Testen, NOTARIZE=1 ./build.sh"
echo "fuer ein verteilbares Bundle ausserhalb des Release-Flows."
