#!/usr/bin/env bash
# Erzeugt src/font_ui_<px>.c: die Montserrat-Schriften von LVGL mit denselben
# Optionen wie die eingebauten, ergänzt um Ä Ö Ü ä ö ü ß. Zeilenhöhe und
# Grundlinie bleiben gleich, bestehende Layouts verschieben sich nicht.
# Braucht Node (npx lv_font_conv) und die LVGL-Quellen aus einem CYD-Build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FONTS="$ROOT/.pio/libdeps/esp32dev/lvgl/scripts/built_in_font"
if [[ ! -f "$FONTS/Montserrat-Medium.ttf" ]]; then
    echo "Build the CYD firmware first to install the pinned LVGL version" >&2
    exit 1
fi

# ASCII, Grad, Aufzählungspunkt wie in LVGL, dazu die deutschen Umlaute.
TEXT="0x20-0x7F,0xB0,0x2022,0xC4,0xD6,0xDC,0xDF,0xE4,0xF6,0xFC"
# Symbolsatz der eingebauten Schriften (LV_SYMBOL_*), siehe built_in_font_gen.py.
SYMBOLS="61441,61448,61451,61452,61452,61453,61457,61459,61461,61465,61468,61473,61478,61479,61480,61502,61507,61512,61515,61516,61517,61521,61522,61523,61524,61543,61544,61550,61552,61553,61556,61559,61560,61561,61563,61587,61589,61636,61637,61639,61641,61664,61671,61674,61683,61724,61732,61787,61931,62016,62017,62018,62019,62020,62087,62099,62212,62189,62810,63426,63650"

cd "$FONTS"
for SIZE in 12 14 16 20 24 36 48; do
    npx --yes lv_font_conv@1.5.3 --no-compress --no-prefilter --bpp 4 --size "$SIZE" \
        --font Montserrat-Medium.ttf -r "$TEXT" \
        --font "FontAwesome5-Solid+Brands+Regular.woff" -r "$SYMBOLS" \
        --format lvgl --force-fast-kern-format \
        --lv-font-name "font_ui_$SIZE" --lv-include lvgl.h \
        -o "$ROOT/src/font_ui_$SIZE.c"
    # Der Kopfkommentar nennt sonst den absoluten Pfad des Rechners.
    sed -i.bak "s#-o $ROOT/src/#-o src/#" "$ROOT/src/font_ui_$SIZE.c"
    rm -f "$ROOT/src/font_ui_$SIZE.c.bak"
done
