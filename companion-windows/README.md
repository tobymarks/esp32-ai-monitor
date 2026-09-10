# AI Monitor für Windows (companion-windows)

Tauri-2-App mit Rust-Backend und React/TypeScript-Frontend. Phase 1 nach
`docs/windows-app-plan.md`: Tray-Icon mit Provider-Menü, Einstellungsfenster,
CodexBar-Abruf über das Core-Crate. Serial, Display und Updates folgen in
Phase 2 und 3.

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
`cargo build` baut den Workspace, `cargo test -p aimonitor-core` testet die
Fachlogik. `cargo tauri build` erzeugt das Bundle.

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
    pages/              Übersicht, Diagnose, Platzhalter
    i18n/               de.json, en.json (Schlüssel aus companion/Resources)
    format.ts           Countdown und „aktualisiert vor"
    styles.css          Tokens aus installer/assets/site.css, Light und Dark
  src-tauri/            Tauri-Hülle (Rust)
    src/lib.rs          Builder, Plugins, Setup, Run-Loop
    src/state.rs        AppState (Source, Settings, Tray)
    src/settings.rs     settings.json unter app_config_dir()
    src/poll.rs         Abrufzyklus (POLL_INTERVAL, spawn_blocking)
    src/commands.rs     Tauri-Commands fürs Frontend
    src/tray.rs         Tray-Icon, Menü, Tooltip
    src/window.rs       Einstellungsfenster
    tauri.conf.json, capabilities/default.json, icons/
  crates/core/          aimonitor-core: Provider, CodexBar-Parsing, Zeilenregeln
  fixtures/codexbar/    Win-CodexBar-Fixtures (Aufnahme unter Windows)
```

Einstellungen liegen unter macOS in
`~/Library/Application Support/de.aimonitor.companion/settings.json`, unter
Windows in `%APPDATA%\de.aimonitor.companion\settings.json`.
