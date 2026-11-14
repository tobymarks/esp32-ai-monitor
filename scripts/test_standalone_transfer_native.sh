#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -t aimonitor-standalone-transfer.XXXXXX)"
trap 'rm -f "$OUT"' EXIT
g++ -std=c++17 -Wall -Wextra -Werror -I"$ROOT/src" "$ROOT/tests/standalone_transfer_native.cpp" -o "$OUT"
"$OUT"
