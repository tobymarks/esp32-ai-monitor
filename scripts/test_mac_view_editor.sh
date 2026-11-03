#!/usr/bin/env bash
# Syntax parsing and editing-state tests also work with the Linux Swift toolchain.
# This cannot type-check AppKit or replace a macOS layout/interaction test.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v swiftc >/dev/null || { echo "Swift is required (e.g. the official swift:6.2-bookworm container)."; exit 1; }
swiftc -frontend -parse "$TASK_ROOT"/companion/Sources/*.swift
TASK_BINARY="$(mktemp)"
trap 'rm -f "$TASK_BINARY"' EXIT
swiftc "$TASK_ROOT/companion/Sources/DisplayViewEditorState.swift" \
       "$TASK_ROOT/companion/Tests/DisplayViewEditor/main.swift" -o "$TASK_BINARY"
"$TASK_BINARY"
