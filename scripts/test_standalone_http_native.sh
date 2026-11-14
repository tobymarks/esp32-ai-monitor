#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -t aimonitor-standalone-http.XXXXXX)"
trap 'rm -f "$OUT"' EXIT
g++ -std=c++17 -Wall -Wextra -I"$ROOT/src" "$ROOT/tests/standalone_http_native.cpp" "$ROOT/src/standalone_http.cpp" -o "$OUT"
"$OUT"
