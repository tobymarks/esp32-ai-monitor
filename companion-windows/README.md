# AI Monitor für Windows (companion-windows)

Tauri-2-App mit Rust-Backend und React/TypeScript-Frontend. Stand nach
Phase 2 von `docs/windows-app-plan.md`: Tray-Icon mit Provider-Menü,
Einstellungsfenster mit Übersicht, Verbindung, Display und Diagnose,
CodexBar-Abruf über das Core-Crate, USB-Serial-Verbindung zur CYD mit
Handshake, Datenframes mit ACK, Geräteprofilen und Display-Einstellungen.
Firmware-Flash und Updates folgen in Phase 3.

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
  Cargo.toml            Workspace: crates/core und src-tauri
  package.json          Frontend (Vite, React 18, TypeScript)
  index.html, vite.config.ts, tsconfig.json
  src/                  Frontend
    api.ts              Typen und invoke-Aufrufe gegen das Backend
    App.tsx             Navigation und Zustand (Snapshot, Settings, Event)
    pages/              Übersicht, Verbindung, Display, Diagnose, Platzhalter
    i18n/               de.json, en.json (Schlüssel aus companion/Resources)
    format.ts           Countdown und „aktualisiert vor"
    styles.css          Tokens aus installer/assets/site.css, Light und Dark
  src-tauri/            Tauri-Hülle (Rust)
    src/lib.rs          Builder, Plugins, Setup, Run-Loop
    src/state.rs        AppState (Source, Settings, Tray)
    src/settings.rs     settings.json unter app_config_dir()
    src/poll.rs         Abrufzyklus (POLL_INTERVAL, spawn_blocking)
    src/commands.rs     Tauri-Commands fürs Frontend
    src/serial_service.rs Serial-Thread: Scan, Handshake, Frames, ACK-Buchführung
    src/registry.rs     devices.json (Geräteprofile) unter app_config_dir()
    src/timezone.rs     Zeitzonenliste und Offset für displayTime
    src/tray.rs         Tray-Icon, Menü, Tooltip mit Verbindungszustand
    src/window.rs       Einstellungsfenster
    tauri.conf.json, capabilities/default.json, icons/
  crates/core/          aimonitor-core: Provider, CodexBar-Parsing, Zeilenregeln, Protokoll
  crates/serial/        aimonitor-serial: Port-Suche, Link, Handshake, Frames
  fixtures/codexbar/    Win-CodexBar-Fixtures (Aufnahme unter Windows)
```

Einstellungen und Geräteprofile liegen unter macOS in
`~/Library/Application Support/de.aimonitor.companion/` (`settings.json`,
`devices.json`), unter Windows in `%APPDATA%\de.aimonitor.companion\`.
