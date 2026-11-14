# Hardware-Test ESP32-S3-4848S040

Eigenständiges PlatformIO-Projekt, um das 4"-Board (ST7701S, 480×480, GT911) vor der eigentlichen Firmware-Anbindung zu prüfen. Es ist nicht Teil des Release-Builds.

Die spätere [Standalone-Teilabnahme vom 14.11.2026](standalone-2026-11-14.md)
prüft die eigentliche Entwicklungsfirmware aus PR #30 auf diesem Board und
trennt bestätigte Geräteergebnisse von noch offenen WLAN- und Sichtprüfungen.

## Flashen

```bash
cd hardware-test/esp32s3-4848s040
pio run -e 4848s040 -t upload --upload-port /dev/cu.usbserial-XXXX
pio device monitor --port /dev/cu.usbserial-XXXX
```

Die Umgebung `4848s040-ohne-bb` ist dieselbe Firmware ohne Bounce Buffer. Sie dient nur zum Vergleich, falls das Bild auf Seite 3 unruhig ist.

Die Werksfirmware wird dabei überschrieben. Wer sie behalten will, sichert sie vorher:

```bash
esptool.py --chip esp32s3 --port /dev/cu.usbserial-XXXX -b 460800 read_flash 0 0x1000000 werksfirmware-4848s040.bin
```

## Ergebnis vom 17.09.2026

Alles bestätigt: Timings und Auflösung (vollständiger 1-px-Rahmen), Farbzuordnung aller 16 Datenpins (saubere Verläufe), native Ausrichtung passend zur Aufstellung mit USB rechts, GT911 deckungsgleich mit der Anzeige, Backlight-PWM sauber bei 1 kHz.

Der Bildaufbau reißt ab, sobald ins Flash geschrieben wird: Der Zwischenspeicher ist dabei abgeschaltet, der Treiber kommt nicht an den Framebuffer im PSRAM. Ein solcher Aussetzer verschiebt das Bild dauerhaft nach oben (was oben herausläuft, kommt unten wieder herein). Gemessen wird das über die Bildanfang-Meldung des Panels: Ein Bild dauert dann rund 49 statt 28 ms.

| Last | Aussetzer |
|---|---|
| Leerlauf mit Animation, 15 min | 0 |
| Dauerschreiben in den NVS, 90 s | 3 |

Weder `esp_lcd_rgb_panel_restart()` noch eine erneute ST7701-Init-Sequenz holen das Bild zurück, nur ein Neustart. Niedrigerer Pixeltakt und größerer Puffer verzögern das Problem, verhindern es aber nicht.

**Folge für die Firmware (bis 28.09.2026):** feste Werte 10 MHz Pixeltakt und 19200 px Bounce Buffer (rund 35 Bilder/s), kein WLAN, und im Betrieb keine Schreibzugriffe ins Flash. Die Einstellungen kamen von der Host-App. Überholt, siehe unten.

Die Umgebung `4848s040-idf` sollte das Problem an der Wurzel beheben, indem Programmcode ins PSRAM wandert und der Zwischenspeicher nicht mehr abgeschaltet werden muss. Sie scheiterte zunächst an `No module named 'SCons.Tool.FortranCommon'` und war nicht weiterverfolgt.

## Ergebnis vom 28.09.2026: Ursache behoben

Der SCons-Fehler kommt von der Plattform 55.03.311: Sie tauscht mitten im Build das SCons-Paket aus, beim Linken fehlt dann das Modul. Mit 55.03.312 baut `4848s040-idf` durch. Die Konfiguration stammt aus dem evcc-Garagendisplay (gleiches Board, stabil mit WLAN und OTA):

```ini
custom_sdkconfig =
    CONFIG_SPIRAM_XIP_FROM_PSRAM=y          ; Code und Konstanten aus dem PSRAM, Cache bleibt beim Flash-Schreiben an
    CONFIG_LCD_RGB_ISR_IRAM_SAFE=y          ; Bildausgabe laeuft auch bei gesperrtem Flash weiter
    CONFIG_LCD_RGB_RESTART_IN_VSYNC=y       ; faengt ein verrutschtes Bild im naechsten Bild wieder
    CONFIG_GDMA_CTRL_FUNC_IN_IRAM=y
    CONFIG_ESP32S3_DATA_CACHE_LINE_64B=y    ; mehr Durchsatz aus dem PSRAM
```

Messung mit unveränderten Werten (10 MHz, 19200 px Bounce Buffer), Bild dabei durchgehend ruhig:

| Last | Aussetzer |
|---|---|
| Leerlauf, 30 s | 0 |
| Dauerschreiben in den NVS, 90 s (449 Schreibzugriffe) | 0 |
| 12 WLAN-Scans, 60 s | 0 |
| NVS-Schreiben und WLAN-Scans gleichzeitig, 60 s (304 Schreibzugriffe) | 0 |
| WLAN an ohne Stromsparmodus, 30 s | 0 |

Bildrate durchgehend 35,2 Bilder/s. Der erste Build kompiliert das ESP-IDF neu und dauert je nach Rechner 5 bis 25 Minuten.

**Folge für die Firmware:** Die S3-Umgebung übernimmt Plattform und `custom_sdkconfig`. WLAN und Schreibzugriffe ins Flash sind damit auch auf diesem Board erlaubt.

## Prüfliste

**Beim Start (serieller Monitor)**
- Chip ESP32-S3, 16 MB Flash, rund 8 MB PSRAM, Arduino-Core 3.x
- `[Display] ST7701S initialisiert`, GT911 an 0x5D oder 0x14

**Seite 1: Farben**
- Weißer 1-px-Rahmen an allen vier Kanten vollständig sichtbar
- Orangefarbenes Dreieck oben links: Wo sitzt es am Gehäuse?
- Vier Verläufe (Rot, Grün, Blau, Grau) laufen gleichmäßig von dunkel nach hell, ohne Sprünge oder Farbstiche
- Felder R, G, B zeigen wirklich Rot, Grün, Blau (nicht vertauscht)

**Seite 2: Touch**
- Tippen auf die fünf Kreuze: Der Punkt landet im Kreis, nicht gespiegelt oder gedreht
- Wischen über die Helligkeitsleiste regelt das Backlight stufenlos, ohne Flackern oder Pfeifen
- Falls es pfeift oder flackert: seriell `f150` oder `f20000` ausprobieren

**Serielle Befehle**

`b<0..100>` Helligkeit, `f<hz>` PWM-Frequenz, `p` Seite, `t` automatischer Lasttest, `n` Dauerschreiben an/aus, `r` Schreibstöße alle 15 s, `w` WLAN-Scan, `d` WLAN aus, `x` Panel-Restart, `g` Init-Sequenz erneut, `i` Infos. Alle 10 s meldet die Firmware Bildrate und Aussetzer.

Achtung: Das Öffnen des seriellen Ports startet das Board neu, jede Messung beginnt also mit einem Boot.

**Seite 3: Drift**
- Raster und Rahmen bleiben ruhig, während der Zähler der NVS-Schreibzugriffe läuft
- Seriell `w` schickt zusätzlich einen WLAN-Scan: Bild bleibt trotzdem ruhig?
- Das bewegte Feld läuft flüssig, ohne Risse; Bilder/s notieren
