#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${AIMONITOR_SITE_BUILD_DIR:-/tmp/aimonitor-site-render}"
OUTPUT="${AIMONITOR_SITE_OUTPUT_DIR:-$ROOT/installer/assets/screens}"
LVGL="$ROOT/.pio/libdeps/esp32dev/lvgl"
JSON="$ROOT/.pio/libdeps/esp32dev/ArduinoJson/src"
mkdir -p "$BUILD" "$OUTPUT"
if ! cmake -S "$LVGL" -B "$BUILD" -DLV_BUILD_CONF_PATH="$ROOT/src/lv_conf.h" -DCONFIG_LV_BUILD_DEMOS=OFF -DCONFIG_LV_BUILD_EXAMPLES=OFF -DCONFIG_LV_USE_THORVG_INTERNAL=OFF -DCMAKE_BUILD_TYPE=Release > "$BUILD/configure.log" 2>&1; then
  cat "$BUILD/configure.log" >&2
  exit 1
fi
if ! cmake --build "$BUILD" --target lvgl -j 4 > "$BUILD/build.log" 2>&1; then
  tail -100 "$BUILD/build.log" >&2
  exit 1
fi
cc -O2 -DLV_CONF_PATH=\""$ROOT/src/lv_conf.h"\" -I "$LVGL" -c "$ROOT/src/font_standby_clock_76.c" -o "$BUILD/clock.o"
FONT_OBJECTS=()
for FONT in "$ROOT"/src/font_ui_*.c; do
  OBJECT="$BUILD/$(basename "$FONT" .c).o"
  cc -O2 -DLV_CONF_PATH=\""$ROOT/src/lv_conf.h"\" -I "$LVGL" -c "$FONT" -o "$OBJECT"
  FONT_OBJECTS+=("$OBJECT")
done
c++ -std=c++17 -O2 -DLV_CONF_PATH=\""$ROOT/src/lv_conf.h"\" -I "$ROOT/scripts/site-render" -I "$ROOT/src" -I "$LVGL" -I "$JSON" \
  "$ROOT/scripts/site-render/render.cpp" "$ROOT/src/ui_dashboard.cpp" "$ROOT/src/ui_common.cpp" "$ROOT/src/providers.cpp" "$ROOT/src/localization.cpp" \
  "$ROOT/src/plugin_scene.cpp" "$ROOT/src/plugin_scene_renderer.cpp" "$BUILD/clock.o" "${FONT_OBJECTS[@]}" "$BUILD/lib/liblvgl.a" -lm -pthread -o "$BUILD/render"
for spec in '320 240 claude 1 cyd-rings' '240 320 claude 1 cyd-bars' '320 240 chatgpt 1 cyd-chatgpt' '480 480 chatgpt 1 s3-chatgpt' '480 480 claude 0 s3-claude' '480 480 claude-full 1 s3-claude-full'; do
  read -r width height provider theme name <<< "$spec"
  "$BUILD/render" "$width" "$height" "$provider" "$theme" "$BUILD/$name.ppm"
  sips -s format png "$BUILD/$name.ppm" --out "$OUTPUT/$name.png" >/dev/null
done
