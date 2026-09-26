#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" -ne 3 ]]; then
    echo "usage: $0 portrait.json landscape.json square.json" >&2
    exit 2
fi

BUILD="$(mktemp -d -t aimonitor-lvgl-render.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT
LVGL="$ROOT/.pio/libdeps/esp32dev/lvgl"
ARDUINOJSON="$ROOT/.pio/libdeps/esp32dev/ArduinoJson"
if [[ ! -f "$LVGL/CMakeLists.txt" || ! -f "$ARDUINOJSON/src/ArduinoJson.h" ]]; then
    echo "Build the CYD firmware first to install the pinned LVGL and ArduinoJson versions" >&2
    exit 1
fi

if ! cmake -S "$LVGL" -B "$BUILD" -DLV_BUILD_CONF_PATH="$ROOT/src/lv_conf.h" \
    -DCONFIG_LV_BUILD_DEMOS=OFF -DCONFIG_LV_BUILD_EXAMPLES=OFF \
    -DCONFIG_LV_USE_THORVG_INTERNAL=OFF -DCMAKE_BUILD_TYPE=Release \
    > "$BUILD/configure.log" 2>&1; then
    cat "$BUILD/configure.log" >&2
    exit 1
fi
if ! cmake --build "$BUILD" --target lvgl -j 4 > "$BUILD/build.log" 2>&1; then
    tail -100 "$BUILD/build.log" >&2
    exit 1
fi

c++ -std=c++17 -O2 -DLV_CONF_PATH='"'"$ROOT/src/lv_conf.h"'"' \
    -I "$ROOT/src" -I "$LVGL" -I "$ARDUINOJSON/src" \
    "$ROOT/tests/plugin_scene_render_native.cpp" \
    "$ROOT/src/plugin_scene.cpp" "$ROOT/src/plugin_scene_renderer.cpp" \
    "$BUILD/lib/liblvgl.a" -lm -pthread -o "$BUILD/render_scene"

OUTPUT="${AIMONITOR_SCENE_OUTPUT_DIR:-$BUILD}"
mkdir -p "$OUTPUT"
"$BUILD/render_scene" "$1" 240 320 "$OUTPUT/portrait.ppm"
"$BUILD/render_scene" "$2" 320 240 "$OUTPUT/landscape.ppm"
"$BUILD/render_scene" "$3" 480 480 "$OUTPUT/square.ppm"

python3 - "$OUTPUT" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
for name, size in (("portrait", (240, 320)), ("landscape", (320, 240)), ("square", (480, 480))):
    data = (out / f"{name}.ppm").read_bytes()
    header = f"P6\n{size[0]} {size[1]}\n255\n".encode()
    assert data.startswith(header), f"{name}: invalid image header"
    pixels = data[len(header):]
    assert len(pixels) == size[0] * size[1] * 3, f"{name}: missing pixels"
    colors = {pixels[i:i + 3] for i in range(0, len(pixels), 3)}
    assert len(colors) > 10, f"{name}: scene did not render"
    print(f"{name}: {size[0]}x{size[1]}, {len(colors)} colors")
PY
