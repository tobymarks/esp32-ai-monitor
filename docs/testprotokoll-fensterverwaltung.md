# Testprotokoll: Fensterverwaltung (25.09.2026)

## Testumgebung

- Windows-App nativ unter Windows 11 gestartet; Entwicklung und Builds in WSL.
- Physischer ESP32-D0WD-V3 mit ILI9341, XPT2046, COM5 (CH340), MAC `14:33:5c:6c:82:c0`.
- Geflashte Dev-Firmware: `2.19.0-dev`, ILI9341, SHA-256 des aktuellen Images an Adresse `0x10000`: `06a94d5f768a18bedabeecf762b9fae3bea8c09c2bd9a152497511da3985a04c`.

## Ergebnisse

| Prüfung | Ergebnis | Nachweis |
| --- | --- | --- |
| Windows-Frontend, TypeScript und Vite | Bestanden | `npm run build`; 29 Module verarbeitet. |
| Native Windows-App | Bestanden | `cargo build -p aimonitor`; App verbindet sich mit COM5 und erkennt Firmware `2.19.0-dev`. |
| Rust-Kerntests | Bestanden | 49 Unit-Tests und 5 Fixture-Tests. |
| Firmware-Builds | Bestanden | PlatformIO `esp32dev` und `esp32dev-st7789`; ILI9341: 36,5 % RAM und 65,0 % Flash. |
| Firmware auf physischem ESP | Bestanden | esptool meldet verifizierten Flash-Hash und Hard-Reset; anschließender `get_info`-Handshake meldet `2.19.0-dev` und `ili9341`. |
| Fensterkonfiguration per serieller Schnittstelle | Bestanden | `set_views` mit drei Fenstern (Uhr, Claude, ChatGPT) angenommen; Datenframes mit `viewIndex` als ACK quittiert. |
| Automatischer Wechsel | Bestanden | Bei 2 Sekunden Intervall erscheinen seriell nacheinander Fenster 1/3, 2/3 und 3/3. |
| Manueller Wechsel | Bestanden | Fenster 3/3 bleibt über 4,5 Sekunden aktiv; Auswahl aus der Windows-Übersicht schaltet das aktive Fenster. |
| Fehlerbehandlung | Bestanden | Frame mit unpassender Quelle zum `viewIndex` wird abgewiesen; danach wird ein gültiger Frame wieder quittiert. |
| Konfiguration nach Neustart | Bestanden | Der ESP stellt den gespeicherten manuellen Modus und das aktive Fenster wieder her. |
| Fensterverwaltung in Windows | Bestanden | Visuell bei 1400 × 900 und 916 × 639 geprüft; Hinzufügen, Entfernen, festes erstes Fenster, Drag-and-Drop, Quelle/Uhr, Intervall und manuelle Auswahl gespeichert. |
| Fensterübersicht mit Inhaltsnamen | Bestanden | In der nativen Windows-App bei 916 × 639 zeigen die Buttons eine zweite Zeile mit ChatGPT, Uhr und Claude. Auswahl der Uhr per Button geprüft und zuvor aktives Claude-Fenster wiederhergestellt. |
| Physische Uhransicht | Bestanden | Nutzerfoto zeigt die Uhr auf dem angeschlossenen Display. |
| Physischer Touch | Bestanden | Nach Wechsel auf den separaten HSPI-Bus werden Druckkoordinaten und Loslassen seriell erfasst; mehrere kurze Berührungen wechseln zwischen Fenster 1/2 und 2/2. Nutzer bestätigt die Funktion. |
| Touchrichtung links/rechts | Bestanden | Mit drei Fenstern schalten Berührungen links (`x≈50–86`) rückwärts und rechts (`x≈243–272`) vorwärts, jeweils mit Umlauf am Listenende. Nutzer bestätigt beide Richtungen; der erneute Flash-Hash wurde verifiziert. |
| Standby nach App-Ende | Bestanden | Gültigen Zeit- und Nutzungsframe für Claude gesendet, danach `standby`: die Firmware protokolliert sofort „Standby clock shown“. |
| Neustart ohne Companion-App | Bestanden | Bei gespeichertem Claude-Fenster erscheint nach kurzer Startphase die Standby-Uhr; der manuelle Fenstermodus bleibt ohne automatische Wechsel erhalten. Ohne gespeicherte WLAN-Zugangsdaten steht nach einem vollständigen Stromverlust zunächst `--:--`, bis eine Zeitquelle verfügbar ist. |
| Physische Datenquellenansicht | Nicht visuell geprüft | Auf Wunsch des Nutzers wurde das zusätzliche Foto ausgelassen. Die App sendet echte ChatGPT- und Claude-Daten, und der ESP quittiert die Frames mit 1 bzw. 2 Zeilen. |

## Regressionstest nach Code-Review

| Prüfung | Ergebnis | Nachweis |
| --- | --- | --- |
| Legacy-Companion bei gespeicherter Uhr und mehreren Fenstern | Bestanden | Nach `set_views` mit `clock,codex` nahm der physische ESP einen Codex-Frame ohne `viewIndex` mit ACK an. `get_views` zeigte zur Laufzeit ein Codex-Fenster. Nach `reboot` war die gespeicherte Liste `clock,codex` wieder vorhanden. |
| Touch-Kalibrierung | Bestanden | Die lineare Abbildung nutzt nun den Messbereich von `TOUCH_MIN` bis `TOUCH_MAX` und bildet dessen Enden auf 0 und 319 bzw. 239 ab. Hardware-Touch wurde weiterhin seriell mit Koordinaten und `view_state` erfasst. Eine separate Messung direkt am äußersten Rand steht aus. |
| Touchrichtung in Querformat rechts | Bestanden | Ein Tipp oben rechts wurde vor der Korrektur als `x≈23,y≈23` gemessen. Die X-Richtung wurde gedreht, beide Firmware-Varianten neu gebaut und der physische ESP erneut geflasht. Der Nutzer bestätigt danach: rechts = nächstes Fenster, links = vorheriges Fenster. |
| Einstellungen per langem Druck verlassen | Bestanden | Serielle Folge am physischen ESP: `Long press -> Settings`, `Settings screen created`, danach `Settings closed -> Dashboard`. Der Nutzer bestätigt visuell Öffnen und Schließen. Der Zurück-Pfeil nutzt denselben Rückweg. |
| Standby bei automatischem Wechsel | Bestanden | Zwei Provider-Fenster hatten gültige ACKs. Nach `standby` erschien die Standby-Uhr; beide Fenster rotierten weiter, ohne dass „Standby clock hidden“ oder alte Werte zurückkamen. |
| Geräteauswahl an Windows-App | Bestanden | Der ESP sendete nach Touch `view_state`; die native Windows-App übernahm den aktiven Index in `settings.json`, und die Übersicht markierte visuell dasselbe Fenster. |
| Touch-Auswahl über Neustart und Reconnect | Bestanden | Vor und nach einem physischen ESP-Neustart meldete `get_views` dieselbe Liste `codex,clock,claude`, `manual`, 2 Sekunden und `active:2`. Nach Start der Windows-App blieb Fenster 3 in Datei und Übersicht markiert. |
| Builds und Tests | Bestanden | PlatformIO für ILI9341 und ST7789, `npm run build`, nativer `cargo build -p aimonitor`, 50 Rust-Kerntests, 5 Fixture-Tests und 2 Serial-Tests unter Windows. |
| Abschlusszustand | Bestanden | Nach dem letzten Flash zeigt die native Windows-App „verbunden“ auf COM5, Firmware `2.19.0-dev`, ILI9341 und quittierte Datenframes. Die Dev-Firmware läuft auf dem physisch angeschlossenen ESP. |

Der projektweite `cargo fmt --all -- --check` meldet bereits in unveränderten Dateien zahlreiche Formatabweichungen; es wurde keine pauschale Umformatierung vorgenommen.

## Integration mit `main` vom 25.09.2026

- Die drei neuen `main`-Commits mit lokalem Firmware-Flash und den Releases Windows 1.1.0 / Mac 1.29.0 wurden in den Feature-Branch gemergt. Die Windows-Version steht in `package.json`, `Cargo.toml` und `tauri.conf.json` übereinstimmend auf 1.1.0; die neue Geräte-Firmware bleibt `2.19.0-dev`.
- Nach dem Merge: `npm run build`, `cargo test -p aimonitor-core --locked` (50 Unit- und 5 Fixture-Tests), `cargo test --workspace --locked` nativ unter Windows (65 Tests) und `cargo build -p aimonitor --locked` bestanden. Beide PlatformIO-Varianten wurden erneut erfolgreich gebaut.
- Die nativ neu gebaute Windows-App verbindet sich nach dem Merge wieder mit dem physischen ESP auf COM5. Die Verbindungsansicht zeigt Firmware `2.19.0-dev`, ILI9341 und einen quittierten Datenframe mit zwei Zeilen.
