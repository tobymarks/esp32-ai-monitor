"""
Pre-build script: Remove ARM-specific assembly files from LVGL.
LVGL includes Helium/NEON .S files incompatible with ESP32 xtensa assembler.
PlatformIO compiles all .S files regardless of preprocessor guards.
"""
import os
import glob

Import("env")

lvgl_dir = os.path.join(env.subst("$PROJECT_LIBDEPS_DIR"), env.subst("$PIOENV"), "lvgl")
if os.path.isdir(lvgl_dir):
    for s_file in glob.glob(os.path.join(lvgl_dir, "**", "*.S"), recursive=True):
        print(f"  Removing incompatible ASM: {s_file}")
        os.remove(s_file)
