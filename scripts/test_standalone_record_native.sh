#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aimonitor-record.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer -I src tests/standalone_record_native.cpp -o "$TASK_TMP/record"
"$TASK_TMP/record"
