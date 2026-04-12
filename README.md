# AI Monitor

A Mac menubar app + ESP32 desk display that shows your Claude Pro/Max subscription usage limits in real-time. Session limits, weekly limits, and cost tracking -- always visible on your desk.

## How It Works

The **AI Monitor** Mac menubar app reads your Claude OAuth token from the macOS Keychain (Claude Code credentials), polls `api.anthropic.com/api/oauth/usage` every 60 seconds, and sends the data via USB serial to the ESP32. The ESP32 with its 2.8" color display renders the dashboard. No WiFi needed -- just USB.

```
Claude API  -->  Mac Menubar App  --USB-->  ESP32 CYD Display
```

## Features

- Session limit (5h window) with progress bar and reset countdown
- Weekly limit with progress bar and reset countdown
- Extra usage / cost tracking ($used / $limit)
- Splash screen with spinner while waiting for data
- 1-minute polling, aligned to full minutes
- Automatic USB detection and instant data on connect
- Rate limit handling with exponential backoff
- Portrait and landscape display orientation

## Quick Start

1. **Buy** the ESP32-2432S028R board (~$8 on [AliExpress](https://de.aliexpress.com/item/1005007731775734.html))
2. **Flash** firmware via the [Web Installer](https://tobymarks.github.io/esp32-ai-monitor/) or PlatformIO
3. **Download** the AI Monitor Mac app
4. **Plug** the ESP32 into your Mac via USB -- done!

## Requirements

- macOS 13+ (Apple Silicon)
- Claude Pro or Max subscription
- Claude Code CLI installed (provides the OAuth token in Keychain)

## Hardware

- **Board:** [ESP32-2432S028R](https://de.aliexpress.com/item/1005007731775734.html) (Cheap Yellow Display, ~$8)
- **Display:** 2.8" ILI9341 (320x240, SPI)
- **MCU:** ESP32-WROOM-32

## Enclosures

3D-printable cases for the CYD on MakerWorld:

- [Vertical: Aura Display Case](https://makerworld.com/de/models/1382304-aura-smart-weather-forecast-display?from=search#profileId-1430975)
- [Desk Stand with ESP32 CYD](https://makerworld.com/de/models/609280-desk-stand-for-xtouch-with-esp32-cyd-jc2432w328?from=search#profileId-532299)

## Build from Source

### ESP32 Firmware

```bash
# Install PlatformIO, then:
pio run -t upload
pio device monitor
```

### Installer Binary

```bash
./scripts/build_firmware.sh
```

Merges all partitions into `installer/bin/ai-monitor.bin` and updates the manifest version. Requires PlatformIO CLI and esptool.py (`pip install esptool`).

### Mac Companion App

The companion app is in `companion-v2/` and built with Swift (AppKit, Keychain Services, POSIX serial).

## Tech Stack

| Component | Stack |
|-----------|-------|
| ESP32 | PlatformIO, TFT_eSPI, LVGL v9, ArduinoJson |
| Mac App | Swift, AppKit, Keychain Services, POSIX serial |

## CI/CD

Push to `main` with changes in `src/` or `platformio.ini` triggers a GitHub Actions workflow that builds the firmware and deploys the installer to GitHub Pages automatically.

## Attribution

Chatbot icons created by [LAFS - Flaticon](https://www.flaticon.com/)
