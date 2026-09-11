# AI Monitor für Windows (companion-windows)

Tauri-2-App mit Rust-Backend und React/TypeScript-Frontend. Stand nach
Phase 3 von `docs/windows-app-plan.md`: Tray-Icon mit Provider-Menü,
Einstellungsfenster mit Übersicht, Verbindung, Display, Updates und Diagnose,
CodexBar-Abruf über das Core-Crate, USB-Serial-Verbindung zur CYD mit
Handshake, Datenframes mit ACK, Geräteprofilen und Display-Einstellungen,
Release-Prüfung gegen GitHub, Firmware-Download und Flash über `espflash`,
App-Update mit SHA-256-Prüfung.

## Voraussetzungen

- Rust stable (Cargo) und `cargo tauri` (tauri-cli 2): `cargo install tauri-cli --version "^2"`
- Node 20 oder neuer und pnpm 10
- Windows: WebView2 (Windows 11 bringt es mit), Win-CodexBar für echte Daten
- macOS (Entwicklung): Xcode Command Line Tools

## Entwickeln

```sh
pnpm install
cargo tauri dev
```

Die App startet ohne Fenster im Tray. Linksklick auf das Tray-Icon oder
„Einstellungen…" im Menü öffnet das Fenster; Schließen versteckt es nur,
„Beenden" beendet die App.

`pnpm build` prüft die Typen und baut das Frontend nach `dist/`,
`cargo build` baut den Workspace, `cargo test --workspace` testet alle
Crates. `cargo tauri build` erzeugt das Bundle.

Umgebungsvariablen für die Entwicklung:

| Variable | Wirkung |
|---|---|
| `AIMONITOR_OPEN_SETTINGS=1` | Öffnet das Einstellungsfenster sofort beim Start. |
| `AIMONITOR_CODEXBAR_FIXTURE_DIR=<dir>` | Provider aus `<provider>.json` bedienen statt über das CLI (siehe Fixture-Modus). |
| `AIMONITOR_OPEN_PAGE=<seite>` | Startseite des Fensters: `overview`, `connection`, `display`, `updates`, `diagnostics`. |
| `AIMONITOR_DEV_ACTION=check\|download\|flash` | Führt beim Start einmal `check_updates`, `download_firmware` oder `flash_firmware` aus und schreibt das Ergebnis ins Log (`flash` wartet bis zu 60 s auf ein Gerät). Variante über `AIMONITOR_DEV_VARIANT=ili9341\|st7789`. |

Strg+C oder SIGTERM beenden die App wie „Beenden" im Tray: `standby` ans
Gerät, Port schließen, dann Exit.

## Serielle Verbindung

Der Thread `aimonitor-serial` in `src-tauri/src/serial_service.rs` besitzt
den Port allein und arbeitet die Abläufe aus `docs/serial-protocol.md`
(Abschnitte 6 und 7) ab: Port-Scan alle 3 s, Handshake mit `get_info`,
Fremd-Firmware nach 5 s ohne Antwort (8 s Fenster für eine späte `info`),
nach dem Connect `set_theme`, `set_language`, `set_orientation`,
`set_brightness` aus dem Geräteprofil und ein gebündelter Datenframe.
Datenframes gehen bei jedem neuen Snapshot, Provider-, Einstellungs- und
Profilwechsel über einen 120-ms-Debounce, dazu ein Heartbeat alle 60 s.
Drei unbestätigte Frames in Folge lösen einen Reconnect aus (Abkühlung 60 s).

Der Zustand geht als `ConnectionSnapshot` über das Event
`connection-changed` ans Frontend (Zustand, Port, `info`, Profil, letzter
Receipt, Zähler, Protokoll). Geräteprofile liegen als `devices.json` neben
`settings.json`.

Commands fürs Frontend (`src-tauri/src/commands.rs`):

| Command | Zweck |
|---|---|
| `get_snapshot`, `set_provider`, `refresh` | Datenquelle (Phase 1) |
| `get_settings`, `set_settings`, `list_providers`, `rescan_cli`, `open_settings` | Einstellungen (Phase 1) |
| `get_connection` | Aktueller `ConnectionSnapshot` |
| `list_ports` | USB-Serial-Ports mit VID/PID und Chip |
| `set_manual_port(port)` | Fester Port oder `null` für automatisch |
| `get_devices` | Alle Geräteprofile |
| `rename_device(mac, name)` | Umbenennen; Fehler als Schlüssel `disp.name.err.*` |
| `update_profile(mac, theme, orientation, language)` | Profil setzen, geänderte `set_*` ans Gerät |
| `set_brightness(value, persist)` | 5..100; `persist:false` als Vorschau beim Ziehen |
| `get_timezones`, `set_timezone(timezone)` | `auto` oder IANA-Name, mit aktuellem Offset |
| `send_diagnostic_frame` | Testframe, nach 20 s wieder der echte Snapshot |
| `check_updates(force)` | Releases von GitHub laden (`force:false` nimmt den Cache); Ergebnis `UpdateStatus` |
| `get_update_status` | `UpdateStatus` aus dem Cache ohne Netzzugriff |
| `download_firmware(variant)` | Firmware-Asset nach `app_data_dir()/firmware/` laden, Event `firmware-download` |
| `flash_firmware(variant)` | Serial-Service anhalten, Image mit `aimonitor-flash` schreiben, fortsetzen; Event `flash-progress` |
| `install_app_update` | `AIMonitor-Setup.exe` laden, SHA-256 prüfen, mit `/SILENT` starten; sonst Browser. Event `update-progress` |
| `open_release_page` | Release-Seite im Browser |

## Updates und Firmware-Flash

`src-tauri/src/updates.rs` lädt die Releases über `ureq` (User-Agent
`AI-Monitor-Windows/<Version>`, Timeout 15 s), 10 s nach dem Start und
danach alle 6 h, dazu auf Knopfdruck. Parallele Prüfungen warten auf die
laufende. Der Kanal (`updateChannel`: stable oder beta) liegt in den
Einstellungen; die Auswahl je Kanal macht `aimonitor_core::release`.
Nach jeder Prüfung geht `updates-changed` mit dem `UpdateStatus` ans Frontend.

`src-tauri/src/flash.rs` setzt Spec 6.4 um: Port der aktiven Verbindung
merken, `Job::Pause` an den Serial-Thread (trennen, Scan stoppen, Port
schließen, Bestätigung), 500 ms warten, `flash_image` mit 460800 Baud in
`spawn_blocking`, dann `Job::Resume { diagnostic_after_connect }`. Nach dem
nächsten Connect geht 1 s später der Diagnose-Frame raus, nach 20 s wieder
der echte Snapshot. Bei Erfolg landen Variante im Geräteprofil und
`installedFirmwareVersion` in den Einstellungen. Fehler kommen als Event mit
`phase:"failed"` und den Schlüsseln `flash.err.*`. Gemessen an der CYD:
1,34 MB in 31 s inklusive Bootloader-Connect.

Firmware-Dateien liegen unter `app_data_dir()/firmware/<asset>-<tag>.bin`,
der Installer wird nach `%TEMP%\ai-monitor-update\` geladen.

## Fixture-Modus

Ohne CodexBar-CLI lassen sich Provider aus JSON-Dateien bedienen. Die Variable
zeigt auf ein Verzeichnis mit `<provider>.json`; nur Provider mit vorhandener
Datei werden ersetzt, die übrigen laufen über das echte CLI.

```sh
AIMONITOR_CODEXBAR_FIXTURE_DIR=$PWD/fixtures/codexbar/synthetic cargo tauri dev
```

`fixtures/codexbar/synthetic/` enthält synthetische Win-CodexBar-Antworten
(snake_case) für alle sechs Provider, `../companion/Fixtures/codexbar/` die
camelCase-Fixtures der Mac-App. Echte Windows-Aufnahmen gehören nach
`fixtures/codexbar/` (siehe README dort).

## Verzeichnisstruktur

```
companion-windows/
  Cargo.toml            Workspace: crates/core, crates/serial, crates/flash und src-tauri
  package.json          Frontend (Vite, React 18, TypeScript)
  index.html, vite.config.ts, tsconfig.json
  src/                  Frontend
    api.ts              Typen und invoke-Aufrufe gegen das Backend
    App.tsx             Navigation und Zustand (Snapshot, Settings, Event)
    pages/              Übersicht, Verbindung, Display, Updates, Diagnose
    i18n/               de.json, en.json (Schlüssel aus companion/Resources)
    format.ts           Countdown und „aktualisiert vor"
    styles.css          Tokens aus installer/assets/site.css, Light und Dark
  src-tauri/            Tauri-Hülle (Rust)
    src/lib.rs          Builder, Plugins, Setup, Run-Loop
    src/state.rs        AppState (Source, Settings, Tray)
    src/settings.rs     settings.json unter app_config_dir()
    src/poll.rs         Abrufzyklus (POLL_INTERVAL, spawn_blocking)
    src/commands.rs     Tauri-Commands fürs Frontend
    src/serial_service.rs Serial-Thread: Scan, Handshake, Frames, ACK-Buchführung, Pause/Resume
    src/updates.rs      Release-Abfrage, Firmware-Download, App-Update
    src/flash.rs        Flash-Ablauf mit Pause/Resume des Serial-Threads
    src/registry.rs     devices.json (Geräteprofile) unter app_config_dir()
    src/timezone.rs     Zeitzonenliste und Offset für displayTime
    src/tray.rs         Tray-Icon, Menü, Tooltip mit Verbindungszustand
    src/window.rs       Einstellungsfenster
    tauri.conf.json, capabilities/default.json, icons/
  crates/core/          aimonitor-core: Provider, CodexBar-Parsing, Zeilenregeln, Protokoll
  crates/serial/        aimonitor-serial: Port-Suche, Link, Handshake, Frames
  crates/flash/         aimonitor-flash: Image über espflash schreiben
  fixtures/codexbar/    Win-CodexBar-Fixtures (Aufnahme unter Windows)
```

Einstellungen und Geräteprofile liegen unter macOS in
`~/Library/Application Support/de.aimonitor.companion/` (`settings.json`,
`devices.json`), unter Windows in `%APPDATA%\de.aimonitor.companion\`.
