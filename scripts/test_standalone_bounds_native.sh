#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -t aimonitor-standalone-bounds.XXXXXX)"
trap 'rm -f "$OUT"' EXIT
g++ -std=c++17 -Wall -Wextra -I"$ROOT/src" -I"$ROOT/.pio/libdeps/esp32dev/ArduinoJson/src" \
  "$ROOT/tests/standalone_bounds_native.cpp" "$ROOT/src/standalone_profile.cpp" "$ROOT/src/plugin_scene.cpp" -o "$OUT"
"$OUT"
