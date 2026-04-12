#!/usr/bin/env bash
# =============================================================================
# serial_feeder.sh — CodexBar USB-Serial Feeder fuer ESP32 AI Monitor
# =============================================================================
#
# Pollt codexbar alle 90s und sendet die Usage-Daten als JSON per USB-Serial
# an den angeschlossenen ESP32.
#
# Voraussetzungen:
#   - codexbar im PATH (https://github.com/anthropics/codexbar)
#   - ESP32 per USB angeschlossen (/dev/cu.usbserial-*)
#   - jq installiert (brew install jq)
#
# Installation als LaunchAgent (automatischer Start bei Login):
#   cp scripts/com.aimonitor.serial-feeder.plist ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/com.aimonitor.serial-feeder.plist
#
# Deinstallation:
#   launchctl unload ~/Library/LaunchAgents/com.aimonitor.serial-feeder.plist
#   rm ~/Library/LaunchAgents/com.aimonitor.serial-feeder.plist
#
# =============================================================================

set -euo pipefail

BAUD=115200
POLL_INTERVAL=90
PORT_PATTERN="/dev/cu.usbserial-*"

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------
log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
}

# ---------------------------------------------------------------------------
# Finde ESP32 Serial-Port
# ---------------------------------------------------------------------------
find_port() {
  local ports
  # shellcheck disable=SC2086
  ports=( $PORT_PATTERN )
  if [[ -e "${ports[0]:-}" ]]; then
    echo "${ports[0]}"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Warte bis ein Serial-Port auftaucht
# ---------------------------------------------------------------------------
wait_for_port() {
  log "Warte auf Serial-Port ($PORT_PATTERN) ..."
  while true; do
    if PORT=$(find_port); then
      log "Port gefunden: $PORT"
      return 0
    fi
    sleep 2
  done
}

# ---------------------------------------------------------------------------
# Serial-Port konfigurieren (macOS stty)
# ---------------------------------------------------------------------------
configure_port() {
  stty -f "$PORT" "$BAUD" cs8 -cstopb -parenb raw 2>/dev/null
  log "Port $PORT konfiguriert (${BAUD} 8N1)"
}

# ---------------------------------------------------------------------------
# Hauptschleife
# ---------------------------------------------------------------------------
main() {
  log "serial_feeder.sh gestartet (PID $$)"

  # Auf Port warten
  wait_for_port
  configure_port

  while true; do
    # Pruefen ob Port noch da ist (USB abgezogen?)
    if [[ ! -e "$PORT" ]]; then
      log "WARN: Port $PORT verschwunden — warte auf Reconnect ..."
      wait_for_port
      configure_port
    fi

    # codexbar abfragen
    local raw_json
    if raw_json=$(codexbar usage --provider claude --source oauth --json 2>&1); then
      # Timestamp erzeugen und Envelope bauen
      local ts
      ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      local envelope
      envelope=$(printf '{"time":"%s","data":%s}' "$ts" "$raw_json" | jq -c . 2>/dev/null)

      if [[ -n "$envelope" ]]; then
        # Senden
        echo "$envelope" > "$PORT"
        log "OK: gesendet (${#envelope} bytes)"
      else
        log "WARN: jq konnte Envelope nicht bauen — raw: ${raw_json:0:120}"
      fi
    else
      log "ERR: codexbar fehlgeschlagen — $raw_json"
    fi

    sleep "$POLL_INTERVAL"
  done
}

main
