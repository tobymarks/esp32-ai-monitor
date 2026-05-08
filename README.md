# AI Monitor

A macOS background app plus an ESP32 desk display for keeping AI usage limits visible while you work. It reads the local CodexBar usage snapshot for Claude, Codex, or Antigravity, then streams the current limits to a small USB-connected CYD display.

No WiFi on the ESP32, no display-side cloud credentials, no browser tab to keep open.

## How It Works

CodexBar collects the provider usage data and writes a local `widget-snapshot.json`. The **AI Monitor** Mac app watches that file, applies your selected provider and display settings, and sends a compact JSON frame over USB serial to the ESP32. The ESP32 renders the dashboard on the 2.8" color display.

```text
AI providers -> CodexBar snapshot -> AI Monitor.app -> USB serial -> ESP32 CYD display
```

The Mac app can also flash firmware, check GitHub Releases for app and firmware updates, and remember per-device display settings.

## Features

- Claude, Codex, and Antigravity provider views
- Session, weekly, and third usage rows where available
- Antigravity model rows for Claude, Gemini Pro, and Gemini Flash
- Used or remaining percentage display mode
- Live reset countdowns and local display clock
- Optional cost/extra-usage support when supplied by the provider data
- Automatic USB serial detection and instant resend on connect
- Per-device settings for orientation, theme, language, brightness, timezone, and board variant
- Portrait plus left/right landscape layouts
- Firmware flashing for ILI9341 and ST7789 CYD variants
- Optional menu bar quick menu for provider switching

## Quick Start

1. **Buy** an [ESP32-2432S028 / ESP32-2432S028R board](https://de.aliexpress.com/item/1005007731775734.html), also known as a Cheap Yellow Display.
2. **Flash** the firmware via the [Web Installer](https://tobymarks.github.io/esp32-ai-monitor/) or PlatformIO.
3. **Install and run CodexBar** so it can write the local usage snapshot.
4. **Download** the AI Monitor Mac app from [GitHub Releases](https://github.com/tobymarks/esp32-ai-monitor/releases).
5. **Plug** the ESP32 into your Mac via a USB data cable and choose the provider in the AI Monitor settings window.

## Requirements

- macOS 13+ on Apple Silicon
- CodexBar installed and writing `widget-snapshot.json`
- Claude, Codex, or Antigravity access in CodexBar
- ESP32-2432S028 / ESP32-2432S028R CYD board
- USB data cable, not a charge-only cable
- Chrome or Edge for the browser-based firmware installer

## Hardware

Supported board family:

- **ESP32-2432S028R / R board:** ILI9341 display controller
- **ESP32-2432S028 / Hybrid board:** ST7789 display controller

Common hardware:

- **Display:** 2.8" 320x240 TFT
- **Touch:** XPT2046
- **MCU:** ESP32-WROOM-32
- **Backlight:** GPIO 21

If the display stays white or shows noise after flashing, flash the other panel variant from the installer.

## Enclosures

3D-printable cases for the CYD on MakerWorld:

- [Vertical: Aura Display Case](https://makerworld.com/de/models/1382304-aura-smart-weather-forecast-display?from=search#profileId-1430975)
- [Desk Stand with ESP32 CYD](https://makerworld.com/de/models/609280-desk-stand-for-xtouch-with-esp32-cyd-jc2432w328?from=search#profileId-532299)

## Build from Source

### ESP32 Firmware

```bash
# Install PlatformIO, then:
pio run
pio run -e esp32dev -t upload
pio device monitor
```

Firmware targets:

- `esp32dev`: ILI9341 / R-board build
- `esp32dev-st7789`: ST7789 / Hybrid-board build

### Installer Binaries

```bash
./scripts/build_firmware.sh
```

This merges the bootloader, partitions, app image, and boot app into browser-flashable binaries under `installer/bin/`, then updates the installer manifests. It requires PlatformIO CLI and `esptool.py`.

### Mac Companion App

```bash
cd companion-v2
./build.sh
```

The current Mac app lives in `companion-v2/` and is built with Swift, AppKit, POSIX serial I/O, and GitHub Releases update checks. The older `companion/` app is kept only as historical reference.

## Release Flow

- Firmware releases use tags like `v2.11.3`.
- Mac app releases use tags like `app-v1.17.1`.
- Pushes to `main` that touch firmware or installer files build and deploy the GitHub Pages installer.
- Firmware tags build release assets for both ILI9341 and ST7789 variants.
- App tags build `AIMonitor.zip` and `AIMonitor.dmg` via the macOS workflow.

## Tech Stack

| Component | Stack |
|-----------|-------|
| ESP32 Firmware | PlatformIO, Arduino-ESP32, TFT_eSPI, LVGL v9, ArduinoJson |
| Mac App | Swift, AppKit, POSIX serial, GitHub Releases API |
| Data Source | CodexBar `widget-snapshot.json` |
| Installer | GitHub Pages, ESP Web Tools |

## Attribution

Chatbot icons created by [LAFS - Flaticon](https://www.flaticon.com/)
