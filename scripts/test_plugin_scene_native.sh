#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARDUINO_JSON="$ROOT/.pio/libdeps/esp32dev/ArduinoJson/src"
if [ ! -f "$ARDUINO_JSON/ArduinoJson.h" ]; then
  echo "Build the esp32dev PlatformIO environment first to install ArduinoJson." >&2
  exit 1
fi

OUT="$(mktemp -t aimonitor-plugin-scene.XXXXXX)"
trap 'unlink "$OUT"' EXIT
g++ -std=c++17 -Wall -Wextra -I"$ROOT/src" -I"$ARDUINO_JSON" \
  "$ROOT/tests/plugin_scene_native.cpp" "$ROOT/src/plugin_scene.cpp" -o "$OUT"
"$OUT" "$@"
