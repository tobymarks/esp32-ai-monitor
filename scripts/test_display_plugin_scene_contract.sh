#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$(mktemp -t aimonitor-display-fixture.XXXXXX)"
RESULT="$(mktemp -t aimonitor-fixture-scenes.XXXXXX)"
PORTRAIT="$(mktemp -t aimonitor-fixture-portrait.XXXXXX)"
LANDSCAPE="$(mktemp -t aimonitor-fixture-landscape.XXXXXX)"
SQUARE="$(mktemp -t aimonitor-fixture-square.XXXXXX)"
trap 'for file in "$PACKAGE" "$RESULT" "$PORTRAIT" "$LANDSCAPE" "$SQUARE"; do unlink "$file"; done' EXIT

python3 "$ROOT/scripts/package_display_plugin.py" \
  "$ROOT/tests/fixtures/display-plugin/plugin.json" "$PACKAGE" > /dev/null

cargo run --quiet --locked --manifest-path "$ROOT/companion-windows/Cargo.toml" \
  -p aimonitor-plugin-host -- render \
  "$PACKAGE" - all \
  "$ROOT/tests/fixtures/display-plugin/response.json" > "$RESULT"

python3 - "$RESULT" "$PORTRAIT" "$LANDSCAPE" "$SQUARE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    scenes = json.load(handle)["scenes"]
for name, path in zip(("portrait", "landscape", "square"), sys.argv[2:], strict=True):
    scene = scenes[name]
    assert any(node.get("type") == "bar" and node.get("value") == 62
               for node in scene["nodes"]), f"missing bound bar in {name}"
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(scene, handle, separators=(",", ":"))
PY

bash "$ROOT/scripts/test_plugin_scene_native.sh" \
  "$PORTRAIT" "$LANDSCAPE" "$SQUARE"

bash "$ROOT/scripts/test_plugin_scene_render_native.sh" \
  "$PORTRAIT" "$LANDSCAPE" "$SQUARE"
