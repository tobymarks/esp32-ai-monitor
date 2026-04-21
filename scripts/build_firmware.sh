#!/bin/bash
# Build firmware and prepare installer binary for ESP Web Tools
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIRMWARE_DIR="$PROJECT_DIR/.pio/build/esp32dev"
FIRMWARE_ST7789_DIR="$PROJECT_DIR/.pio/build/esp32dev-st7789"
INSTALLER_DIR="$PROJECT_DIR/installer"
OUTPUT_BIN="$INSTALLER_DIR/bin/ai-monitor.bin"
OUTPUT_BIN_ST7789="$INSTALLER_DIR/bin/ai-monitor-st7789.bin"
BOOT_APP0="$HOME/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"

echo "=== Building firmware ==="
cd "$PROJECT_DIR"
pio run

echo ""
echo "=== Merging firmware binary ==="

# Verify required files exist
for f in \
  "$FIRMWARE_DIR/bootloader.bin" "$FIRMWARE_DIR/partitions.bin" "$FIRMWARE_DIR/firmware.bin" \
  "$FIRMWARE_ST7789_DIR/bootloader.bin" "$FIRMWARE_ST7789_DIR/partitions.bin" "$FIRMWARE_ST7789_DIR/firmware.bin"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: Missing $f"
    exit 1
  fi
done

if [ ! -f "$BOOT_APP0" ]; then
  echo "ERROR: Missing boot_app0.bin at $BOOT_APP0"
  echo "Try: pio pkg install -g -p espressif32"
  exit 1
fi

mkdir -p "$INSTALLER_DIR/bin"

esptool.py --chip esp32 merge_bin \
  -o "$OUTPUT_BIN" \
  --flash_mode dio \
  --flash_freq 40m \
  --flash_size 4MB \
  0x1000  "$FIRMWARE_DIR/bootloader.bin" \
  0x8000  "$FIRMWARE_DIR/partitions.bin" \
  0xe000  "$BOOT_APP0" \
  0x10000 "$FIRMWARE_DIR/firmware.bin"

esptool.py --chip esp32 merge_bin \
  -o "$OUTPUT_BIN_ST7789" \
  --flash_mode dio \
  --flash_freq 40m \
  --flash_size 4MB \
  0x1000  "$FIRMWARE_ST7789_DIR/bootloader.bin" \
  0x8000  "$FIRMWARE_ST7789_DIR/partitions.bin" \
  0xe000  "$BOOT_APP0" \
  0x10000 "$FIRMWARE_ST7789_DIR/firmware.bin"

cp "$FIRMWARE_DIR/firmware.bin" "$INSTALLER_DIR/bin/firmware-ota.bin"
cp "$FIRMWARE_ST7789_DIR/firmware.bin" "$INSTALLER_DIR/bin/firmware-ota-st7789.bin"

echo ""
echo "=== Updating manifest ==="

# Extract version from config.h
VERSION=$(grep '#define APP_VERSION' "$PROJECT_DIR/src/config.h" | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [ -z "$VERSION" ]; then
  echo "WARNING: Could not extract version from config.h, keeping manifest as-is"
else
  # Update installer manifests version
  if command -v python3 &> /dev/null; then
    python3 -c "
import json, sys
for manifest in ('$INSTALLER_DIR/manifest.json', '$INSTALLER_DIR/manifest-st7789.json'):
    with open(manifest, 'r') as f:
        m = json.load(f)
    m['version'] = '$VERSION'
    with open(manifest, 'w') as f:
        json.dump(m, f, indent=2)
        f.write('\n')
"
  else
    sed -i.bak "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" "$INSTALLER_DIR/manifest.json"
    sed -i.bak "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" "$INSTALLER_DIR/manifest-st7789.json"
    rm -f "$INSTALLER_DIR/manifest.json.bak"
    rm -f "$INSTALLER_DIR/manifest-st7789.json.bak"
  fi
  echo "Version: $VERSION"
fi

echo ""
echo "=== Done ==="
echo "Firmware: $OUTPUT_BIN"
echo "Firmware ST7789: $OUTPUT_BIN_ST7789"
echo "Size (ILI9341): $(du -h "$OUTPUT_BIN" | cut -f1)"
echo "Size (ST7789):  $(du -h "$OUTPUT_BIN_ST7789" | cut -f1)"
echo "Version: ${VERSION:-unknown}"
