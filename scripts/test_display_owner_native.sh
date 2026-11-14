#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -t aimonitor-owner.XXXXXX)"
trap 'rm -f "$OUT"' EXIT
g++ -std=c++17 -Wall -Wextra -Werror -I"$ROOT/src" "$ROOT/tests/display_owner_native.cpp" -o "$OUT"
"$OUT"
