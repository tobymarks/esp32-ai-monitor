# AI Monitor

A macOS or Windows companion app plus an ESP32 desk display for keeping AI usage limits visible while you work. It reads Claude, ChatGPT, Antigravity, Gemini, Copilot, or Cursor usage through the local CodexBar CLI, then streams the current limits to a small USB-connected CYD display.

Usage data travels only over USB: the ESP32 needs no Wi-Fi, never sees cloud credentials, and there is no browser tab to keep open.

## How It Works

The **AI Monitor** app on your Mac or Windows PC periodically asks the locally installed CodexBar CLI for the selected provider, applies your display settings, and sends a compact JSON frame over USB serial to the ESP32. The ESP32 renders the dashboard on the 2.8" color display.

```text
AI providers -> CodexBar CLI -> AI Monitor app (macOS / Windows) -> USB serial -> ESP32 CYD display
```

The Mac app can also flash firmware, check GitHub Releases for app and firmware updates, and remember per-device display settings.

### Display plugins (in development)

The companion apps can install declarative `.aimplugin` files from disk or an
HTTPS release URL. Each installed plugin appears as a placeable window in the
display manager. Plugins can define separate portrait, landscape, and square
layouts; the built-in AI dashboards remain the main purpose of the device.
The desktop fetches plugin data and
sends bounded drawing scenes to firmware with `sceneProtocol: 1`. Install that
firmware once; installing another compatible plugin does not require flashing
again. Plugins in this format contain no executable code, and the app shows
their data origin and unsigned status before installation. See the
[plugin architecture](docs/display-plugins.md), [authoring guide](docs/display-plugin-authoring.md),
and [acceptance test](docs/display-plugin-test.md).

## Features

- Provider views for Claude, ChatGPT, Antigravity, Gemini CLI, GitHub Copilot, and Cursor
- Session, weekly, and provider-specific usage rows where available (including Claude Fable)
- Centered circular ChatGPT display when only one limit is available, in portrait and landscape
- Antigravity model rows for Claude, Gemini Pro, and Gemini Flash; Gemini CLI rows for Pro, Flash, and Flash Lite; Cursor rows for plan, auto, and API usage
- Copilot premium-request quota as a single centered ring
- Used or remaining percentage display mode
- Live reset countdowns and local display clock
- Optional cost/extra-usage support when supplied by the provider data
- ChatGPT/Codex header badges for workspace extra credits and reset credits (see below)
- Automatic USB serial detection and instant resend on connect
- Per-device settings for orientation, theme, language, brightness, timezone, and board variant
- Portrait plus left/right landscape layouts
- Firmware flashing for ILI9341 and ST7789 CYD variants
- Optional menu bar quick menu for provider switching
- Optional Wi-Fi on the display, used only to keep the standby clock accurate via NTP while the app is not connected

### ChatGPT Header Badges

Since firmware 2.18.0 (Mac app 1.28.3, Windows app 1.0.1) the ChatGPT view can show small badges next to the provider name:

- **`+Cr`** (green): the ChatGPT workspace has purchased extra credits, so you can keep working once your limit is used up. Owners and admins see the balance instead, for example `+238` or `+2.5k`. OpenAI does not share the workspace balance with other members, so they only see `+Cr`.
- **Arrow icon with a number** (grey): available Codex reset credits. Each one resets your Codex limit early, once. They belong to your own account and you redeem them yourself in the Codex app or the Codex IDE extension; no admin is needed. CodexBar shows when they expire.

Without these badges the account reports neither. In portrait the header is narrow, so the reset-credit badge may be left out.

## Quick Start

1. **Buy** an [ESP32-2432S028 / ESP32-2432S028R board](https://de.aliexpress.com/item/1005007731775734.html), also known as a Cheap Yellow Display.
2. **Install [CodexBar](https://codexbar.app/)** so its local CLI is available.
3. **Download** the AI Monitor app from [GitHub Releases](https://github.com/tobymarks/esp32-ai-monitor/releases): the Mac app (`app-v*`), or the Windows app (`win-v*`).
4. **Plug** the ESP32 into your computer via a USB data cable.
5. **Flash** the right firmware variant and choose the provider in the AI Monitor settings window.

A step-by-step build guide with photos is on [Hackster.io](https://www.hackster.io/toby-marks/esp32-desk-display-for-claude-and-chatgpt-usage-limits-71d7e3).

## Requirements

- macOS 14+ on Apple Silicon or Intel (the app ships as a universal binary), or Windows 10/11 x64 for the Windows app
- [CodexBar](https://codexbar.app/) installed with its local CLI; on Windows [Win-CodexBar](https://github.com/nesszer/Win-CodexBar) (`winget install Finesssee.Win-CodexBar`), whose `codexbar-cli.exe` provides the same data
- Windows only: a driver for the CYD's CH340 USB-serial chip if Windows does not install it automatically
- Windows only: the installer is not code-signed yet, so Windows SmartScreen warns on first launch. Choose "More info", then "Run anyway"
- At least one of Claude, ChatGPT, Antigravity, Gemini, Copilot, or Cursor set up in CodexBar
- ESP32-2432S028 / ESP32-2432S028R CYD board
- USB data cable, not a charge-only cable
- Optional: PlatformIO if you want to build or flash the firmware manually

## CodexBar Dependency

AI Monitor does not talk to any AI service directly. CodexBar is the required local data source: its CLI obtains the provider limits that AI Monitor sends to the desk display.

Install CodexBar first:

- Website: [codexbar.app](https://codexbar.app/)
- Repository: [steipete/CodexBar](https://github.com/steipete/CodexBar)
- Latest download: [CodexBar GitHub Releases](https://github.com/steipete/CodexBar/releases/latest)
- Homebrew: `brew install --cask steipete/tap/codexbar`

After CodexBar is running, enable the providers you want there. AI Monitor will then offer Claude, ChatGPT, Antigravity, Gemini, Copilot, and Cursor as display sources.

## Hardware

Supported board family:

- **ESP32-2432S028R / R board:** ILI9341 display controller
- **ESP32-2432S028 / Hybrid board:** ST7789 display controller
- **Guition ESP32-S3-4848S040:** 480×480 ST7701 display controller

CYD hardware:

- **Display:** [ESP32-2432S028 2.8" 320x240 TFT](https://de.aliexpress.com/item/1005007731775734.html)
- **Touch:** XPT2046
- **MCU:** ESP32-WROOM-32
- **Backlight:** GPIO 21

If a CYD stays white or shows noise after flashing, flash the other CYD panel variant from the AI Monitor app. Select the ST7701 image only for the Guition S3 board.

## Enclosures

3D-printable cases for the CYD on MakerWorld:

- [Landscape: Weather Station Pro for ESP32-2432S028 CYD](https://makerworld.com/de/models/2583102-weather-station-pro-anemometer-esp32-2432s028-cyd#profileId-2849155)
- [Portrait: Aura Smart Weather Forecast Display](https://makerworld.com/de/models/1382304-aura-smart-weather-forecast-display?from=search#profileId-1430951)

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
- `esp32s3-4848s040`: ST7701 / Guition S3 square build

### Installer Binaries

```bash
./scripts/build_firmware.sh
```

This merges the bootloader, partitions, app image, and boot app into browser-flashable binaries under `installer/bin/`, then updates the installer manifests. It requires PlatformIO CLI and `esptool.py`.

### Mac Companion App

```bash
cd companion
./build.sh
```

The supported Mac app source lives in `companion/` and is built with Swift, AppKit, POSIX serial I/O, and GitHub Releases update checks.

### Windows Companion App

```bash
cd companion-windows
pnpm install
cargo tauri dev
```

The Windows app lives in `companion-windows/` and is built with Tauri 2 (Rust backend, React frontend). The Rust workspace holds the shared logic (`crates/core`), the serial link (`crates/serial`) and the firmware flasher over the espflash library (`crates/flash`); everything builds and runs on macOS too for development. See `companion-windows/README.md` for the fixture mode and developer switches, and `docs/windows-app-plan.md` for the implementation plan and status.

## Release Flow

- Firmware releases use tags like `v2.11.4`.
- Mac app releases use tags like `app-v1.17.1`.
- Windows app releases use tags like `win-v1.0.0`; betas use `win-beta-v*` and are marked as prereleases.
- Pushes to `main` that touch firmware or installer files build and deploy the GitHub Pages installer.
- Firmware tags build release assets for ILI9341, ST7789, and ST7701 variants.
- App tags build `AIMonitor.zip` and `AIMonitor.dmg` via the macOS workflow.
- Windows tags build `AIMonitor-Setup.exe` plus a `.sha256` sidecar via the Windows workflow (Tauri NSIS bundler, silent install smoke test).
- App release assets are signed with a Developer ID, notarized by Apple and stapled,
  so they open without a Gatekeeper warning. The workflow creates the release and
  attaches both files; no local build is required.

## Tech Stack

| Component | Stack |
|-----------|-------|
| ESP32 Firmware | PlatformIO, Arduino-ESP32, TFT_eSPI, LVGL v9, ArduinoJson |
| Mac App | Swift, AppKit, POSIX serial, GitHub Releases API |
| Windows App | Tauri 2, Rust (serialport, espflash), React, GitHub Releases API |
| Data Source | Local CodexBar CLI (macOS), Win-CodexBar CLI (Windows); explicit HTTPS JSON sources for display plugins |
| Website | GitHub Pages |

## License

AI Monitor is released under the [MIT License](LICENSE).

The MIT License covers everything in this repository, including the app icon,
menu bar icon and website artwork, which are original work made for this
project. See [NOTICE](NOTICE) for third-party components and their licenses.

## Attribution

- Firmware built with [TFT_eSPI](https://github.com/Bodmer/TFT_eSPI) (MIT/BSD), [LVGL](https://github.com/lvgl/lvgl) (MIT) and [ArduinoJson](https://github.com/bblanchon/ArduinoJson) (MIT)
- Usage data provided by [CodexBar](https://github.com/steipete/CodexBar), a separate program invoked at runtime
- Inspired by [Aura](https://github.com/Surrey-Homeware/Aura), a weather display for the same CYD hardware

Full third-party license details are in [NOTICE](NOTICE).
