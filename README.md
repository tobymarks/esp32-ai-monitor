# ESP32 AI Usage Monitor

Dashboard for AI token usage metrics on an ESP32-2432S028R (CYD 2.8").

## Web Installer

Flash the firmware directly from your browser (Chrome/Edge):

**[Open Installer](https://tobiasmarks.github.io/esp32-ai-monitor/)**

No tools required -- just a USB cable and a compatible browser.

## Hardware

- **Board:** ESP32-2432S028R (Cheap Yellow Display)
- **Display:** 2.8" ILI9341 (320x240, SPI)
- **Touch:** XPT2046 resistive (HSPI)
- **MCU:** ESP32-WROOM-32

## Setup

1. Install [PlatformIO](https://platformio.org/)
2. Clone this repo
3. Build and flash:

```bash
pio run -t upload
pio device monitor
```

## Build Installer Binary

To build the merged firmware binary for the web installer:

```bash
./scripts/build_firmware.sh
```

This runs `pio run`, merges all partitions into a single `installer/bin/ai-monitor.bin`, and updates the manifest version automatically.

Requirements: PlatformIO CLI, esptool.py (`pip install esptool`)

## Features

- AI token usage dashboard (Anthropic, OpenAI)
- Real-time cost tracking
- Usage charts and history
- WiFi config via captive portal (WiFiManager)
- Web-based config portal (API keys, display settings)
- OTA updates

## Stack

- PlatformIO + Arduino framework
- TFT_eSPI (display driver)
- LVGL v9 (UI toolkit)
- ArduinoJson (API parsing)
- WiFiManager (WiFi provisioning)
- ESPAsyncWebServer (config portal)

## CI/CD

Push to `main` with changes in `src/` or `platformio.ini` triggers a GitHub Actions workflow that builds the firmware and deploys the installer to GitHub Pages automatically.
