#!/usr/bin/env bash
# Synchronisiert die Versionsangaben auf der Installer-Seite mit den Quellen.
#
#   Firmware -> src/config.h        (#define APP_VERSION)
#   Mac App  -> companion/build.sh  (APP_VERSION=)
#   Win App  -> companion-windows/src-tauri/tauri.conf.json ("version")
#
# Die Seite verlinkt nur Stable. Steht eine Quelle auf einer Vorabversion
# (z. B. 2.23.0-beta.1), bleibt dieser Teil der Seite unveraendert — so kann
# ein Windows-Stable-Release erscheinen, waehrend Firmware oder Mac-App gerade
# eine Beta haben.
#
# Ohne Argument: patcht installer/index.html.
# Mit --check:   patcht nichts, sondern meldet Abweichungen (Exit 1) — fuer CI.
set -euo pipefail
cd "$(dirname "$0")/.."

PAGE="installer/index.html"
MANIFEST_ILI="installer/manifest.json"
MANIFEST_ST="installer/manifest-st7789.json"
MANIFEST_S3="installer/manifest-st7701.json"

FW=$(grep '#define APP_VERSION' src/config.h | head -1 | sed 's/.*"\(.*\)".*/\1/')
APP=$(grep '^APP_VERSION=' companion/build.sh | head -1 | cut -d'"' -f2)
WIN=$(python3 -c 'import json;print(json.load(open("companion-windows/src-tauri/tauri.conf.json"))["version"])')

[ -n "$FW" ]  || { echo "Firmware-Version nicht gefunden (src/config.h)"; exit 1; }
[ -n "$APP" ] || { echo "App-Version nicht gefunden (companion/build.sh)"; exit 1; }
[ -n "$WIN" ] || { echo "Windows-App-Version nicht gefunden (tauri.conf.json)"; exit 1; }

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

is_stable() { [[ "$1" != *-* ]]; }

# Windows-Betas tragen keinen Suffix (Tag win-beta-v1.4.1, Version 1.4.1).
# Released ist eine Windows-Version erst mit ihrem Tag win-v<Version>. Ohne
# dieses Tag (oder in einem CI-Checkout ohne Tags) bleibt der Windows-Teil
# der Seite unveraendert. Fuer den Release-Commit selbst, vor dem Tag:
#   WIN_RELEASE=1 scripts/sync_site_versions.sh
win_released() {
  [ "${WIN_RELEASE:-}" = "1" ] ||
    [ "${GITHUB_REF:-}" = "refs/tags/win-v$1" ] ||
    git rev-parse -q --verify "refs/tags/win-v$1" >/dev/null 2>&1
}

SED_ARGS=()
if is_stable "$FW"; then
  SED_ARGS+=(
    -e "s|(data-v=\"fw\">)v[0-9]+\.[0-9]+\.[0-9]+|\1v${FW}|g"
    -e "s|(data-v=\"fw-link\">)v[0-9]+\.[0-9]+\.[0-9]+|\1v${FW}|g"
    -e "s|(releases/tag/)v[0-9]+\.[0-9]+\.[0-9]+|\1v${FW}|g"
  )
fi
if is_stable "$APP"; then
  SED_ARGS+=(
    -e "s|(data-v=\"app\">)v[0-9]+\.[0-9]+\.[0-9]+|\1v${APP}|g"
    -e "s|(releases/download/app-)v[0-9]+\.[0-9]+\.[0-9]+|\1v${APP}|g"
    -e "s|(releases/tag/app-)v[0-9]+\.[0-9]+\.[0-9]+|\1v${APP}|g"
  )
fi
if is_stable "$WIN" && win_released "$WIN"; then
  SED_ARGS+=(
    -e "s|(data-v=\"win\">)v[0-9]+\.[0-9]+\.[0-9]+|\1v${WIN}|g"
    -e "s|(releases/download/win-(beta-)?v)[0-9]+\.[0-9]+\.[0-9]+|\1${WIN}|g"
    -e "s|(releases/tag/win-(beta-)?v)[0-9]+\.[0-9]+\.[0-9]+|\1${WIN}|g"
  )
fi
# Stand, den die Seite zeigen soll; Vorabversionen sind markiert.
label() { is_stable "$1" && echo "v$1" || echo "v$1 (Vorabversion, Seite unverändert)"; }
win_label() { is_stable "$1" && win_released "$1" && echo "v$1" || echo "v$1 (noch nicht als win-v$1 veröffentlicht, Seite unverändert)"; }

tmp=$(mktemp)
if [ ${#SED_ARGS[@]} -gt 0 ]; then
  sed -E "${SED_ARGS[@]}" "$PAGE" > "$tmp"
else
  cp "$PAGE" "$tmp"
fi

# Die Firmware-Version steckt auch im JS-Woerterbuch (help.a4 nutzt __FW__),
# dort ist nichts zu ersetzen — der Platzhalter zieht sich den Wert aus dem DOM.

if [ "$CHECK" = "1" ]; then
  # Zeilenenden ignorieren: auf Windows-Runnern liegt die Seite mit CRLF vor,
  # die sed-Ausgabe hat LF; ohne Normalisierung meldet diff jede Zeile.
  if ! diff -q <(tr -d "\r" < "$PAGE") <(tr -d "\r" < "$tmp") >/dev/null; then
    echo "Versionen auf der Seite weichen ab (erwartet: FW $(label "$FW"), App $(label "$APP"), Windows $(win_label "$WIN")):"
    diff <(tr -d "\r" < "$PAGE") <(tr -d "\r" < "$tmp") | head -20 || true
    echo
    echo "Fix: scripts/sync_site_versions.sh"
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
  echo "Seite ist aktuell: FW $(label "$FW"), App $(label "$APP"), Windows $(win_label "$WIN")"
  exit 0
fi

mv "$tmp" "$PAGE"

if is_stable "$FW"; then
  for m in "$MANIFEST_ILI" "$MANIFEST_ST" "$MANIFEST_S3"; do
    [ -f "$m" ] || continue
    sed -i.bak -E "s|(\"version\": \")[0-9]+\.[0-9]+\.[0-9]+|\1${FW}|" "$m" && rm -f "$m.bak"
  done
fi

echo "Seite und Manifeste aktualisiert: FW $(label "$FW"), App $(label "$APP"), Windows $(win_label "$WIN")"
