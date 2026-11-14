#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -t aimonitor-standalone-policy.XXXXXX)"
trap 'rm -f "$OUT"' EXIT
g++ -std=c++17 -Wall -Wextra -fsanitize=address,undefined -I"$ROOT/src" "$ROOT/tests/standalone_policy_native.cpp" -o "$OUT"
"$OUT"
