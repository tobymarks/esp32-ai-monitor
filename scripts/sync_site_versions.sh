#!/usr/bin/env bash
# Synchronisiert die Versionsangaben auf der Installer-Seite mit den Quellen.
#
#   Firmware -> src/config.h        (#define APP_VERSION)
#   Mac App  -> companion/build.sh  (APP_VERSION=)
#   Win App  -> companion-windows/src-tauri/tauri.conf.json ("version")
#
# Ohne Argument: patcht installer/index.html.
# Mit --check:   patcht nichts, sondern meldet Abweichungen (Exit 1) — fuer CI.
set -euo pipefail
cd "$(dirname "$0")/.."

PAGE="installer/index.html"
MANIFEST_ILI="installer/manifest.json"
MANIFEST_ST="installer/manifest-st7789.json"

FW=$(grep '#define APP_VERSION' src/config.h | head -1 | sed 's/.*"\(.*\)".*/\1/')
APP=$(grep '^APP_VERSION=' companion/build.sh | head -1 | cut -d'"' -f2)
WIN=$(python3 -c 'import json;print(json.load(open("companion-windows/src-tauri/tauri.conf.json"))["version"])')

[ -n "$FW" ]  || { echo "Firmware-Version nicht gefunden (src/config.h)"; exit 1; }
[ -n "$APP" ] || { echo "App-Version nicht gefunden (companion/build.sh)"; exit 1; }
[ -n "$WIN" ] || { echo "Windows-App-Version nicht gefunden (tauri.conf.json)"; exit 1; }

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

tmp=$(mktemp)
sed -E \
  -e "s|(data-v=\"fw\">)v[0-9]+\.[0-9]+\.[0-9]+|\1v${FW}|g" \
  -e "s|(data-v=\"app\">)v[0-9]+\.[0-9]+\.[0-9]+|\1v${APP}|g" \
  -e "s|(data-v=\"fw-link\">)v[0-9]+\.[0-9]+\.[0-9]+|\1v${FW}|g" \
  -e "s|(releases/download/app-)v[0-9]+\.[0-9]+\.[0-9]+|\1v${APP}|g" \
  -e "s|(releases/tag/app-)v[0-9]+\.[0-9]+\.[0-9]+|\1v${APP}|g" \
  -e "s|(releases/tag/)v[0-9]+\.[0-9]+\.[0-9]+|\1v${FW}|g" \
  -e "s|(data-v=\"win\">)v[0-9]+\.[0-9]+\.[0-9]+|\1v${WIN}|g" \
  -e "s|(releases/download/win-(beta-)?v)[0-9]+\.[0-9]+\.[0-9]+|\1${WIN}|g" \
  -e "s|(releases/tag/win-(beta-)?v)[0-9]+\.[0-9]+\.[0-9]+|\1${WIN}|g" \
  "$PAGE" > "$tmp"

# Die Firmware-Version steckt auch im JS-Woerterbuch (help.a4 nutzt __FW__),
# dort ist nichts zu ersetzen — der Platzhalter zieht sich den Wert aus dem DOM.

if [ "$CHECK" = "1" ]; then
  if ! diff -q "$PAGE" "$tmp" >/dev/null; then
    echo "Versionen auf der Seite weichen ab (erwartet: FW v${FW}, App v${APP}, Windows v${WIN}):"
    diff "$PAGE" "$tmp" | head -20 || true
    echo
    echo "Fix: scripts/sync_site_versions.sh"
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
  echo "Seite ist aktuell: FW v${FW}, App v${APP}, Windows v${WIN}"
  exit 0
fi

mv "$tmp" "$PAGE"

for m in "$MANIFEST_ILI" "$MANIFEST_ST"; do
  [ -f "$m" ] || continue
  sed -i.bak -E "s|(\"version\": \")[0-9]+\.[0-9]+\.[0-9]+|\1${FW}|" "$m" && rm -f "$m.bak"
done

echo "Seite und Manifeste aktualisiert: FW v${FW}, App v${APP}, Windows v${WIN}"
