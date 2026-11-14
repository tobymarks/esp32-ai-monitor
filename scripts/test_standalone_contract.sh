#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aimonitor-standalone.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
JSON_INCLUDE=".pio/libdeps/esp32dev/ArduinoJson/src"
if [[ ! -d "$JSON_INCLUDE" ]]; then
  echo "ArduinoJson missing; install project PlatformIO dependencies first" >&2
  exit 1
fi
"$CARGO" run --quiet --locked --manifest-path companion-windows/Cargo.toml -p aimonitor-core --example standalone_goldens > "$TASK_TMP/goldens.jsonl"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -Wno-misleading-indentation -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I src -I "$JSON_INCLUDE" src/standalone_profile.cpp tests/standalone_contract_native.cpp -o "$TASK_TMP/contract"
"$TASK_TMP/contract" "$TASK_TMP/goldens.jsonl"
