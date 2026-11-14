#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t aimonitor-scene-contract.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
OUTPUT="${AIMONITOR_SCENE_OUTPUT_DIR:-$WORK/images}"

host() {
  cargo run --quiet --locked --manifest-path "$ROOT/companion-windows/Cargo.toml" \
    -p aimonitor-plugin-host -- "$@"
}

for fixture in display-plugin display-plugin-format3; do
  python3 "$ROOT/scripts/package_display_plugin.py" \
    "$ROOT/tests/fixtures/$fixture/plugin.json" "$WORK/$fixture.aimplugin" > /dev/null
done

host render "$WORK/display-plugin.aimplugin" - all \
  "$ROOT/tests/fixtures/display-plugin/response.json" > "$WORK/legacy.json"

FORMAT3="$ROOT/tests/fixtures/display-plugin-format3/response.json"
LOCATION='--location={"name":"Köln","latitude":50.93751,"longitude":6.96028}'
host inspect "$WORK/display-plugin-format3.aimplugin" > "$WORK/preview.json"
for protocol in 1 2; do
  host render "$WORK/display-plugin-format3.aimplugin" - all "$FORMAT3" \
    "$LOCATION" "--scene-protocol=$protocol" > "$WORK/format3-protocol$protocol.json"
done

# Use fewer source entries to exercise optional rows and the zero-result state.
python3 - "$FORMAT3" "$WORK" <<'PY'
import json
from pathlib import Path
import sys

source = json.loads(Path(sys.argv[1]).read_text())
for case, entries in (("single", [source["ac"][4]]), ("empty", [])):
    Path(sys.argv[2], f"{case}-response.json").write_text(
        json.dumps({**source, "ac": entries}))
PY
for case in single empty; do
  host render "$WORK/display-plugin-format3.aimplugin" - all "$WORK/$case-response.json" \
    "$LOCATION" --scene-protocol=2 > "$WORK/format3-$case.json"
done

python3 - "$WORK" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
preview = json.loads((root / "preview.json").read_text())
assert preview["requiresLocation"] is True
assert preview["intervalSeconds"] == 20
assert preview["sourceOrigin"] == "https://example.org"

expected = {
    "format3-protocol2": ["FLÜGE Köln", "4 Flüge", "SWR2CY: 145 m", "UAL932", "ÄÖÜ äöü ß", "12.5 °C"],
    "format3-protocol1": ["FLUEGE Koeln", "4 Fluege", "SWR2CY: 145 m", "UAL932", "AEOEUE aeoeue ss", "12.5 C"],
    "format3-single": ["FLÜGE Köln", "1 Flüge", "SWR2CY: 145 m", "ÄÖÜ äöü ß", "12.5 °C"],
    "format3-empty": ["FLÜGE Köln", "0 Flüge", "Keine Flüge: -- m", "ÄÖÜ äöü ß", "12.5 °C"],
}
for case in ("legacy", *expected):
    result = json.loads((root / f"{case}.json").read_text())
    assert set(result["scenes"]) == {"portrait", "landscape", "square"}, case
    folder = root / case
    folder.mkdir()
    for layout, scene in result["scenes"].items():
        nodes = scene["nodes"]
        texts = [node["text"] for node in nodes if node["type"] == "text"]
        bar_values = [node["value"] for node in nodes if node["type"] == "bar"]
        if case == "legacy":
            assert bar_values == [62], (case, layout, bar_values)
            assert "Demo" in texts and "18 pts" in texts, (case, layout, texts)
        else:
            assert texts == expected[case], (case, layout, texts)
            count = 0 if case.endswith("empty") else 1 if case.endswith("single") else 4
            assert bar_values == [count], (case, layout, bar_values)
            assert result["attention"] == {"overhead": count > 0}, case
        for text in texts:
            assert len(text.encode("utf-8")) <= 64, (case, layout, text)
            if case == "format3-protocol1":
                assert all(32 <= ord(c) <= 126 for c in text), (layout, text)
        (folder / f"{layout}.json").write_text(
            json.dumps(scene, ensure_ascii=False, separators=(",", ":")))
    print(f"{case}: expected content in all three layouts")

# Protocol downgrade changes text only; drawing nodes and geometry stay intact.
new = json.loads((root / "format3-protocol2.json").read_text())["scenes"]
old = json.loads((root / "format3-protocol1.json").read_text())["scenes"]
for layout in new:
    assert old[layout]["background"] == new[layout]["background"]
    assert len(old[layout]["nodes"]) == len(new[layout]["nodes"])
    for before, after in zip(new[layout]["nodes"], old[layout]["nodes"]):
        assert {k: v for k, v in before.items() if k != "text"} == {
            k: v for k, v in after.items() if k != "text"}
        if "text" in before:
            assert len(after["text"].encode()) <= len(before["text"].encode())
PY

# Reuse the compiled LVGL library while rendering every contract case.
for case in legacy format3-protocol2 format3-protocol1 format3-single format3-empty; do
  SCENES=("$WORK/$case/portrait.json" "$WORK/$case/landscape.json" "$WORK/$case/square.json")
  bash "$ROOT/scripts/test_plugin_scene_native.sh" "${SCENES[@]}"
  # Preserve the original fixture's image paths for existing callers.
  CASE_OUTPUT="$OUTPUT/$case"
  if [[ "$case" == legacy ]]; then CASE_OUTPUT="$OUTPUT"; fi
  AIMONITOR_SCENE_BUILD_DIR="$WORK/render-build" AIMONITOR_SCENE_OUTPUT_DIR="$CASE_OUTPUT" \
    bash "$ROOT/scripts/test_plugin_scene_render_native.sh" "${SCENES[@]}"
done
