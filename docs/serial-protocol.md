# USB-Serial-Protokoll zwischen Companion-App und ESP32-Firmware

Basisstand: 10. September 2026. Bezug: Mac-App 1.28.0 `(main.swift:33)`, Firmware 2.17.0 `(config.h:11)`. Die Windows-Erweiterung vom 25. September 2026 steht in Abschnitt 10.

Diese Spezifikation beschreibt das Protokoll implementierungsunabhängig. Jede Aussage trägt einen Quellverweis in der Form `(main.swift:1706)` oder `(serial_receiver.cpp:120)`, damit sie gegen den Code prüfbar bleibt. Zeilenangaben beziehen sich auf `companion/Sources/main.swift`, `companion/Sources/CodexBarSource.swift`, `companion/Sources/SettingsWindow+*.swift` sowie `src/*.cpp` und `src/*.h` im Stand des oben genannten Commits.

Was im Code nicht eindeutig ist, steht in Abschnitt 9 als offener Punkt. Nichts in diesem Dokument ist erfunden oder aus anderen Quellen ergänzt.

Die Quellenverweise und Zeilenangaben der Abschnitte 1 bis 9 beschreiben den damaligen Basisstand. Abschnitt 10 beschreibt die Fensterverwaltung der Mac- und Windows-App ab Firmware 2.19.0.

---

## 1. Überblick und Transportparameter

Die App ist der Host, das ESP32-Board ist das Gerät. Der Host öffnet den USB-Serial-Port, identifiziert das Gerät per Handshake und schickt danach zwei Arten von Nachrichten: kurze JSON-Kommandos und größere JSON-Datenframes mit Nutzungsdaten. Das Gerät antwortet mit JSON-Zeilen und gibt daneben unstrukturierte Log-Zeilen aus, die der Host ignorieren muss.

| Parameter | Wert | Quelle |
|---|---|---|
| Baudrate | 115200 | `(main.swift:34)`, `(main.cpp:246)` |
| Datenformat | 8 Datenbits, keine Parität, 1 Stoppbit, keine Hardware-Flusskontrolle, keine Software-Flusskontrolle | `(main.swift:1796-1803)` |
| Zeichensatz | UTF-8 auf dem Host `(main.swift:1699)`. Das Gerät verarbeitet Bytes; Anzeigetexte müssen druckbares ASCII sein, siehe 5.5 | `(main.swift:2744-2760)` |
| Zeilenende Host zu Gerät | `\n` (0x0A). Das Gerät ignoriert `\r` (0x0D) | `(serial_receiver.cpp:774)` |
| Zeilenende Gerät zu Host | `\n`. Der Host ignoriert `\r` und schneidet bei `\n` | `(main.swift:2190-2191)` |
| RX-Puffer Gerät (UART-Treiber) | 4096 Bytes | `(main.cpp:245)` |
| Zeilen-/Frame-Puffer Gerät | `SERIAL_BUF_SIZE` = 4096, davon nutzbar `SERIAL_FRAME_MAX_SIZE` = 4095 Bytes | `(serial_receiver.cpp:36-37)` |
| Maximale Frame-Größe | 4095 Bytes JSON-Payload. Der Host liest den Wert aus `maxFrameBytes` im `info`-Handshake und verwirft größere Payloads ohne zu senden | `(serial_receiver.cpp:169)`, `(main.swift:1701-1705)` |
| Maximale Zeilenlänge im Legacy-Modus | 4095 Bytes, bei Überschreitung antwortet das Gerät mit `Serial line overflow` und verwirft bis zum nächsten `\n` | `(serial_receiver.cpp:775-781)` |
| Host-Lesepuffer | unbegrenzt wachsendes Byte-Array pro Zeile, byteweise gelesen | `(main.swift:2181-2191)` |
| Schema-Version der Datenframes | 1. Das Gerät lehnt größere Werte ab | `(main.swift:2214)`, `(serial_receiver.cpp:48)` |

Alle Nachrichten sind einzeilige JSON-Objekte. Der Host akzeptiert nur Zeilen, die mit `{` beginnen `(main.swift:1838)`, `(main.swift:2091)`, `(main.swift:2167)`. Alles andere, insbesondere Log-Zeilen wie `[Serial] Command received: get_info` `(serial_receiver.cpp:403)` oder das Boot-Banner `(main.cpp:248-250)`, wird übersprungen.

---

## 2. Port-Erkennung und -Öffnen

### 2.1 Erkennung auf dem Mac

Der Host listet alle Einträge in `/dev`, deren Name mit `cu.usbserial-` beginnt, und sortiert sie alphabetisch `(main.swift:1747-1751)`. USB-Vendor- oder Product-IDs kommen im Code nicht vor. Die Auswahl läuft so `(main.swift:1760-1785)`:

1. Ist bereits ein Port verbunden und existiert die Datei noch, passiert nichts. Ist die Datei verschwunden, wird getrennt.
2. Gibt es einen manuell gewählten Port `manualPortPath` `(main.swift:516)` und ist er in der Liste, wird er genommen. Sonst der erste Eintrag der sortierten Liste.
3. Liegt der letzte Disconnect weniger als `kReconnectBlockWindow` = 1 s zurück, wird der Verbindungsversuch übersprungen `(main.swift:1662)`, `(main.swift:1777-1783)`.

Der Scan läuft alle `kSerialScanInterval` = 3 s per Timer und einmal sofort beim Start `(main.swift:35)`, `(main.swift:1733-1738)`. Ein manueller Portwechsel im Settings-Fenster trennt und scannt sofort neu `(main.swift:1755-1758)`, `(SettingsWindow+Connection.swift:306-320)`.

### 2.2 Öffnen

Der Port wird mit `O_RDWR | O_NOCTTY | O_NONBLOCK` geöffnet, danach wird `O_NONBLOCK` wieder entfernt, sodass alle weiteren Lese- und Schreibaufrufe blockierend sind `(main.swift:1789)`, `(main.swift:1806-1807)`. termios-Einstellungen `(main.swift:1792-1805)`:

- Ein- und Ausgabegeschwindigkeit 115200
- `PARENB` aus, `CSTOPB` aus, `CSIZE` auf `CS8`
- `CRTSCTS` aus, `CLOCAL` an
- `ICANON`, `ECHO`, `ECHOE`, `ISIG` aus (Raw-Modus)
- `IXON`, `IXOFF`, `IXANY` aus
- `OPOST` aus

DTR und RTS werden im Code nicht explizit gesetzt oder gelöscht. `HUPCL` wird nicht verändert. Was der Treiber beim Öffnen und Schließen mit den Modem-Leitungen macht, ist damit nicht durch den Code festgelegt. Siehe offener Punkt 9.1.

### 2.3 Boot-Delay und Handshake

Unmittelbar nach dem Öffnen `(main.swift:1811-1827)`:

1. Zustand wird auf `probing` gesetzt.
2. Ein einzelnes `\n` wird geschrieben.
3. Der Host wartet 200 ms (`usleep(200_000)`).
4. Auf einem Hintergrund-Thread: Eingangspuffer leeren (`drainInput`, liest alles, was innerhalb 10 ms Poll-Fenstern anliegt `(main.swift:2198-2206)`), dann `{"cmd":"get_info"}\n` schreiben.
5. Bis zu `kGetInfoTimeout` = 5 s auf eine Zeile mit `"type":"info"` und einem String-Feld `version` warten `(main.swift:1667)`, `(main.swift:1832-1844)`. Andere Zeilen werden übersprungen. Ab App 1.28.4 wird `get_info` jede Sekunde wiederholt, bis eine Antwort kommt, auch im späteren Wartefenster nach `foreignFirmware`.

Ab App 1.28.4 gilt ein Lesefehler auf dem offenen Port (`POLLHUP`/`POLLERR`, `read` mit `ENXIO`/`EIO` oder 0 Bytes) als Portverlust. Der nächste Scan trennt und öffnet den Port neu, auch wenn er unter demselben Namen wieder erscheint. Anlass: Bis Firmware 2.18.0 startete das Gerät beim ersten Boot nach einem Flash das Funkmodul, das komplett neu kalibrierte. Der Stromstoß ließ auf CYD-Boards den USB-Seriell-Chip kurz abfallen, und die App blieb auf `foreignFirmware` stehen. Ab Firmware 2.18.1 bleibt das Funkmodul ohne gespeicherte WLAN-Zugangsdaten aus.

Erfolg führt in den Zustand `connected`, Timeout in `foreignFirmware` `(main.swift:1862)`, `(main.swift:1888)`. Nach `foreignFirmware` lauscht der Host noch bis zu 8 s weiter auf eine späte `info`-Antwort und stuft bei Erfolg auf `connected` hoch `(main.swift:1907-1946)`. In beiden Fällen wird anschließend der `onConnect`-Callback ausgelöst `(main.swift:1898)`, `(main.swift:1943)`.

Kommandos und Datenframes werden nur im Zustand `connected` gesendet (`isReadyForCommands`) `(main.swift:1684)`, `(main.swift:2133)`, `(main.swift:2464)`, `(main.swift:2693)`.

Auf Geräteseite startet die Firmware die UART mit 4096 Bytes RX-Puffer, 115200 Baud, wartet 500 ms und gibt dann ein Textbanner aus `(main.cpp:245-250)`.

### 2.4 Trennen

`disconnect()` schließt den Deskriptor, setzt alle Geräteinfos (`deviceFirmwareVersion`, `deviceSerialTransport`, `deviceMaxFrameBytes`) zurück, merkt sich den Zeitpunkt für das Block-Fenster und geht in `disconnected` `(main.swift:1949-1957)`. Ein Schreibfehler löst ebenfalls `disconnect()` aus `(main.swift:2056-2059)`, `(main.swift:2080-2083)`.

### 2.5 Hinweis für Windows

Die Port-Erkennung über den Dateinamen-Präfix und die termios-Konfiguration sind macOS-spezifisch. Für Windows gibt es im Code keine Vorgabe. Siehe 9.1 und 9.2.

---

## 3. Framing

Es gibt zwei Übertragungsformen für JSON-Nachrichten vom Host zum Gerät. Vom Gerät zum Host gibt es nur die Zeilenform.

### 3.1 Legacy-Zeilenmodus

Ein JSON-Objekt als eine Zeile, abgeschlossen mit `\n` `(main.swift:1712)`, `(main.swift:2064)`, `(main.swift:2151)`. Das Gerät sammelt Bytes bis `\n`, ignoriert `\r`, und parst die Zeile als JSON, sofern sie nicht mit dem AIM1-Header beginnt `(serial_receiver.cpp:766-782)`. Leere Zeilen werden ignoriert `(serial_receiver.cpp:767)`.

Alle Kommandos (`get_info`, `set_*`, `wifi_*`, `standby`) gehen immer im Zeilenmodus, unabhängig von der Firmware-Version `(main.swift:1821)`, `(main.swift:2063-2066)`, `(main.swift:2151)`.

### 3.2 AIM1-Framing

Nur Datenframes (Usage-, Notice- und Diagnose-Frames) werden gerahmt, und nur wenn das Gerät den Modus unterstützt `(main.swift:1698-1713)`, `(main.swift:2072)`.

Aufbau `(main.swift:1706-1710)`:

```
AIM1 <byteLength> <frameId>\n
<byteLength Bytes JSON-Payload>\n
```

Header-Format-String: `"AIM1 \(payload.count) \(frameId ?? -1)\n"`. `byteLength` ist die Byte-Länge der UTF-8-kodierten JSON-Payload ohne das abschließende `\n`. `frameId` ist die Frame-Nummer aus der Payload; ohne Frame-ID wird `-1` gesendet. Nach der Payload folgt ein einzelnes `\n`.

Beispiel mit 52 Byte Payload:

```
AIM1 52 17
{"schemaVersion":1,"frameId":17,"data":[{"x":1}]}
```

Geräteseitiges Verhalten `(serial_receiver.cpp:151-183)`, `(serial_receiver.cpp:742-756)`:

- Der Header wird als normale Zeile empfangen. Beginnt sie mit `AIM1` gefolgt von einem Leerzeichen, wird die Länge mit `strtoul` gelesen; danach optional die Frame-ID mit `strtol`.
- Länge 0 oder größer als 4095 führt zu `{"type":"error","frameId":<id>,"message":"Invalid frame length <n>"}` und der Header wird verworfen `(serial_receiver.cpp:169-175)`.
- Sonst wechselt das Gerät in den Frame-Modus und übernimmt exakt `byteLength` Rohbytes, egal welchen Inhalts. Nach dem letzten Byte wird die Payload als JSON geparst und der Modus verlassen.
- Das abschließende `\n` des Hosts kommt danach als leere Zeile an und wird ignoriert `(serial_receiver.cpp:766-773)`.
- Kommen die Bytes nach dem Header nicht innerhalb von `SERIAL_FRAME_TIMEOUT_MS` = 2000 ms vollständig an, verwirft das Gerät den Teilframe und meldet `{"type":"error","message":"frame timeout"}` `(serial_receiver.cpp:45)`, `(serial_receiver.cpp:791-798)`.

Die Frame-ID aus dem Header wird vom Gerät nur für die Längenfehlermeldung benutzt. Das ACK trägt die `frameId` aus der JSON-Payload `(serial_receiver.cpp:612)`.

### 3.3 Wann welcher Modus gilt

Der Host wählt AIM1, wenn eine der beiden Bedingungen erfüllt ist `(main.swift:1678-1696)`:

1. Das Feld `serialTransport` im `info`-Handshake ist, nach Kleinschreibung und Trimmen, gleich `aim1` `(main.swift:1846-1848)`.
2. Die gemeldete `version` ist größer oder gleich `2.12.3` nach dem Vergleich in Abschnitt 8.1.

Sonst gilt der Legacy-Zeilenmodus. Das Gerät akzeptiert beide Formen gleichzeitig; die Firmware seit 2.12.3 meldet `serialTransport` `(serial_receiver.cpp:11-13)`, `(serial_receiver.cpp:377)`.

---

## 4. Nachrichten vom Gerät

Alle Nachrichten sind einzeilige JSON-Objekte mit einem Feld `type`. Dazwischen erscheinen Log-Zeilen in Klartext, die mit `[` oder `=` beginnen `(main.cpp:248-250)`, `(serial_receiver.cpp:403)`, `(serial_receiver.cpp:702)`.

### 4.1 `info`

Antwort auf `get_info` `(serial_receiver.cpp:353-389)`.

| Feld | Typ | Bedeutung | Quelle |
|---|---|---|---|
| `type` | String | `"info"` | 373 |
| `version` | String | Firmware-Version ohne führendes `v`, z. B. `"2.17.0"` | 373, `(config.h:11)` |
| `mac` | String | WiFi-STA-MAC, Kleinbuchstaben-Hex mit Doppelpunkten, z. B. `"a4:cf:12:34:56:78"`. Seit 2.10.0 | 363-369 |
| `display` | String | `"ili9341"`, `"st7789"` oder `"unknown"`. Seit 2.10.1 | 374, `(config.h:19-25)` |
| `orientation` | String | `"portrait"`, `"landscape_left"`, `"landscape_right"` | 354-360 |
| `theme` | String | `"light"` oder `"dark"` | 361 |
| `language` | String | `"de"` oder `"en"` | 362 |
| `brightness` | Int | 5..100 | 376, `(config.h:170-171)` |
| `serialTransport` | String | `"AIM1"` | 377, `(serial_receiver.cpp:38)` |
| `maxFrameBytes` | Int | 4095 | 377 |
| `sceneProtocol` | Int | `1` bei Firmware mit Display-Szenen; fehlt bei älterer Firmware | `serial_receiver.cpp` |
| `wifiConfigured` | Bool | Zugangsdaten gespeichert | 378 |
| `wifiConnected` | Bool | WLAN verbunden | 378 |
| `timeSynced` | Bool | NTP-Sync erfolgt | 378 |
| `uptime` | Int | Sekunden seit Boot | 379 |
| `heap` | Int | freier Heap in Bytes | 379 |

Beispiel:

```json
{"type":"info","version":"2.17.0","mac":"a4:cf:12:34:56:78","display":"ili9341","orientation":"portrait","theme":"dark","language":"de","brightness":80,"serialTransport":"AIM1","maxFrameBytes":4095,"wifiConfigured":false,"wifiConnected":false,"timeSynced":false,"uptime":12,"heap":180000}
```

Der Host liest `version` (Pflicht), `serialTransport`, `maxFrameBytes`, `mac`, `display`, `brightness` `(main.swift:1841-1873)`. Die übrigen Felder werden vom Host nicht ausgewertet. `serialTransport` wird kleingeschrieben und getrimmt verglichen, `mac` und `display` ebenfalls kleingeschrieben `(main.swift:1846-1869)`. Fehlt `mac` oder ist es leer, verwendet der Host die Pseudo-MAC `legacy-device` `(main.swift:99)`, `(main.swift:1859-1861)`. `display` wird nur übernommen, wenn es `ili9341` oder `st7789` ist `(main.swift:1974-1977)`, `(main.swift:53-56)`.

### 4.2 `ack`

Bestätigung eines Datenframes, nur wenn die Payload ein `frameId` >= 0 enthielt `(serial_receiver.cpp:129-140)`.

| Feld | Typ | Bedeutung |
|---|---|---|
| `type` | String | `"ack"` |
| `frameId` | Int | `frameId` aus der Payload |
| `schemaVersion` | Int | `schemaVersion` aus der Payload, 0 wenn nicht vorhanden |
| `message` | String | immer `"accepted"` |
| `bytes` | Int | Länge der geparsten Payload in Bytes; bei Notice-Frames 0 `(serial_receiver.cpp:668)` |
| `provider` | String | Anzeige-Label des erkannten Providers in Großbuchstaben, z. B. `"CLAUDE"` `(providers.cpp:18)` |
| `rows` | Int | Anzahl übernommener Zeilen, 0..3 |
| `heap` | Int | freier Heap |

Beispiel:

```json
{"type":"ack","frameId":17,"schemaVersion":1,"message":"accepted","bytes":812,"provider":"CLAUDE","rows":3,"heap":176000}
```

Der Host liest `type`, `frameId`, `message`, `bytes`, `schemaVersion` `(main.swift:2094-2107)`.

### 4.3 `error`

Drei Formen:

1. Frame-Fehler mit Frame-ID, nur wenn `frameId` >= 0 `(serial_receiver.cpp:142-149)`:
   ```json
   {"type":"error","frameId":17,"schemaVersion":1,"message":"Missing data[0]"}
   ```
   Mögliche `message`-Werte: `"unsupported schemaVersion"` `(serial_receiver.cpp:622)`, `"Missing data[0]"` `(serial_receiver.cpp:635)`, `"Missing usage"` `(serial_receiver.cpp:676)`.
2. Header-Längenfehler mit Frame-ID aus dem Header `(serial_receiver.cpp:170-173)`:
   ```json
   {"type":"error","frameId":17,"message":"Invalid frame length 5000"}
   ```
3. Kommando- und Transportfehler ohne Frame-ID:
   - `"set_orientation: missing value"`, `"set_orientation: invalid value '<x>'"` `(serial_receiver.cpp:229, 240)`
   - `"set_brightness: missing or invalid value"` `(serial_receiver.cpp:256)`
   - `"set_theme: missing value"`, `"set_theme: invalid value '<x>'"` `(serial_receiver.cpp:308, 317)`
   - `"set_language: missing value"`, `"set_language: invalid value '<x>'"` `(serial_receiver.cpp:331, 341)`
   - `"Unknown command: <cmd>"` `(serial_receiver.cpp:429)`
   - `"Serial line overflow"` `(serial_receiver.cpp:778)`
   - `"frame timeout"` `(serial_receiver.cpp:793)`

Der Host wertet beim Warten auf ein ACK nur `error`-Zeilen mit passender `frameId` aus `(main.swift:2095-2097)`. Fehler ohne `frameId` werden vom Host nirgends gelesen.

JSON-Parse-Fehler auf dem Gerät erzeugen keine JSON-Antwort, nur eine Log-Zeile `[Serial] JSON parse error: ...` und den Anzeigestatus `JSON Error` `(serial_receiver.cpp:604-610)`.

### 4.4 `ok`

Antwort auf Einstellungs- und Steuerkommandos. Der Host wartet auf keine dieser Antworten; sie werden beim nächsten `drainInput` verworfen oder beim Warten auf andere Typen übersprungen `(main.swift:2063-2066)`, `(main.swift:2078)`.

| Kommando | Antwort | Quelle |
|---|---|---|
| `set_orientation` | `{"type":"ok","cmd":"set_orientation","value":"portrait"}` | `(serial_receiver.cpp:248)` |
| `set_brightness` | `{"type":"ok","cmd":"set_brightness","value":80,"persist":true}` | `(serial_receiver.cpp:268-270)` |
| `set_theme` | `{"type":"ok","cmd":"set_theme","value":"dark"}` | `(serial_receiver.cpp:325)` |
| `set_language` | `{"type":"ok","cmd":"set_language","value":"de"}` | `(serial_receiver.cpp:349)` |
| `standby` | `{"type":"ok","cmd":"standby"}` | `(serial_receiver.cpp:301)` |
| `reboot` | `{"type":"ok","cmd":"reboot"}`, danach 200 ms Pause und Neustart | `(serial_receiver.cpp:393-395)` |

Bei `set_brightness` enthält `value` den geclampten Wert `(serial_receiver.cpp:260-261)`.

### 4.5 `wifi_status`

Antwort auf `wifi_status`, `wifi_set` und `wifi_forget` `(wifi_time.cpp:197-209)`, `(serial_receiver.cpp:283, 289)`.

| Feld | Typ | Bedeutung |
|---|---|---|
| `type` | String | `"wifi_status"` |
| `configured` | Bool | Zugangsdaten gespeichert |
| `connected` | Bool | verbunden |
| `ssid` | String | bei Verbindung die aktive SSID, sonst die gespeicherte |
| `ip` | String | IPv4 als Text oder `""` |
| `rssi` | Int | dBm oder 0 |
| `timeSynced` | Bool | NTP-Sync erfolgt |
| `error` | String | nur bei `wifi_set` ohne SSID: `"missing ssid"` `(serial_receiver.cpp:278)` |

Beispiel:

```json
{"type":"wifi_status","configured":true,"connected":true,"ssid":"Home","ip":"192.168.1.42","rssi":-58,"timeSynced":true}
```

### 4.6 `wifi_scan`

Antwort auf `wifi_scan` `(wifi_time.cpp:211-232)`. Maximal 16 Netze `(wifi_time.cpp:23)`.

```json
{"type":"wifi_scan","networks":[{"ssid":"Home","rssi":-58,"secure":true},{"ssid":"Guest","rssi":-70,"secure":false}]}
```

Der Host liest `networks` als Array von Objekten `(SettingsWindow+Connection.swift:236)`.

---

## 5. Nachrichten zum Gerät

Jede Nachricht ist ein JSON-Objekt. Das Gerät entscheidet anhand des Feldes `cmd`: Ist es ein String, wird die Nachricht als Kommando behandelt und die Datenparser werden übersprungen `(serial_receiver.cpp:399-400)`, `(serial_receiver.cpp:627)`. Vor dieser Prüfung wird `schemaVersion` geprüft; ein Wert größer 2 führt zum Fehler `unsupported schemaVersion`, auch bei Kommandos. Fehlt `schemaVersion`, gilt 0 und die Nachricht wird verarbeitet. Schema 1 ist für Usage-Frames reserviert, Schema 2 für Plugin-Szenen.

### 5.1 Kommandos

Alle Kommandos werden im Zeilenmodus gesendet (Abschnitt 3.1).

#### `get_info`

```json
{"cmd":"get_info"}
```

Antwort: `info` (4.1). Gesendet beim Verbindungsaufbau `(main.swift:1821)`.

#### `set_theme`

```json
{"cmd":"set_theme","value":"dark"}
```

| Feld | Typ | Pflicht | Werte |
|---|---|---|---|
| `value` | String | ja | `"dark"`, `"light"` `(serial_receiver.cpp:312-315)` |

Das Gerät speichert den Wert in NVS, wendet das Theme an und baut das Dashboard im nächsten Hauptschleifendurchlauf neu `(serial_receiver.cpp:320-325)`, `(main.cpp:346-349)`. Der Host löst den Wert `system` selbst auf: Er ermittelt das aktuelle System-Erscheinungsbild und sendet `dark` oder `light` `(main.swift:2465-2472)`. Bei Wechsel des System-Erscheinungsbilds sendet der Host erneut `(main.swift:3132-3136)`. Antwort: `ok`.

#### `set_language`

```json
{"cmd":"set_language","value":"de"}
```

| Feld | Typ | Pflicht | Werte |
|---|---|---|---|
| `value` | String | ja | `"de"`, `"en"` `(serial_receiver.cpp:336-339)` |

Speichert in NVS, baut das Dashboard neu `(serial_receiver.cpp:344-349)`. Antwort: `ok`.

#### `set_orientation`

```json
{"cmd":"set_orientation","value":"landscape_left"}
```

| Feld | Typ | Pflicht | Werte |
|---|---|---|---|
| `value` | String | ja | `"portrait"`, `"landscape_left"`, `"landscape_right"`; `"landscape"` wird als `landscape_left` akzeptiert `(serial_receiver.cpp:233-238)` |

Nur bei Änderung wird gespeichert und die Anzeige live rotiert, ohne Neustart `(serial_receiver.cpp:243-247)`. Der Host sendet die Werte aus dem Geräteprofil, Default `portrait` `(main.swift:191-192)`, `(main.swift:487-488)`. Antwort: `ok`.

#### `set_brightness`

```json
{"cmd":"set_brightness","value":80,"persist":true}
```

| Feld | Typ | Pflicht | Werte |
|---|---|---|---|
| `value` | Int | ja, muss Integer sein `(serial_receiver.cpp:255)` | wird auf 5..100 geclampt `(serial_receiver.cpp:260-261)` |
| `persist` | Bool | nein, Default `true` `(serial_receiver.cpp:262)` | `false` = nur PWM setzen, kein NVS-Write |

Der Host clampt vorher auf 5..100 `(main.swift:2645)`. Beim Slider-Ziehen sendet der Host `persist:false` und nach 0,45 s Ruhe einmal `persist:true` `(SettingsWindow+Display.swift:636-646)`. `persist:false` wird nur an Firmware ab 2.12.4 gesendet; bei älterer Firmware wird der Vorschau-Aufruf unterdrückt `(main.swift:2216)`, `(main.swift:2648-2650)`. Antwort: `ok` mit geclamptem Wert.

#### `standby`

```json
{"cmd":"standby"}
```

Ohne weitere Felder. Das Gerät markiert die vorhandenen Daten als abgelaufen, setzt den Status `Standby` und zeigt daraufhin die Standby-Uhr `(serial_receiver.cpp:295-302)`, `(ui_dashboard.cpp:691-693)`. Der Host sendet das beim sauberen Beenden der App `(main.swift:3161-3164)`. Antwort: `ok`.

#### `wifi_status`

```json
{"cmd":"wifi_status"}
```

Antwort: `wifi_status`. Host-Timeout 4 s `(SettingsWindow+Connection.swift:174-176)`.

#### `wifi_scan`

```json
{"cmd":"wifi_scan"}
```

Antwort: `wifi_scan`. Der Scan blockiert die Firmware synchron `(wifi_time.cpp:213)`. Host-Timeout 18 s `(SettingsWindow+Connection.swift:231-233)`.

#### `wifi_set`

```json
{"cmd":"wifi_set","ssid":"Home","password":"geheim"}
```

| Feld | Typ | Pflicht |
|---|---|---|
| `ssid` | String | ja, nicht leer `(serial_receiver.cpp:277)` |
| `password` | String | nein, Default `""` `(serial_receiver.cpp:276)` |

Das Gerät speichert die Zugangsdaten, versucht bis zu 10 s zu verbinden und antwortet mit `wifi_status` `(serial_receiver.cpp:281-283)`. Host-Timeout 15 s `(SettingsWindow+Connection.swift:280-284)`.

#### `wifi_forget`

```json
{"cmd":"wifi_forget"}
```

Löscht Zugangsdaten und trennt. Antwort: `wifi_status` `(serial_receiver.cpp:287-290)`. Host-Timeout 5 s `(SettingsWindow+Connection.swift:296-298)`.

#### `reboot`

```json
{"cmd":"reboot"}
```

Vom Gerät unterstützt `(serial_receiver.cpp:425-426)`, von der Mac-App nie gesendet.

### 5.2 Datenframe (Usage-Frame)

Gesendet mit AIM1-Framing oder im Zeilenmodus, siehe 3.3. Aufbau in `buildUsageEnvelope` `(main.swift:2841-3060)`.

#### Envelope

| Feld | Typ | Pflicht | Bedeutung | Host-Quelle | Geräte-Quelle |
|---|---|---|---|---|---|
| `schemaVersion` | Int | ja | immer 1 bei Usage-Frames | `(main.swift:2214, 3033)` | Schema 2 wird separat als Plugin-Szene geprüft |
| `frameId` | Int | ja für ACK | fortlaufend 1..999999, dann wieder 1 | `(main.swift:2337-2342)` | fehlt: -1, dann kein ACK `(serial_receiver.cpp:612)`, `(serial_receiver.cpp:130)` |
| `sentAt` | String | nein | ISO-8601 UTC, gleicher Wert wie `time` | `(main.swift:3035)` | wird nicht gelesen |
| `time` | String | nein | ISO-8601 UTC im Format `YYYY-MM-DDTHH:MM:SSZ`; setzt die Systemuhr des Geräts | `(main.swift:2517-2521, 3036)` | `(serial_receiver.cpp:454-461)`, Parser `(api_common.h:88-100)` |
| `displayTime` | String | nein | lokale Uhrzeit `HH:mm` in der gewählten Zeitzone | `(main.swift:2522-2526, 2893-2894)` | Puffer 6 Bytes, also maximal 5 Zeichen `(serial_receiver.cpp:65, 441-444)` |
| `tzOffsetMinutes` | Int | nein | Offset der gewählten Zeitzone zu UTC in Minuten, z. B. 120 | `(main.swift:2895)` | muss Integer sein, gültig in -840..840, setzt die TZ des Geräts `(serial_receiver.cpp:192-218, 446-451)` |
| `data` | Array | ja | genau ein Element wird gelesen: `data[0]` | `(main.swift:3039)` | `(serial_receiver.cpp:632-640)` |

Alle Felder des Envelopes außer `data[0]` sind aus Gerätesicht optional; fehlende Felder lassen den jeweiligen Zustand unverändert.

#### `data[0]`

| Feld | Typ | Pflicht | Bedeutung | Quelle |
|---|---|---|---|---|
| `source` | String | nein | `"codexbar"` bei echten Daten, `"diagnostic"` beim Testframe. Vom Gerät nicht gelesen | `(main.swift:3041)`, `(main.swift:2595)` |
| `provider` | String | nein | Provider-Schlüssel, siehe Tabelle unten. Fehlt er oder ist er unbekannt, gilt `claude` | `(main.swift:3042)`, `(serial_receiver.cpp:645-647)`, `(providers.cpp:87-108)` |
| `fetching` | Bool | nein | Abruf läuft gerade auf dem Host; das Gerät zeigt ein Refresh-Symbol. Fehlt: `false` | `(main.swift:3046)`, `(serial_receiver.cpp:657)`, `(ui_dashboard.cpp:896-898)` |
| `notice` | String | nein | Hinweistext; wenn vorhanden und nicht leer, wird `usage` ignoriert, siehe 5.3 | `(serial_receiver.cpp:659-671)` |
| `usage` | Objekt | ja, sofern kein `notice` | Nutzungsdaten | `(serial_receiver.cpp:673-681)` |

Provider-Schlüssel und Anzeige-Labels `(providers.cpp:14-68)`, `(CodexBarSource.swift:36-51)`:

| Wire-Key | Label auf dem Gerät | Default-Zeilentitel |
|---|---|---|
| `claude` | `CLAUDE` | Session, Weekly, Tertiary |
| `codex` | `CHATGPT` | Session, Weekly, Tertiary |
| `antigravity` | `ANTIGRAVITY` | Claude, Gemini Pro, Gemini Flash |
| `gemini` | `GEMINI` | Pro, Flash, Flash Lite |
| `copilot` | `COPILOT` | Premium, Chat, Extra |
| `cursor` | `CURSOR` | Plan, Auto, API |

Der Vergleich ist case-insensitiv, der String wird auf 15 Zeichen gekürzt `(providers.cpp:90-97)`.

#### `usage`

| Feld | Typ | Pflicht | Bedeutung | Quelle |
|---|---|---|---|---|
| `rows` | Array | ja (darf leer sein) | Anzeigezeilen, maximal 3 werden gelesen | `(main.swift:3004)`, `(serial_receiver.cpp:513-527)` |
| `loginMethod` | String | nein | Klartext-Label des Kontos, z. B. `"Claude Max"`. Das Gerät loggt es nur | `(main.swift:3005)`, `(CodexBarSource.swift:86-101)`, `(serial_receiver.cpp:590-593)` |
| `primary` | Objekt | nein | Fenster 1 (Session), nur wenn die Quelle es liefert | `(main.swift:3007-3013)` |
| `secondary` | Objekt | nein | Fenster 2 | `(main.swift:3014-3020)` |
| `tertiary` | Objekt | nein | Fenster 3 | `(main.swift:3021-3027)` |
| `providerCost` | Objekt | nein | `{"used":<Float>,"limit":<Float>}`; wird vom Gerät gelesen, von der Mac-App nie gesendet | `(serial_receiver.cpp:574-587)` |
| `credits` | Objekt | nein | Zusatz-Credits (Codex), siehe unten. Fehlt, wenn die Quelle nichts dazu meldet. Gesendet ab Mac-App 1.28.3 bzw. Windows-App 1.0.1. Ab Firmware 2.18.0 zeigt das Gerät bei `available:true` ein grünes Kennzeichen im Header: `+Cr` ohne Stand, sonst den Betrag (`+238`, `+2.5k`) | `(CodexBarSource.swift, credits(from:))`, `(codexbar.rs, credits_from)`, `(serial_receiver.cpp, parse_credits)` |
| `resetCredits` | Objekt | nein | Einlösbare Limit-Zurücksetzungen (Codex „Reset credits"), siehe unten. Nur bei Anzahl > 0. Ab Firmware 2.18.0 graues Kennzeichen `⟲ n` im Header; im Hochformat entfällt es, wenn der Platz nicht reicht | `(CodexBarSource.swift, resetCredits(from:))`, `(codexbar.rs)`, `(ui_dashboard.cpp, layout_header_center)` |

Fenster-Objekte `primary`/`secondary`/`tertiary`:

| Feld | Typ | Bedeutung | Quelle |
|---|---|---|---|
| `usedPercent` | Int (Host) / Float (Gerät) | Anzeigeprozent 0..100 | `(main.swift:3009)`, `(serial_receiver.cpp:469)` |
| `resetsAt` | String | ISO-8601 UTC `YYYY-MM-DDTHH:MM:SSZ` oder `""` | `(main.swift:2877-2879)`, `(serial_receiver.cpp:472-476)` |
| `windowMinutes` | Int | Fensterlänge in Minuten. Ab 10080 gilt ein Fenster als "weekly" | `(main.swift:2882-2884)`, `(serial_receiver.cpp:42, 482-492)` |

Das Gerät nutzt die Fenster-Objekte für die Legacy-Werte Session/Weekly `(serial_receiver.cpp:465-504)` und als Fallback, wenn `rows` leer ist `(serial_receiver.cpp:529-548)`. Für `antigravity` füllt es fehlende Zeilen bis auf 3 aus den Fenster-Objekten auf `(serial_receiver.cpp:553-568)`.

Objekt `credits`:

| Feld | Typ | Pflicht | Bedeutung |
|---|---|---|---|
| `available` | Bool | ja | `true`: Die Quelle meldet einen Credit-Pool. `false`: Sie meldet ausdrücklich keinen |
| `balance` | Zahl | nein | Verbleibende Credits, auf zwei Stellen gerundet. Fehlt, wenn der Stand nicht lesbar ist |

Den Stand des Workspace-Pools gibt OpenAI nur an Owner und Admins heraus. Für Mitglieder meldet die Quelle den Pool, hält den Betrag aber zurück. Dann kommt `{"available":true}` ohne `balance`, niemals eine 0. Bei einem persönlichen Monatslimit steht in `balance` dessen Rest. Die Werte stammen aus dem Block `credits` der Upstream-CLI bzw. aus `cost` (`period` `"Credits"` oder `"Monthly credits"`) bei Win-CodexBar.

Objekt `resetCredits`:

| Feld | Typ | Pflicht | Bedeutung |
|---|---|---|---|
| `count` | Int | ja | Anzahl verfügbarer Reset Credits, immer > 0 |
| `nextExpiresAt` | String | ja | Ablauf des nächsten Credits, ISO-8601 UTC oder `""`. Kein Reset-Zeitpunkt eines Fensters |

Fenster, die Win-CodexBar als `is_informational` kennzeichnet (etwa „No active 5h session" bei reinen Wochenplänen oder die Reset Credits), sendet die Windows-App weder als Zeile noch als `primary`/`secondary`/`tertiary`. Sie tragen keinen echten Prozentwert.

Zeilen-Objekte in `rows`:

| Feld | Typ | Pflicht | Bedeutung | Quelle |
|---|---|---|---|---|
| `id` | String | nein | Kennung, z. B. `"primary"`, `"row0"`, oder ID des Zusatzfensters. Vom Gerät nicht gelesen | `(main.swift:2919, 2956, 2971)` |
| `title` | String | nein | Zeilentitel; leer oder fehlend ergibt den Default-Titel des Providers. Puffer 20 Bytes, also maximal 19 Zeichen | `(serial_receiver.cpp:112-114)`, `(api_common.h:57)` |
| `usedPercent` | Zahl | nein, Default 0 | wird auf 0..100 geclampt | `(serial_receiver.cpp:108-110, 521)` |
| `resetsAt` | String | nein | ISO-8601 UTC oder `""`; Puffer 32 Bytes | `(serial_receiver.cpp:116-122)`, `(api_common.h:58)` |
| `windowMinutes` | Int | nein | Fensterlänge; vom Gerät in `rows` nicht gelesen | `(main.swift:2923)` |

Prozentlogik: Der Host rechnet die Anzeige-Prozent vor dem Senden um. Im Modus `used` sind es die verbrauchten Prozent, im Modus `remaining` die verbleibenden (`100 - used`) `(main.swift:2846-2869)`, `(main.swift:556-561)`. Das Feld heißt in beiden Fällen `usedPercent`; das Gerät zeigt den Wert unverändert an. Bei Zeilen mit `percentLeft` aus der Quelle wird dieser bevorzugt `(main.swift:2858-2869)`.

Zeilenaufbau im Host `(main.swift:2901-2997)`:

- Provider mit `usesModelRows` (nur `antigravity`): Zeilen aus den Zusatzfenstern (`extraWindows`, maximal 3) mit deren `id` und `title`; ohne Zusatzfenster drei feste Zeilen mit IDs `primary`/`secondary`/`tertiary` und Default-Titeln `(main.swift:2910-2943)`, `(CodexBarSource.swift:106-111)`.
- Alle anderen Provider: Zeilen aus `usageRows` der Quelle (maximal 3), sonst aus den vorhandenen Fenstern mit IDs `row0`..`row2`. Bleiben Plätze frei, werden Zusatzfenster angehängt `(main.swift:2944-2997)`.
- Fehlende `windowMinutes` ergänzt der Host provider-spezifisch: `claude`/`codex`/`antigravity` 300 für Index 0, sonst 10080; `gemini` 1440; `copilot`/`cursor` 43200 `(CodexBarSource.swift:143-152)`.

#### Beispiel: Usage-Frame für `claude` mit drei Zeilen

Payload, hier zur Lesbarkeit umgebrochen; auf dem Draht ist es eine Zeile ohne Zeilenumbruch `(main.swift:2715)`:

```json
{
  "schemaVersion": 1,
  "frameId": 42,
  "sentAt": "2026-09-10T13:30:00Z",
  "time": "2026-09-10T13:30:00Z",
  "displayTime": "15:30",
  "tzOffsetMinutes": 120,
  "data": [
    {
      "source": "codexbar",
      "provider": "claude",
      "fetching": false,
      "usage": {
        "rows": [
          {"id": "row0", "title": "Session", "usedPercent": 37, "resetsAt": "2026-09-10T17:00:00Z", "windowMinutes": 300},
          {"id": "row1", "title": "Weekly",  "usedPercent": 62, "resetsAt": "2026-09-14T09:00:00Z", "windowMinutes": 10080},
          {"id": "fable-weekly", "title": "Fable weekly", "usedPercent": 12, "resetsAt": "2026-09-14T09:00:00Z", "windowMinutes": 10080}
        ],
        "loginMethod": "Claude Max",
        "primary":   {"usedPercent": 37, "resetsAt": "2026-09-10T17:00:00Z", "windowMinutes": 300},
        "secondary": {"usedPercent": 62, "resetsAt": "2026-09-14T09:00:00Z", "windowMinutes": 10080}
      }
    }
  ]
}
```

Mit AIM1-Framing wird daraus (Länge exemplarisch):

```
AIM1 812 42
{"schemaVersion":1,"frameId":42,...}
```

Erwartete Antwort:

```json
{"type":"ack","frameId":42,"schemaVersion":1,"message":"accepted","bytes":812,"provider":"CLAUDE","rows":3,"heap":176000}
```

Die Reihenfolge der Schlüssel ist nicht festgelegt; der Host serialisiert ein Dictionary `(main.swift:2715)`.

### 5.3 Notice-Frame

Gleicher Envelope, aber `data[0]` trägt `notice`, `usage.rows` ist leer und es gibt keine Fenster-Objekte `(main.swift:2769-2825)`.

```json
{"schemaVersion":1,"frameId":43,"sentAt":"2026-09-10T13:30:05Z","time":"2026-09-10T13:30:05Z","displayTime":"15:30","tzOffsetMinutes":120,"data":[{"source":"codexbar","provider":"gemini","notice":"Bitte App starten","fetching":false,"usage":{"rows":[],"loginMethod":"Gemini CLI"}}]}
```

Das Gerät löscht alle Zeilen, zeigt den Text als Hinweis (Platzhalter `--` statt `ERR`) und antwortet mit `ack` und `bytes:0`, `rows:0` `(serial_receiver.cpp:659-671)`, `(ui_dashboard.cpp:854)`. Der Text landet in einem Puffer von 64 Bytes `(api_common.h:63)`.

Mögliche Texte auf dem Mac, je nach App-Sprache `(CodexBarSource.swift:190-204)`, `(Localizable.strings:87-92)`: `CodexBar-CLI fehlt`, `Abruf fehlgeschlagen`, `Lade Provider ...`, `Datenfehler`, `Daten veraltet`, `Bitte App starten` und die englischen Entsprechungen. Ein Notice-Frame wird nur gesendet, wenn die Quelle einen Status-Hinweis liefert oder ein Abruf ohne vorhandene Daten läuft; sonst wird gar nichts gesendet `(main.swift:2774-2781)`.

### 5.4 Diagnose-Testframe

Synthetischer Usage-Frame mit `source:"diagnostic"`, festen Werten 42/68/17 Prozent, drei Zeilen und `loginMethod:"AI Monitor Test"` `(main.swift:2532-2640)`. Wird nach erfolgreichem Flash beim nächsten Connect mit 1 s Verzögerung gesendet `(main.swift:2297-2304)`, `(main.swift:3448)` oder manuell aus dem Diagnose-Tab `(SettingsWindow+Diagnostics.swift:41)`. 20 s später sendet der Host wieder den echten Snapshot `(main.swift:2632-2634)`.

### 5.5 Textregeln

Die Firmware rendert nur druckbares ASCII. Der Host transliteriert Hinweistexte: Umlaute zu `ae`/`oe`/`ue`/`ss`, typografische Zeichen zu ASCII, alles außerhalb 0x20..0x7E wird entfernt `(main.swift:2744-2760)`. Diese Funktion wird nur auf `notice` angewendet `(main.swift:2782)`; Zeilentitel aus der Quelle werden unverändert übernommen.

---

## 6. Abläufe

### 6.1 Verbindungsaufbau

```
Host                                     Gerät
 |  Port öffnen, termios setzen             |
 |  state = probing                         |
 |  "\n" ------------------------------->   |
 |  200 ms warten                           |
 |  drainInput()                            |
 |  {"cmd":"get_info"}\n ---------------->  |
 |                                          |  [Serial] Command received: get_info
 |  <------------------------ {"type":"info",...}\n
 |  version, serialTransport, maxFrameBytes,|
 |  mac, display, brightness übernehmen     |
 |  state = connected                       |
 |  Profil auflösen (MAC)                   |
 |  onConnect:                              |
 |  {"cmd":"set_theme",...}\n ----------->  |
 |  <------------------------ {"type":"ok","cmd":"set_theme",...}   (nicht ausgewertet)
 |  {"cmd":"set_language",...}\n -------->  |
 |  {"cmd":"set_orientation",...}\n ----->  |
 |  {"cmd":"set_brightness",...}\n ------>  |
 |  120 ms Bündelung                        |
 |  Usage- oder Notice-Frame (AIM1) ----->  |
 |  <------------------------ {"type":"ack",...}\n
```

Quellen: `(main.swift:1787-1900)`, `(main.swift:2284-2306)`, `(main.swift:2681-2690)`. Die vier `set_*`-Kommandos werden nacheinander ohne Warten auf Antwort geschrieben `(main.swift:2292-2295)`. Jedes davon ruft `sendLastUsageSnapshotIfAvailable`, was per 120-ms-Debounce zu genau einem Frame zusammengefasst wird `(main.swift:2667-2690)`. Danach prüft der Host, ob die Firmware veraltet ist `(main.swift:2305)`, `(main.swift:2326-2335)`.

Profilauflösung nach `info` `(main.swift:1967-2046)`: Existiert ein Profil zur MAC, werden `brightness`, `displayVariant`, `lastSeenAt` und `firmwareVersion` aktualisiert. Existiert keines, aber ein `legacy-device`-Profil, wird es auf die echte MAC umgezogen. Sonst wird ein neues Profil mit Auto-Namen angelegt, Defaults aus dem zuletzt aktiven Profil oder `theme:"system"`, `orientation:"portrait"`, `language:"de"`, `brightness:80` `(main.swift:211-230)`.

Was nach dem Connect zum Gerät geht, kommt aus dem Geräteprofil: `theme` (auf `dark`/`light` aufgelöst), `language`, `orientation`, `brightness` `(main.swift:186-209)`, `(main.swift:2463-2497)`, `(main.swift:2644-2655)`. Die Zeitzone geht nicht als Kommando, sondern in jedem Datenframe über `displayTime` und `tzOffsetMinutes` `(main.swift:2499-2504)`. Die Board-Variante (`displayVariant`) wird nur gelesen, nie gesendet; sie bestimmt das Firmware-Asset beim Flashen `(main.swift:197-204)`, `(main.swift:3394-3395)`.

### 6.2 Datenframe mit ACK

```
Host                                     Gerät
 |  ioLock nehmen                           |
 |  drainInput()                            |
 |  "AIM1 <len> <id>\n" + payload + "\n" -> |
 |                                          |  Header parsen, <len> Bytes sammeln
 |                                          |  parse_json: schemaVersion, cmd?, time,
 |                                          |  data[0], provider, notice?, usage
 |  <------------------------ {"type":"ack","frameId":<id>,...}\n
 |  oder                                    |
 |  <------------------------ {"type":"error","frameId":<id>,...}\n
 |  bis 0,8 s warten, Zeilen ohne passende  |
 |  frameId überspringen                    |
 |  ioLock freigeben                        |
```

Quellen: `(main.swift:2069-2126)`, `(serial_receiver.cpp:599-708)`. Bleibt die Antwort aus, erzeugt der Host einen Receipt vom Typ `timeout` mit `message:"No ACK received"` `(main.swift:2116-2125)`. Ein Fehler-Receipt gilt als "gesendet, aber abgelehnt"; der Host zählt ihn nicht als unbestätigt `(main.swift:2389-2391)`.

Auslöser für Datenframes `(main.swift:2263-2317)`, `(main.swift:2246-2261)`:

| Auslöser | Verhalten | Quelle |
|---|---|---|
| Neue Daten der Quelle | Frame über 120-ms-Debounce | `(main.swift:2265-2277)` |
| Heartbeat | alle 60 s ohne Debounce | `(main.swift:74)`, `(main.swift:2313-2316)` |
| Provider-Wechsel | sofort über Debounce, auch ohne Daten (dann Notice) | `(main.swift:2249-2261)` |
| Connect | nach den `set_*`-Kommandos, über Debounce | `(main.swift:2296)` |
| Jedes `set_*`-Kommando | über Debounce | `(main.swift:2478, 2486, 2496)` |
| Zeitzonen- oder Prozentmodus-Wechsel | über Debounce | `(main.swift:2502-2511)` |

Der blockierende Sende-und-Warte-Zyklus läuft auf einer seriellen Queue, damit die Reihenfolge erhalten bleibt; Kommandos vom Hauptthread werden über `ioLock` serialisiert `(main.swift:2224-2230)`, `(main.swift:2722-2733)`.

### 6.3 Einstellung setzen

```
Host                                     Gerät
 |  {"cmd":"set_brightness","value":63,"persist":false}\n ->  PWM setzen
 |  ... weitere Vorschau-Werte ...          |
 |  0,45 s Ruhe                             |
 |  {"cmd":"set_brightness","value":65,"persist":true}\n -->  PWM setzen, NVS speichern
 |  <------------------------ {"type":"ok",...}   (nicht ausgewertet)
```

Für `set_theme`, `set_language`, `set_orientation`: ein Kommando, keine Antwortauswertung, danach ein Usage-Frame über den Debounce `(main.swift:2463-2497)`. Das Gerät baut bei Theme und Sprache das Dashboard neu; der nachgeschobene Frame füllt es `(main.swift:2475-2477)`.

### 6.4 Firmware-Flash und Reconnect

```
Host
 |  Port-Pfad der aktiven Verbindung merken            (main.swift:3389)
 |  stopScanning(): Timer aus, disconnect()             (main.swift:1740-1744, 3443)
 |  500 ms warten                                       (main.swift:1412)
 |  esptool --chip esp32 --port <port> --baud 460800 write_flash 0x0 <bin>
 |                                                      (main.swift:1418-1423), (main.swift:64)
 |  Phasen aus esptool-Ausgabe ableiten                 (main.swift:1441-1476)
 |  Exit 0: installedFirmwareVersion setzen             (main.swift:1488-1491)
 |  startScanning(): Timer an, sofortiger Scan          (main.swift:3446)
 |  Erfolg: Diagnose-Frame nach nächstem Connect        (main.swift:3448)
 |  Reconnect-Sperre 1 s nach disconnect                (main.swift:1662)
 |  Handshake wie 6.1
```

Das Firmware-Asset richtet sich nach der Board-Variante: `ili9341` = `ai-monitor.bin`, `st7789` = `ai-monitor-st7789.bin` `(main.swift:53-56)`. Nach dem Flash liefert das nächste `info` das `display`-Feld, das ins Profil übernommen wird `(main.swift:1863-1873)`.

### 6.5 Stale-Daten, Standby, unbestätigte Frames

Geräteseite `(serial_receiver.cpp:39)`, `(serial_receiver.cpp:800-806)`, `(serial_receiver.cpp:821-824)`, `(ui_dashboard.cpp:685-693)`, `(ui_dashboard.cpp:899-905)`:

- Nach 5 Minuten ohne gültigen Frame gilt der Zustand als abgelaufen: Status `No data (timeout)`, Statuspunkt orange, Standby-Uhr wird eingeblendet, sofern die Uhr gesetzt ist und kein Notice-Frame aktiv ist.
- `standby` setzt diesen Zustand sofort `(serial_receiver.cpp:295-302)`.
- Der nächste gültige Frame blendet die Standby-Uhr wieder aus `(ui_dashboard.cpp:184-192)`.

Hostseite `(main.swift:2376-2441)`:

- `ack`: Zähler unbestätigter Frames auf 0.
- `error`: Zähler auf 0, Statusdetail "Firmware meldet Fehler".
- `timeout`: Wenn die Firmware ACK unterstützt (Version >= 2.12.1 `(main.swift:2215)`, `(main.swift:2443-2448)`), Zähler +1. Ab 3 unbestätigten Frames in Folge `(main.swift:2217)`: `disconnect()`, nach 1,2 s `scanForPort()`, also ein neuer Handshake `(main.swift:2417-2441)`. Zwischen zwei solchen Reparaturen liegen mindestens 60 s `(main.swift:2218)`. Bei älterer Firmware wird nur ein Hinweis angezeigt.

---

## 7. Timeouts, Retries, Fehlerbehandlung

| Wert | Größe | Seite | Bedeutung | Quelle |
|---|---|---|---|---|
| Baudrate Betrieb | 115200 | beide | | `(main.swift:34)`, `(main.cpp:246)` |
| Baudrate Flash | 460800 | Host | esptool | `(main.swift:64)` |
| Port-Scan-Intervall | 3 s | Host | Timer | `(main.swift:35)` |
| Reconnect-Sperre | 1 s | Host | nach Disconnect kein Connect | `(main.swift:1662)` |
| Boot-Delay nach Öffnen | 200 ms | Host | vor `get_info` | `(main.swift:1816)` |
| Boot-Delay nach `Serial.begin` | 500 ms | Gerät | vor Banner | `(main.cpp:247)` |
| `get_info`-Timeout | 5 s | Host | sonst `foreignFirmware` | `(main.swift:1667)` |
| Späte-Antwort-Fenster | 8 s | Host | nach `foreignFirmware` | `(main.swift:1908)` |
| Poll-Scheibe `readLine` | 100 ms | Host | pro Byte-Poll | `(main.swift:2186)` |
| `drainInput`-Poll | 10 ms | Host | leert Eingang | `(main.swift:2202)` |
| Frame-ACK-Timeout | 0,8 s | Host | pro Datenframe, Leseschleife 0,25 s | `(main.swift:2071)`, `(main.swift:2090)` |
| Kommando-Timeout Default | 5 s | Host | `performJSONCommand` | `(main.swift:2130)` |
| `wifi_status`-Timeout | 4 s | Host | | `(SettingsWindow+Connection.swift:176)` |
| `wifi_scan`-Timeout | 18 s | Host | | `(SettingsWindow+Connection.swift:233)` |
| `wifi_set`-Timeout | 15 s | Host | Gerät versucht 10 s | `(SettingsWindow+Connection.swift:284)`, `(serial_receiver.cpp:282)` |
| `wifi_forget`-Timeout | 5 s | Host | | `(SettingsWindow+Connection.swift:298)` |
| Heartbeat | 60 s | Host | Usage-Frame | `(main.swift:74)` |
| Sende-Bündelung | 120 ms | Host | Debounce | `(main.swift:2689)` |
| Brightness-Persist-Debounce | 0,45 s | Host | | `(SettingsWindow+Display.swift:641)` |
| Diagnose-Frame nach Connect | 1 s | Host | | `(main.swift:2301)` |
| Rückkehr zum echten Snapshot | 20 s | Host | nach Diagnose-Frame | `(main.swift:2632)` |
| Auto-Reparatur-Schwelle | 3 Frames | Host | unbestätigte Frames in Folge | `(main.swift:2217)` |
| Auto-Reparatur-Abkühlung | 60 s | Host | | `(main.swift:2218)` |
| Auto-Reparatur-Reconnect | 1,2 s | Host | nach `disconnect()` | `(main.swift:2434)` |
| Flash-Vorlauf | 500 ms | Host | vor esptool-Start | `(main.swift:1412)` |
| Frame-Resync-Timeout | 2000 ms | Gerät | Teilframe verwerfen | `(serial_receiver.cpp:45)` |
| Daten-Timeout | 300000 ms | Gerät | Stale, Standby-Uhr | `(serial_receiver.cpp:39)` |
| Reboot-Verzögerung | 200 ms | Gerät | nach `ok` bei `reboot` | `(serial_receiver.cpp:394)` |
| Frame-ID-Bereich | 1..999999 | Host | dann Umbruch auf 1 | `(main.swift:2340)` |
| Frame-Größe | 4095 Bytes | beide | | `(serial_receiver.cpp:37)`, `(main.swift:1701)` |

Fehlerbehandlung ohne expliziten Retry: Datenframes werden nie wiederholt; der nächste Auslöser sendet den nächsten Frame `(main.swift:2692-2734)`. Kommandos werden nie wiederholt. Schreibfehler führen zu `disconnect()` und damit zum nächsten Scan `(main.swift:2056-2059)`.

---

## 8. Versionsmatrix

### 8.1 Versionsvergleich

Der Host vergleicht Versionen nach SemVer `(main.swift:740-833)`: Präfixe `fw-beta-v`, `fw-beta-`, `app-beta-v`, `app-v`, `v` werden entfernt; die numerischen Teile werden stellenweise verglichen, fehlende Stellen gelten als 0; ein finales Release ist neuer als jedes Prerelease derselben Nummer; Prerelease-Felder werden numerisch oder lexikalisch verglichen. Beispiel: `2.15.0-beta.3 < 2.15.0`, `2.12.3 >= 2.12.3`.

Ist keine Geräteversion bekannt, fällt der Host für die ACK- und Brightness-Prüfungen auf die zuletzt geflashte Version `installedFirmwareVersion` zurück `(main.swift:2444-2446)`, `(main.swift:2451-2453)`; für die Framing-Entscheidung gibt es diesen Fallback nicht `(main.swift:1694)`.

### 8.2 Verhalten je Firmware-Version

| Ab Firmware | Verhalten | Quelle |
|---|---|---|
| < 2.8.0 | `set_orientation`/`set_theme` lösten einen Reboot aus; USB-CDC brauchte danach 2 bis 3 s | `(main.swift:1658-1661)` |
| 2.8.0 | Orientierung und Theme live ohne Reboot; `brightness` im `info` | `(main.swift:1660)`, `(main.swift:1965)` |
| 2.9.0 | `provider`-Feld in `data[0]` steuert das Header-Label; davor statisch `CLAUDE` | `(main.swift:3029-3031)`, `(serial_receiver.cpp:642-644)` |
| 2.10.0 | `mac` im `info`; Per-Device-Profile | `(main.swift:97-99)`, `(serial_receiver.cpp:363-364)` |
| 2.10.1 | `display` im `info` | `(config.h:18)`, `(serial_receiver.cpp:370-372)` |
| 2.11.0 | `usage.rows[]` wird gelesen; davor nur `primary`/`secondary`/`tertiary` | `(serial_receiver.cpp:506-512)` |
| 2.12.1 | `ack`/`error` mit `frameId`; Host zählt unbestätigte Frames | `(main.swift:2215)`, `(main.swift:2401-2414)` |
| 2.12.3 | AIM1-Framing; `serialTransport` und `maxFrameBytes` im `info` | `(main.swift:1679)`, `(serial_receiver.cpp:11-13)` |
| 2.12.4 | `set_brightness` mit `persist:false` | `(main.swift:2216)`, `(serial_receiver.cpp:251-253)` |
| 2.15.0 | `notice`-Frame wird gerendert; ältere Firmware ignoriert das Feld und zeigt leere Zeilen | `(serial_receiver.cpp:649-653)`, `(main.swift:2766-2768)` |
| 2.15.0-beta.3 | `fetching` steuert das Refresh-Symbol | `(serial_receiver.cpp:654-657)` |
| 2.17.0 | Provider `gemini`, `copilot`, `cursor` | `(config.h:138-143)`, `(providers.cpp:39-67)` |
| 2.18.0 | `usage.credits` und `usage.resetCredits` als Kennzeichen im Header | `(serial_receiver.cpp, parse_credits)`, `(ui_dashboard.cpp, layout_header_center)` |
| 2.18.1 | Funkmodul startet nur mit gespeicherten WLAN-Zugangsdaten; kein USB-Abfall mehr beim ersten Boot nach einem Flash | `(wifi_time.cpp, wifi_time_init)` |

Unbekannte Felder werden von der Firmware ignoriert (ArduinoJson-Zugriff per Schlüssel), unbekannte Provider fallen auf `claude` zurück `(providers.cpp:107)`.

### 8.3 Verhalten je App-Version (zur Einordnung)

| Ab App | Verhalten | Quelle |
|---|---|---|
| 1.12.0 | Zeitzone wählbar, `displayTime` und `tzOffsetMinutes` daraus | `(main.swift:2891-2892)` |
| 1.14.0 | Per-Device-Profile, MAC als Schlüssel, alle `set_*` bei Connect | `(main.swift:94)`, `(main.swift:2287-2291)` |
| 1.14.2 | Verbindungszustände `probing`/`connected`/`foreignFirmware` | `(main.swift:1623-1641)` |
| 1.15.0 | Board-Variante im Flash-Dialog aus `display` | `(main.swift:47-56)` |
| 1.24.0 | Antigravity-Zeilen aus Zusatzfenstern | `(main.swift:2911-2914)` |
| 1.28.0 | Provider `gemini`, `copilot`, `cursor` | `(CodexBarSource.swift:40-51)` |
| 1.28.3 | `usage.credits` und `usage.resetCredits` (Windows-App ab 1.0.1) | `(CodexBarSource.swift, credits(from:))` |
| 1.28.4 | `get_info` wird im Handshake jede Sekunde wiederholt; Lesefehler lösen ein Neuöffnen des Ports aus | `(main.swift, sendGetInfo, markPortLost)` |

---

## 9. Offene Punkte für die Windows-Implementierung

### 9.1 DTR, RTS und Reset-Verhalten

Der Mac-Code setzt DTR und RTS nicht explizit und verändert `HUPCL` nicht `(main.swift:1792-1805)`. Ob das Öffnen oder Schließen des Ports auf dem Mac einen Reset des ESP32 auslöst, ist aus dem Code nicht ableitbar. Der Kommentar zu `kReconnectBlockWindow` erwähnt Reconnects "nur nach Flash oder Hard-Reset" `(main.swift:1658-1661)`, was dafür spricht, dass ein normales Öffnen keinen Reset auslöst. Unter Windows entscheidet die Serial-Bibliothek, ob DTR/RTS beim Öffnen gesetzt werden. Zu klären: Welche Leitungszustände die Windows-App beim Öffnen setzt, damit das Gerät nicht in den Bootloader fällt oder neu startet. Das 200-ms-Boot-Delay und der 5-s-Handshake-Timeout sollten übernommen werden; falls das Öffnen unter Windows einen Reset auslöst, reicht das Boot-Delay nicht (die Firmware wartet allein 500 ms vor dem Banner `(main.cpp:247)`).

**Ergänzung aus dem Spike vom 10. September 2026 (Plan Phase 0, Punkt 5):** Die CYD nutzt einen CH340 mit der üblichen Auto-Reset-Schaltung, die nur bei unterschiedlichem Pegel von DTR und RTS einen Reset auslöst. `serialport-rs` setzt unter Windows beim Öffnen `DTR_CONTROL_DISABLE` und bei `FlowControl::None` auch `RTS_CONTROL_DISABLE`, beide Leitungen sind also gleich. Rezept für die Windows-App: `serialport::new(port, 115200).flow_control(FlowControl::None)` ohne `dtr_on_open`, nach dem Öffnen DTR und RTS nicht anfassen, 200 ms warten, dann `get_info`. Der empirische Nachweis auf Windows steht aus. espflash löst nach dem Flashen einen Hard-Reset über die Leitungen aus; die Mac-App verbindet sich danach normal wieder (geprüft mit espflash 4.6.0 gegen Firmware 2.17.0).

### 9.2 Port-Erkennung

Der Mac filtert auf den Dateinamen-Präfix `cu.usbserial-` `(main.swift:1750)`; USB-Vendor- und Product-IDs stehen nirgends im Code. Für Windows fehlt eine Vorgabe, welche COM-Ports als Kandidaten gelten. Die Auswahlregel "manuell gewählter Port, sonst erster Eintrag der sortierten Liste" ist übertragbar; die Sortierung von COM-Namen ist lexikalisch nicht numerisch.

**Ergänzung aus dem Spike vom 10. September 2026:** Der USB-Serial-Chip der CYD ist ein CH340 mit Vendor-ID `0x1A86` und Product-ID `0x7523` (per `ioreg` am Board „Home“ bestätigt). Die Windows-App filtert Kandidaten über `serialport::available_ports()` nach `UsbPortInfo` mit dieser ID; CP2102 (`0x10C4:0xEA60`) zusätzlich zulassen, falls Boards mit diesem Chip auftauchen. Manuelle Auswahl bleibt als Fallback.

### 9.3 Nicht ausgewertete Antworten

Der Mac liest die `ok`-Antworten der `set_*`-Kommandos und `standby` nie; sie werden beim nächsten `drainInput` verworfen `(main.swift:2063-2066)`, `(main.swift:2078)`. Eine Windows-Implementierung muss unaufgeforderte `ok`- und `error`-Zeilen sowie Log-Zeilen jederzeit tolerieren, auch während sie auf ein `ack` wartet. Ebenso werden `error`-Zeilen ohne `frameId` nirgends ausgewertet.

### 9.4 `drainInput` vor jedem Senden

Vor jedem Datenframe und jedem Kommando mit Antwort leert der Host den Eingang `(main.swift:2078)`, `(main.swift:2158)`. Das ist ein Timing-Verhalten, kein Protokollmerkmal: Antworten auf frühere Nachrichten gehen dadurch verloren. Zu entscheiden, ob Windows das nachbildet oder einen Zeilenparser mit Typ-Dispatch verwendet.

### 9.5 Frame-ID im Header

Das Gerät nutzt die Frame-ID im AIM1-Header nur für die Fehlermeldung `Invalid frame length` `(serial_receiver.cpp:162-173)`; das ACK trägt die `frameId` aus der Payload `(serial_receiver.cpp:612)`. Beide sollten identisch gesendet werden, wie es der Mac tut `(main.swift:1706)`, `(main.swift:2072)`.

### 9.6 `time` und `sentAt`

Beide Felder tragen denselben Wert `(main.swift:3035-3036)`. Das Gerät liest nur `time` `(serial_receiver.cpp:454)`. Das Format muss exakt `YYYY-MM-DDTHH:MM:SSZ` sein, da der Parser per `sscanf` genau dieses Muster erwartet `(api_common.h:92)`; Millisekunden oder Offsets wie `+02:00` werden nicht erkannt und liefern 0, dann bleibt die Uhr ungesetzt.

### 9.7 `usedPercent` unter dem Prozentmodus

Im Modus `remaining` enthält `usedPercent` die verbleibenden Prozent `(main.swift:2848-2856)`. Das Gerät kennt den Modus nicht. Die Windows-App muss dieselbe Umrechnung vor dem Senden durchführen, sonst weichen die Anzeigen ab.

### 9.8 Zeichensatz der Zeilentitel

`displaySafeText` wird nur auf `notice` angewendet `(main.swift:2782)`; Zeilentitel aus der Quelle gehen roh durch `(main.swift:2951-2953)`. Nicht-ASCII in Titeln erscheint auf dem Gerät als Kästchen `(main.swift:2736-2743)`. Ob Windows die Titel ebenfalls transliterieren soll, ist zu entscheiden.

### 9.9 Firmware-Version ohne `info`

Ohne `info`-Antwort gibt es keine Geräteversion. Der Mac nutzt für ACK- und Brightness-Entscheidungen die zuletzt geflashte Version als Fallback `(main.swift:2444-2446)`, für die Framing-Entscheidung nicht `(main.swift:1694)`. Da im Zustand `foreignFirmware` ohnehin nichts gesendet wird `(main.swift:1684)`, ist der Fallback in der Praxis nur für die Anzeige relevant. Zu klären, ob Windows ihn übernimmt.

### 9.10 Reihenfolge nach Connect

Die vier `set_*`-Kommandos werden ohne Pause hintereinander geschrieben `(main.swift:2292-2295)`. Das Gerät verarbeitet sie sequentiell aus dem 4096-Byte-RX-Puffer `(main.cpp:245)`; Theme und Sprache lösen je einen Dashboard-Neuaufbau aus `(serial_receiver.cpp:324, 348)`. Ob dieser Burst unter Windows mit anderer Treiber-Latenz Probleme macht, ist nicht aus dem Code ableitbar.

### 9.11 `reboot` und `providerCost`

Beide sind auf dem Gerät implementiert `(serial_receiver.cpp:392-396)`, `(serial_receiver.cpp:574-587)`, werden von der Mac-App aber nie gesendet. Sie sind Teil der Firmware-Schnittstelle, nicht des aktuell genutzten Protokolls.

### 9.12 Thread-Modell

Die Mac-App serialisiert Datenframes über eine eigene Queue und schützt alle Zugriffe auf den Port mit einem Lock `(main.swift:2224-2230)`, `(main.swift:1657)`. `get_info` beim Connect wird ohne diesen Lock geschrieben `(main.swift:1823-1826)`. Eine Windows-Implementierung braucht eine äquivalente Serialisierung, damit ein Kommando nicht in das Warten auf ein ACK hineinschreibt.

---

## 10. Fensterverwaltung ab Firmware 2.19.0

Mac-App (ab 1.30.0) und Windows-App speichern eine geordnete Liste von 1 bis 8 Fenstern. Ein Fenster enthält einen der sechs bekannten Provider, `clock` oder einen installierten Plugin-Schlüssel wie `plugin:org.example.status`. Ein Inhalt darf mehrfach verwendet werden. Fenster 1 bleibt bestehen, sein Inhalt kann geändert werden. Ohne gespeicherte Liste gilt der zuletzt gewählte Provider als Fenster 1. Im manuellen Modus belegt eine Providerwahl im Kopf, Tray oder Menü das aktive Fenster oder springt auf ein Fenster mit diesem Provider. Quelle: `companion-windows/src-tauri/src/settings.rs`, `companion-windows/src-tauri/src/commands.rs`, `companion/Sources/main.swift` (`Settings.displayViews`, `UsageMonitor.setSelectedProvider`).

Nach dem Handshake senden beide Apps ab Firmware 2.19.0 (Vergleich gegen `2.19.0-0`, damit auch `-dev` und `-beta.x` zählen) zusätzlich zu Theme, Sprache, Orientierung und Helligkeit dieses Zeilenkommando. Bei Änderungen sendet sie es erneut:

```json
{"cmd":"set_views","views":["codex","clock","claude"],"mode":"automatic","interval":10,"active":0}
```

`views` enthält 1 bis 8 Einträge aus `claude`, `codex`, `antigravity`, `gemini`, `copilot`, `cursor`, `clock` oder `plugin:<id>`. Ein Plugin-ID hat höchstens 40 Zeichen aus `a-z`, `0-9`, Punkt, Bindestrich und Unterstrich. Unbekannte Inhalte werden abgelehnt. `active` ist der nullbasierte Index. `mode` ist `manual` oder `automatic`; `interval` liegt zwischen 2 und 3600 Sekunden. Das Gerät bestätigt mit `{"type":"ok","cmd":"set_views","count":3}` oder lehnt die gesamte ungültige Konfiguration mit `type:error` ab. Die gültige Konfiguration liegt auch im NVS und bleibt nach einem Neustart erhalten. Ein kurzer Touch auf der linken Displayhälfte wählt das vorherige Fenster, rechts das nächste; ein langer Touch öffnet die Einstellungen und schließt sie dort wieder. Im automatischen Modus wechselt die Firmware selbst nach dem Intervall. Touch- und Timer-Wechsel sind erst aktiv, nachdem in der laufenden Sitzung ein `set_views` angekommen ist; bis dahin bleibt die gespeicherte Auswahl stehen. Quelle: `src/serial_receiver.cpp`, `src/ui_dashboard.cpp`, `src/ui_settings.cpp`.

Jeder Provider erhält weiterhin einen eigenen Datenframe im bestehenden Schema 1. Zusätzlich steht in `data[0]` der Index des Fensters, z. B. `"viewIndex":2`. Die Firmware prüft, ob Index und Provider zur Konfiguration passen, und speichert den Zustand pro Fenster. Für `clock` geht kein Usage-Frame raus; die Uhr nutzt die Systemzeit aus den anderen Frames beziehungsweise NTP. Weil die Frames einzeln übertragen werden, gilt die Grenze von 4095 Bytes weiterhin pro Datenquelle. Quelle: `companion-windows/src-tauri/src/serial_service.rs`, `src/serial_receiver.cpp`.

Fenster-Konfiguration und Datenframes werden nur an Firmware ab 2.19.0 geschickt. Ältere Firmware erhält weiterhin den einzelnen Datenframe des in der Übersicht gewählten Providers. Ein Datenframe ohne `viewIndex` (ältere App-Version) aktiviert auf neuer Firmware zur Laufzeit eine einzelne Provider-Ansicht und schaltet Touch- und Timer-Wechsel ab, unabhängig von der gespeicherten Fensterliste. Diese Liste bleibt im NVS erhalten und wird beim nächsten `set_views` oder Neustart wiederhergestellt. Quelle: `companion-windows/crates/core/src/protocol.rs`, `companion-windows/src-tauri/src/serial_service.rs`, `src/serial_receiver.cpp`.

Beide Apps fragen nach dem Verbinden mit `{"cmd":"get_views"}` die Geräteauswahl ab und senden erst danach `set_views` und die Datenframes. Das Gerät antwortet mit einer Zeile wie `{"type":"view_state","views":["codex","clock"],"mode":"manual","interval":10,"active":1}`. Nach einem kurzen Touch sendet es dieselbe Nachricht unaufgefordert. Stimmen Liste, Modus und Intervall mit den App-Einstellungen überein, übernimmt die App den aktiven Index und speichert ihn. Dadurch bleibt die Touch-Auswahl nach Reconnect und Neustart erhalten. Die Mac-App liest unaufgeforderte Zeilen jede Sekunde sowie vor jedem Frame und reicht `view_state` weiter (`SerialPortManager.drainInput`). Quelle: `src/serial_receiver.cpp`, `companion-windows/src-tauri/src/serial_service.rs`, `companion/Sources/main.swift`.

## 11. Display-Szenen für Plugins

Ein Gerät mit `sceneProtocol:1` akzeptiert für ein zuvor per `set_views`
zugewiesenes Plugin-Fenster einen Datenframe mit `schemaVersion:2`:

```json
{"schemaVersion":2,"frameId":18,"data":[{"pluginId":"org.example.status","viewIndex":1,"scene":{"background":1580575,"nodes":[{"type":"text","x":50,"y":50,"w":900,"h":150,"color":16777215,"font":24,"text":"Status: Ready"}]}}]}
```

`pluginId` muss exakt zum Schlüssel `plugin:<id>` an `viewIndex` passen.
Die Firmware bestätigt einen gültigen Frame mit `type:ack`, `schemaVersion:2`
und demselben `frameId`. Ein ungültiger Frame verändert die bisherige Szene
nicht. Für jedes Fenster wird eine eigene Szene im RAM gehalten. Ein Wechsel
oder Neustart des Geräts braucht deshalb neue Szenenframes vom Companion.

Die Szene enthält höchstens 24 Knoten und höchstens 1536 JSON-Bytes. Ein
vollständiger serieller Frame bleibt unter `maxFrameBytes` (derzeit 4095).
Koordinaten `x`, `y`, `w`, `h` sind Ganzzahlen auf einer Fläche von 0 bis 1000;
Breite und Höhe müssen positiv sein und innerhalb der Fläche bleiben. Farben
sind RGB-Werte von `0` bis `0xFFFFFF`. Unterstützte Knotentypen sind `text`,
`rect`, `circle` und `bar`. `text` hat bis zu 64 druckbare ASCII-Zeichen und
eine Schriftgröße aus `12`, `14`, `16`, `20`, `24`, `36`, `48`; `align` kann
`left`, `center` oder `right` sein. `bar` ergänzt `trackColor` und `value`
von 0 bis 100. Der Companion wählt die Hoch- oder Querformat-Szene aus dem
Pluginpaket; die Firmware skaliert die normierten Koordinaten auf das Display.
Der Companion wählt auf dem ST7701-S3-Board eine eigene quadratische Szene,
sofern das Paket eine enthält; sonst verwendet er die Hochformat-Szene.
Das Paketformat und ein vollständiges Wetterbeispiel stehen in
[`display-plugins.md`](display-plugins.md).
