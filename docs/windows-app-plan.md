# AI Monitor für Windows – Umsetzungsplan

Stand: 11. September 2026. Bezug: Mac-App 1.28.0, Firmware 2.17.0.

## Ziel

Eine native Windows-App, die dasselbe tut wie die Mac-App: Provider-Limits über die
CodexBar-CLI lesen, als AIM1-Frames per USB-Serial an die CYD senden, Firmware flashen,
Geräteprofile verwalten, sich selbst aktualisieren. Firmware und Protokoll bleiben
unverändert.

## Ausgangslage

- Die Mac-App ist reines AppKit/Swift (rund 7.800 Zeilen), nichts davon läuft unter
  Windows. Portierbar ist die Fachlogik: Provider-Modelle, CodexBar-Parsing,
  AIM1-Protokoll, Geräteprofile.
- Datenquelle unter Windows ist [Win-CodexBar](https://github.com/nesszer/Win-CodexBar),
  ein Rust/Tauri-Rewrite von CodexBar (MIT, aktiv, winget). Die mitgelieferte
  `codexbar-cli.exe` unterstützt `usage -p <provider> --json` für alle sechs Provider,
  auch Cursor. Installationspfad: `%LOCALAPPDATA%\Programs\CodexBar\codexbar-cli.exe`.
- Das JSON von Win-CodexBar ist **nicht** feldgleich mit dem Upstream: snake_case
  (`used_percent`, `resets_at`, `window_minutes`, `updated_at`, `extra_rate_windows`)
  statt camelCase, Fehler als String statt Objekt. Struktur, Provider-Namen und
  Zusatzfenster (`id`, `title`, `window`) stimmen überein.

## Entscheidungen

Punkt 1 ist entschieden (10. September 2026). Die Punkte 2 bis 5 und 7 sind als Annahme
gesetzt und werden in Phase 0 bestätigt. Punkt 6 ist offen.

| Nr. | Thema | Entscheidung |
|---|---|---|
| 1 | Stack | **Entschieden: Tauri 2** mit Rust-Backend und React/TypeScript-Frontend. Gründe: `serialport`-Crate mit VID/PID-Enumeration und expliziter DTR/RTS-Steuerung, Flashen über die `espflash`-Crate ohne Fremdbinary, Win-CodexBar als Vorlage für Tray, Autostart, Installer und CI, Linux ohne zweiten Port, Oberfläche im Design der Installer-Seite (Plus Jakarta Sans, gleiche Tokens). Verworfen: C#/WPF (Windows-only, esptool als Subprozess), Avalonia (nirgends nativ), Electron, Flutter, Python/Qt. Bekannte Kosten: zwei Sprachen, Borrow-Checker-Lernkurve, WebView2-Abhängigkeit. |
| 2 | Verzeichnis | `companion-windows/` neben `companion/`. Mac-Build, CI und Skripte bleiben unangetastet. |
| 3 | Versionierung | Eigene Linie ab 1.0.0. Tags `win-v*` und `win-beta-v*`. Der Mac-Updater filtert auf `app-v`/`app-beta-v` und ignoriert Windows-Releases damit automatisch. |
| 4 | Release-Assets | `AIMonitor-Setup.exe` plus `.sha256`. Portable-Variante später, falls gewünscht. |
| 5 | Datenquelle | Win-CodexBar-CLI per Prozessaufruf, Suchreihenfolge: Installationspfad, dann `PATH`. Mapping-Schicht snake_case auf internes Modell. |
| 6 | Signierung | **Offen.** Optionen: Azure Trusted Signing (kostenpflichtig, Identitätsprüfung, kein SmartScreen-Aufbau nötig), SignPath Foundation (kostenlos für Open Source, Antrag), unsigniert mit SHA-256 (SmartScreen warnt). Empfehlung: Azure Trusted Signing beantragen, erste Betas unsigniert. |
| 7 | Systemvoraussetzungen | Windows 10 1809+ oder 11, x64. WebView2 wird vom Installer nachgezogen. ARM64 nicht im ersten Release. |

## Phase 0 – Vorarbeiten und Spikes

Aufwand: 2 bis 3 Tage.

1. **Testumgebung.** Windows-VM mit USB-Passthrough (Parallels) oder physischer PC.
   CYD anstecken, COM-Port und CH340/CP2102-Treiber prüfen.
2. **Fixtures.** Win-CodexBar installieren und für `claude`, `codex`, `antigravity`,
   `gemini`, `copilot`, `cursor` je einmal ausführen:
   `codexbar-cli usage -p <provider> -f json --pretty`. Ausgaben unter
   `companion-windows/fixtures/codexbar/` ablegen. Zusätzlich je einen Fehlerfall
   (Provider nicht eingerichtet) aufnehmen.
3. **Protokoll-Spezifikation.** `docs/serial-protocol.md` aus `companion/Sources/main.swift`
   und `src/serial_receiver.*` ableiten: AIM1-Header `AIM1 <len> <frameId>\n`,
   Legacy-Zeilenmodus für Firmware unter 2.12.3, `info`-Handshake (MAC, Firmware-Version,
   Transport), Frame-ACK, Kommandos, Payload-Schema (`schemaVersion`, `provider`, `rows`,
   `usage`, `displayTime`, `tzOffsetMinutes`, `notice`, `fetching`, `source`, `sentAt`).
   Ergebnis: Die Windows-Implementierung braucht den Swift-Code nicht.
4. **Flashen mit `espflash`.** Die `espflash`-Crate gegen beide Firmware-Varianten
   (`ai-monitor.bin`, `ai-monitor-st7789.bin`, gemergte Images ab Offset 0) auf der CYD
   testen, inklusive Fortschrittsmeldung und Port-Freigabe. Fallback, falls die Crate
   die Images nicht sauber schreibt: `esptool-v5.4.0-windows-amd64.zip` als Sidecar,
   dann Defender-Verhalten mit dem PyInstaller-Binary prüfen.
5. **Port-Öffnen ohne Reset.** Windows toggelt DTR/RTS beim Öffnen, der ESP32 resettet
   dann. Festlegen, wie die App DTR/RTS setzt und welchen Boot-Delay sie einhält
   (Mac: 200 ms nach `open`).
6. **Claude-Quelle.** Prüfen, ob `--source cli` oder `oauth` dieselben Zahlen liefert wie
   die Mac-App, da Win-CodexBar für Claude Browser-Cookies bevorzugt.
7. Entscheidungen 1 bis 7 bestätigen.

### Stand Phase 0 (10. September 2026)

| Punkt | Status | Ergebnis |
|---|---|---|
| 1 Testumgebung | offen | Braucht einen Windows-Rechner oder eine VM mit USB-Passthrough. |
| 2 Fixtures | vorbereitet | `companion-windows/fixtures/codexbar/` mit README und `collect_fixtures.ps1`. Das Skript findet die CLI, nimmt alle sechs Provider plus Fehlerfälle auf, maskiert Konto-E-Mail und Organisation und legt die CLI-Version ab. Aufnahme selbst steht aus (Windows). |
| 3 Protokoll-Spezifikation | **erledigt** | `docs/serial-protocol.md`, 780 Zeilen, jede Aussage mit Zeilenverweis auf Swift- oder Firmware-Code. Enthält Transportparameter, AIM1-Framing und Legacy-Modus, alle Nachrichten in beide Richtungen mit Beispielen, sechs Abläufe, Timeout-Tabelle, Versionsmatrix und zwölf offene Punkte. Wichtigste Befunde für Windows: `time` muss exakt `YYYY-MM-DDTHH:MM:SSZ` sein, `usedPercent` trägt im Modus „remaining“ die Restprozente, `ok`-Antworten werden vom Mac nie gelesen und müssen jederzeit toleriert werden, Zeilentitel gehen ohne Transliteration ans Gerät. |
| 4 Flashen mit `espflash` | **bestätigt** | espflash 4.6.0 gegen das Board „Home“ (ESP32 rev. 3.1, 4 MB, CH340): `board-info` verbindet in rund 7 s, `write-bin 0x0` schreibt das gemergte Release-Image (1,34 MB) bei 460800 Baud in rund 26 s, danach Hard-Reset, die Mac-App verbindet sich wieder und meldet 2.17.0. Bibliotheks-API: `Flasher::connect`, `write_bin_to_flash(addr, data, progress)` mit `ProgressCallbacks`, Crate-Feature `serialport`. Der esptool-Sidecar ist damit nicht nötig. |
| 5 Port-Öffnen ohne Reset | analysiert, Windows-Test offen | Die CYD nutzt CH340 (VID `1A86`, PID `7523`) mit der üblichen Auto-Reset-Schaltung: Reset nur, wenn DTR und RTS verschieden sind. `serialport-rs` setzt unter Windows beim Öffnen `DTR_CONTROL_DISABLE` und bei `FlowControl::None` auch `RTS_CONTROL_DISABLE`, beide Leitungen sind also gleich. Rezept: `serialport::new(port, 115200).flow_control(FlowControl::None)` ohne `dtr_on_open`, nach dem Öffnen DTR/RTS nicht anfassen, 200 ms warten, dann `get_info`. Empirisch auf Windows bestätigen, sobald Punkt 1 steht. |
| 6 Claude-Quelle | offen | Braucht Windows mit eingerichtetem Claude-Konto. |
| 7 Entscheidungen | teilweise | 1 entschieden. 2 bis 5 und 7 unverändert als Annahme. Punkt 4 der Spikes bestätigt den espflash-Teil von Entscheidung 1. |

Nebenbefund: `installer/bin/` ist nicht versioniert, CI baut die Binaries selbst. Ein lokaler
Stand kann veraltet sein (hier: 2.12.4 von Juni). Die Windows-App lädt Firmware wie geplant
aus GitHub Releases, nie aus dem Arbeitsverzeichnis.

## Phase 1 – Grundgerüst und Datenquelle

Aufwand: 4 bis 5 Tage.

- Tauri-Projekt in `companion-windows/`. Tray-Icon, kein Fenster beim Start,
  Settings-Fenster als Rahmen, Autostart per Registry-Run-Key, Lokalisierung de/en
  (Strings aus `companion/Resources/*.lproj` nach JSON übernehmen).
- Modul `codexbar`: Binary-Suche, Prozessaufruf mit 30 s Timeout, Poll alle 180 s,
  Stale-Schwelle 15 min, Fehler-String-Behandlung, Fixture-Modus wie in der Mac-App.
- Provider-Modell mit den Zeilenregeln aus `CodexBarSource.swift` und
  `SettingsWindow+Overview.swift`: Session/Weekly, Antigravity-Zusatzfenster,
  Gemini Pro/Flash/Flash Lite, Copilot Premium/Chat, Cursor Plan/Auto/API.
- Unit-Tests gegen die Windows-Fixtures. Schema-Test, der bei Feldänderungen der CLI
  bricht.

Ergebnis: Tray zeigt Provider-Werte, Provider-Umschaltung, Diagnose mit letztem
CLI-Output und CLI-Version.

### Stand Phase 1 (11. September 2026)

Auf dem Mac gebaut und gestartet, Windows-Lauf steht aus.

| Teil | Status | Ergebnis |
|---|---|---|
| Workspace | erledigt | `companion-windows/` mit Cargo-Workspace (`crates/core`, `src-tauri`), pnpm/Vite/React-Frontend, README, `.gitignore`. |
| Core-Crate `aimonitor-core` | erledigt | Provider-Modell, CLI-Parser für snake_case (Win-CodexBar) und camelCase (Upstream) mit Fehler als String oder Objekt, Zeilenregeln als Port von `buildUsageEnvelope`, Status, CLI-Suche und Prozessaufruf mit Timeout und ohne Konsolenfenster, Fixture-Modus über `AIMONITOR_CODEXBAR_FIXTURE_DIR`, zustandsbehaftete Quelle mit Cache je Provider. 26 Tests, darunter Schema-Tests gegen synthetische, Upstream- und (sobald vorhanden) echte Windows-Fixtures. |
| Tauri-Hülle | erledigt | Tray mit Provider-Menü, Aktualisieren, Einstellungen, Beenden; Tooltip mit erster Zeile; kein Fenster beim Start; Einstellungsfenster mit Übersicht, Diagnose und Platzhaltern für Verbindung, Display, Updates; Schließen versteckt nur; Autostart über `tauri-plugin-autostart`; Settings als JSON im App-Config-Verzeichnis; Lokalisierung de/en aus den Mac-Strings; Design mit den Tokens der Installer-Seite, hell und dunkel. |
| Abnahme | teilweise | `pnpm build`, `cargo build`, `cargo test` grün. Start mit echtem Upstream-CLI, mit Mac-Fixtures und mit synthetischen Fixtures geprüft, Fenster per Bildschirmfoto abgenommen. Nicht geprüft: Tray-Klicks, Windows-Build, Registry-Autostart. |

Offen für Windows: `collect_fixtures.ps1` ausführen und die echten Aufnahmen committen, dann
laufen die Schema-Tests dagegen. Entwickler-Schalter `AIMONITOR_OPEN_SETTINGS=1` öffnet das
Fenster beim Start.

## Phase 2 – Serial und Display

Aufwand: 5 bis 7 Tage.

- COM-Port-Enumeration mit VID/PID-Filter (CH340 `1A86:7523`, CP2102 `10C4:EA60`),
  Autoscan plus manuelle Auswahl, Hotplug-Erkennung.
- Transport nach `docs/serial-protocol.md`: AIM1-Framing, Legacy-Fallback,
  `info`-Handshake, Frame-ACK mit `frameId`, sofortiges Resend bei Verbindung.
- Payload-Builder identisch zur Mac-App.
- Geräteprofile pro MAC: Orientierung, Theme, Sprache, Helligkeit, Zeitzone,
  Board-Variante. Ablage unter `%APPDATA%\AI Monitor\`.
- Settings-Fenster mit den Bereichen Übersicht, Verbindung, Display, Diagnose.
- Hardware-Test gegen Firmware 2.17.0 und eine Version unter 2.12.3 für den
  Legacy-Modus.

Ergebnis: Display zeigt dieselben Werte wie am Mac, Orientierung und Theme wechseln
live.

### Stand Phase 2 (11. September 2026)

Auf dem Mac gegen das Board „Home" (Firmware 2.17.0, CH340) gebaut und getestet.

| Teil | Status | Ergebnis |
|---|---|---|
| Protokoll im Core | erledigt | `semver`, `protocol` (DeviceInfo/DeviceMessage-Parser, Kommandos, AIM1-Framing, Textregeln, alle Timeouts als Konstanten), `envelope` (Usage-, Notice-, Diagnose-Frame als Port von `buildUsageEnvelope`), `device` (Profile je MAC, Registry mit Legacy-Migration und Auto-Namen). 45 Tests. |
| Serial-Crate | erledigt | `crates/serial`: Port-Suche über `serialport::available_ports` mit VID/PID-Filter (CH340, CH9102, CP2102, FT232), natürliche Sortierung, Auswahlregel wie Mac; `Link` mit Öffnen nach dem Rezept aus Phase 0, Zeilenleser, drain, Handshake, Frame mit ACK, Kommando mit Antwort. `examples/probe` gegen das Gerät: Handshake in 285 ms, Diagnose-Frame 832 Bytes mit ACK in 117 ms. |
| Zustandsmaschine in der App | erledigt | `serial_service.rs`: Scan 3 s, Reconnect-Sperre, Handshake mit spätem info-Fenster, Profilauflösung, vier `set_*` nach Connect, Frames über 120-ms-Debounce, Heartbeat 60 s, ACK-Buchführung mit Auto-Reparatur, Diagnose-Frame mit Rückkehr, `standby` beim Beenden. Geräteregistry als `devices.json`, Zeitzone über `chrono-tz`, System-Theme über `dark-light`. |
| Seiten Verbindung und Display | gebaut | Verbindung: Zustand, Port-Auswahl, Gerätetabelle, letzter Frame, Zähler, Testframe, Protokoll. Display: Name, Orientierung, Theme, Sprache, Helligkeit mit Vorschau und Persist, Zeitzone. |
| Abnahme | teilweise | Log der App gegen das Gerät: Handshake 2.17.0, `set_theme/language/orientation/brightness` mit `ok`, Usage-Frame 746 Bytes mit ACK und 3 Zeilen, Heartbeat, `standby` beim Beenden, Port danach frei. Die Mac-App verbindet sich anschließend wieder normal. Nicht geprüft: die Seiten Verbindung und Display visuell (Bildschirmschoner aktiv), Legacy-Zeilenmodus mit Firmware unter 2.12.3, Fremd-Firmware-Pfad, COM-Enumeration unter Windows. |

Hinweis: Die Windows-App führt eine eigene Geräteregistry. Beim ersten Connect legt sie ein
neues Profil mit Standardwerten an und sendet `set_orientation portrait`; die Mac-App stellt
beim nächsten Connect ihre Werte wieder her. Entwickler-Schalter `AIMONITOR_OPEN_PAGE`
öffnet direkt eine Seite (overview, connection, display, updates, diagnostics).

## Phase 3 – Firmware-Flash und Updates

Aufwand: 3 bis 4 Tage.

- Flash über `espflash` im Rust-Backend, Fortschritt als Event ans Frontend, Port vor
  dem Flash freigeben. Nur bei Fallback aus Phase 0: esptool-Binary als Sidecar mit
  denselben Argumenten wie die Mac-App.
- Firmware-Download aus GitHub Releases (`ai-monitor.bin`, `ai-monitor-st7789.bin`),
  Variantenwahl.
- App-Update-Check über die Releases-API: Tags `win-v*`/`win-beta-v*`, Asset
  `AIMonitor-Setup.exe`, Download, SHA-256-Prüfung, stiller Start des Setups. Kanäle stable
  und beta.

Ergebnis: Beide Firmware-Varianten aus der App flashbar, Update von Beta zu Beta
funktioniert.

### Stand Phase 3 (11. September 2026)

| Teil | Status | Ergebnis |
|---|---|---|
| Release-Auswahl im Core | erledigt | `release.rs`: GitHub-Modelle, Auswahl je Kanal für Firmware (`v*`, `fw-beta-v*`) und Windows-App (`win-v*`, `win-beta-v*`), Asset-Zuordnung mit Fallback auf das Standard-Asset, Cache-Namen, SHA-256-Sidecar. |
| Flash-Crate | erledigt | `crates/flash`: `flash_image` über die espflash-Bibliothek, Fortschritt als Ereignisse (Connecting, Connected, Erasing, Writing mit Prozent, Verifying, Rebooting, Done). Gegen das Gerät: Bootloader-Connect rund 7 s, Schreiben 21 s, gesamt 31 s für 1,34 MB. Kein esptool-Sidecar nötig, damit entfällt auch die Defender-Frage. |
| Updates in der App | erledigt | `updates.rs`: Releases über `ureq`, Cache, Prüfung 10 s nach Start und alle 6 h, Kanal stable/beta in den Settings, Firmware-Download in den App-Datenordner mit Fortschritt, App-Update mit SHA-256-Prüfung gegen die Sidecar-Datei und Start von `AIMonitor-Setup.exe /S /UPDATE /R` unter Windows, sonst Release-Seite im Browser. |
| Flash in der App | erledigt | `flash.rs`: Serial-Service anhalten und Port freigeben, 500 ms, Flash im Worker mit Ereignissen, danach Wiederaufnahme mit Diagnose-Frame nach dem nächsten Connect und Rückkehr zum echten Snapshot nach 20 s. Bei Erfolg Board-Variante im Profil und installierte Version gespeichert. Flash-Sperre gegen Doppelstart. |
| Seite Updates | gebaut | App-Box mit Version, Kanal, Prüfen, Installieren; Firmware-Box mit installierter Version, Variante, Update-Zeile und Inline-Flash-Dialog wie auf dem Mac (Variante, Vorprüfung, Fortschritt, Fehler mit Wiederholen und anderer Variante). |
| Abnahme | teilweise | Log gegen das Gerät: Update-Prüfung gegen die echte GitHub-API (v2.17.0, beide Assets, für die Windows-App noch kein Release), Firmware-Download 1,34 MB, Flash mit allen Phasen, Reconnect mit 2.17.0, Diagnose-Frame mit ACK, Rückkehr zum Snapshot, `standby` beim Beenden. 55 Tests grün. Nicht geprüft: App-Update-Installation (kein Windows, kein `win-v`-Release, kommt mit Phase 4), Flash der ST7789-Variante (kein solches Board angeschlossen), Seite Updates visuell (Bildschirm aus). |

Entwickler-Schalter: `AIMONITOR_DEV_ACTION=check|download|flash` löst die jeweilige Aktion beim
Start aus, `AIMONITOR_DEV_VARIANT` wählt die Variante.

## Phase 4 – Installer, Signierung, CI

Aufwand: 3 bis 4 Tage.

- Installer über den NSIS-Bundler von Tauri statt eines eigenen Inno-Setup-Skripts:
  Per-User-Installation nach `%LOCALAPPDATA%\AI Monitor`, Startmenü, WebView2-Bootstrap,
  stiller Modus `/S` für den In-App-Updater. Der Autostart bleibt eine App-Einstellung.
  Das Inno-Skript aus Win-CodexBar war als Vorlage geplant; der Tauri-Bundler liefert
  dasselbe Ergebnis ohne eigenes Skript und ist mit der Signierung integriert.
- Signierung gemäß Entscheidung 6.
- Workflow `.github/workflows/windows-app.yml` nach dem Muster von `mac-app.yml`:
  Trigger auf `win-v*`/`win-beta-v*` und Dispatch, `windows-latest`, Versionsprüfung
  Tag gegen `tauri.conf.json`, `package.json` und `Cargo.toml`, Tests auf Windows, NSIS-Build, Signatur, SHA-256,
  `gh release upload`.

Ergebnis: Tag pushen liefert ein signiertes Setup am Release.

### Stand Phase 4 (11. September 2026)

| Teil | Status | Ergebnis |
|---|---|---|
| Installer | erledigt | Tauri-NSIS-Bundler: `AIMonitor-Setup.exe` mit 2,9 MB, Per-User nach `%LOCALAPPDATA%\AI Monitor`, Startmenü, WebView2-Bootstrapper still, Sprachen de/en. Stiller Modus `/S` im CI per Smoketest geprüft: Installation, `aimonitor.exe` vorhanden, Deinstallation. |
| Workflow | erledigt | `.github/workflows/windows-app.yml`: Trigger `win-v*`/`win-beta-v*` und Dispatch, Versionsprüfung Tag gegen `tauri.conf.json`, `package.json`, `Cargo.toml`, `cargo test --workspace` auf `windows-latest` (erster echter Windows-Build der Crates, alle 55 Tests grün), NSIS-Build, Umbenennen, SHA-256-Sidecar, Workflow-Artefakt, Release-Upload mit Prerelease-Markierung für Betas. Laufzeit rund 12 min mit warmem Cache. |
| Signierung | vorbereitet, offen | Zwei optionale Pfade im Workflow, aktiviert allein durch Secrets: Azure Trusted Signing (`AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_SIGNING_ENDPOINT`, `AZURE_SIGNING_ACCOUNT`, `AZURE_SIGNING_PROFILE`, über `trusted-signing-cli` als `signCommand`) oder PFX (`WINDOWS_CERTIFICATE_BASE64`, `WINDOWS_CERTIFICATE_PASSWORD`, über `certificateThumbprint`). Ohne Secrets baut CI unsigniert. Entscheidung 6 bleibt offen. |
| Abnahme | teilweise | Zwei Dispatch-Läufe: der erste scheiterte am Bundle-Pfad (Workspace-Zielordner), der zweite lief komplett durch. Nicht geprüft: Signierung (keine Secrets), Release-Upload per Tag (noch kein `win-v`-Tag), Updater-Kette Beta zu Beta. |

Nächster Schritt für ein erstes Release: Tag `win-beta-v1.0.0-beta.1` setzen, dann prüft der
Workflow die Versionen, baut das Setup und hängt es mit Sidecar an ein Prerelease. Dafür
müssen `tauri.conf.json`, `package.json` und die Workspace-`Cargo.toml` vorher auf
`1.0.0-beta.1` stehen.

## Phase 5 – Seite, Doku, Release

Aufwand: 2 Tage.

- `installer/index.html`: zweite Download-Karte für Windows, Anforderungen
  (Windows 10/11 x64, Win-CodexBar statt CodexBar, CH340-Treiber), i18n-Strings.
- `scripts/sync_site_versions.sh` um die Windows-Version erweitern, Check in
  `build.yml` nachziehen.
- README: Abschnitt Windows mit Anforderungen und Build from Source.
- Release 1.0.0 als Beta, dann stable.

### Stand Phase 5 (11. September 2026)

| Teil | Status | Ergebnis |
|---|---|---|
| Installer-Seite | erledigt | Windows-Download als zweiter Button in der AI-Monitor-Karte mit Versionshinweisen und Versions-Tag, Hinweis im Hero, Win-CodexBar-Link in der CodexBar-Karte, Anforderungen und Einrichtung sprachlich für beide Plattformen, neuer Hilfe-Eintrag „Gibt es AI Monitor auch für Windows?" mit winget-Befehl und CH340-Hinweis, Fußzeile mit Windows-Version. Alle Texte auch auf Englisch. |
| Versions-Sync | erledigt | `scripts/sync_site_versions.sh` liest die Windows-Version aus `tauri.conf.json` und ersetzt `data-v="win"` sowie die `win-v`/`win-beta-v`-Links. Der Windows-Workflow prüft die Seite bei jedem Release-Tag. |
| README | erledigt | Windows in Überblick, Quick Start, Anforderungen (Win-CodexBar, CH340-Treiber), Build from Source, Release Flow und Tech Stack. |
| Erstes Release | **veröffentlicht** | Prerelease [win-beta-v1.0.0](https://github.com/tobymarks/esp32-ai-monitor/releases/tag/win-beta-v1.0.0) mit `AIMonitor-Setup.exe` (2,9 MB) und `.sha256`, unsigniert. Die Seite verlinkt darauf und ist deployt. Der erste Tag-Lauf scheiterte an CRLF im Versions-Sync, der zweite lief durch. Die Versionsnummer bleibt numerisch `1.0.0`, weil der NSIS-Bundler von Tauri Prerelease-Suffixe wie `-beta.1` nicht zuverlässig verarbeitet; der Beta-Status steckt im Tag und im Prerelease-Flag. Der Weg zu stable: Tag `win-v1.0.0` auf demselben Stand oder `win-v1.0.1` nach Fixes. |
| Stable-Release | **veröffentlicht** | [win-v1.0.0](https://github.com/tobymarks/esp32-ai-monitor/releases/tag/win-v1.0.0) mit `AIMonitor-Setup.exe` (2,9 MB) und `.sha256`, unsigniert. Seite und README stehen auf stable, die Seite ist deployt und verlinkt das Release. Signierung: SignPath-Foundation-Antrag am 12. September 2026 gestellt, am 17. September abgelehnt (zu wenig externe Sichtbarkeit, Wiederbewerbung möglich). Nächste Optionen: Reichweite aufbauen und erneut beantragen, oder Certum Open Source Code Signing mit lokaler Signierung auf dem Mac. |


## Gesamtaufwand

Etwa 19 bis 25 Personentage netto, ohne Wartezeiten für Signierung und Hardware.

## Risiken

| Risiko | Gegenmaßnahme |
|---|---|
| Win-CodexBar ändert das JSON ohne Ankündigung | Fixtures und Schema-Test in CI, CLI-Version in der Diagnose, Mapping in einem Modul gekapselt |
| Claude-Zahlen weichen von der Mac-App ab (Cookies statt OAuth) | Spike in Phase 0, Source-Modus als Einstellung durchreichen |
| SmartScreen-Warnung ohne Signatur | Entscheidung 6 vor dem ersten stable Release |
| ESP32 resettet beim Öffnen des COM-Ports | Spike in Phase 0, DTR/RTS explizit setzen |
| `espflash` schreibt die gemergten Images nicht korrekt | Spike in Phase 0, Fallback esptool-Sidecar |
| WebView2 fehlt auf Windows 10 | Bootstrap im Installer |
| Win-CodexBar hat einen einzelnen Maintainer | Fork-Fähigkeit durch MIT-Lizenz, Mapping-Schicht hält Abhängigkeit klein |

## Nicht im Umfang

- Windows auf ARM64
- Linux (durch Tauri vorbereitet, eigener Plan)
- Änderungen an Firmware oder Protokoll
- Änderungen an der Mac-App außer dem Versions-Sync der Seite
