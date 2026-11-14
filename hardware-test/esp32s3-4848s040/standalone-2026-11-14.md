# Standalone-Teilabnahme am S3, 14.11.2026

Getestet wurde ein ESP32-S3-4848S040 mit ST7701, 480 × 480 und GT911.
Dies ist eine begrenzte Geräteprüfung, keine Freigabe für alle Boards oder
für den WLAN-Dauerbetrieb.

## Firmware und Rücksicherung

- Ausgangszustand: Firmware 2.23.0, `sceneProtocol: 1`, kein eingerichtetes WLAN.
- Testquelle: Commit `36edce547d964f3b468635153f8a3d00edf7d2e1` aus PR #30.
- Neues Image: 1.844.240 Bytes, SHA-256
  `cc214c4b0d36ef88d962841a7a680c827fd93c1755b63072d97637cdcb152f5c`.
- Versionsnummer unverändert 2.23.0; das laufende Gerät meldet
  `sceneProtocol: 2` und `standaloneProtocol: 1`.

Vorher wurden sämtliche 16.777.216 Flash-Bytes gesichert. Bei 115200 Baud und
einem einzelnen ausstehenden 4096-Byte-Paket funktionierte der zuvor instabile
Leseweg. Jeder 64-KiB-Block wurde geprüft; nachweislich gelöschte Blöcke wurden
über die Geräteprüfsumme identifiziert. Die Gesamtprüfsummen des Geräts vor und
nach der Sicherung stimmten mit der lokalen Datei überein. Eine zusätzliche
SHA-256-Prüfung bestätigte die dauerhaft gespeicherte Kopie. Die Sicherung
enthält NVS und bleibt geschützt außerhalb des Repositories.

Partitionstabelle und OTA-Auswahl wurden geprüft: app0 liegt bei `0x10000`.
Ausschließlich das Anwendungsimage wurde dort geschrieben; Bootloader,
Partitionstabelle und NVS wurden nicht mit einem Factory-Image überschrieben.
Die automatische Schreibprüfung und ein separater `verify-flash`-Durchlauf
waren erfolgreich.

## Erste Geräteprüfung ohne WLAN

| Prüfung | Beobachtetes Ergebnis |
|---|---|
| Start und Fähigkeiten | ST7701 erkannt; beide neuen Protokollfähigkeiten gemeldet |
| UTF-8-Szene | Sieben Schriftgrößen mit `ÄÖÜ äöü ß 12 °C`, ACK für Frame 9301 |
| Ungültiges Zeichen | Szene mit Eurozeichen als ungültig abgelehnt, Frame 9302 |
| Speicherinitialisierung | Zuvor vollständig gelöschter Dateisystembereich explizit initialisiert |
| Profiltransfer | Öffentliches Status-Testprofil gespeichert; Digest und Aktivierung zurückgelesen |
| Fehlerhafter Transfer | Falscher Digest mit `transfer_digest` abgelehnt; bestehendes Profil unverändert |
| Aktivierung | Aktivieren und Deaktivieren bestätigt |
| Neustart | Profil samt Digest sowie aktivierter und deaktivierter Zustand bleiben erhalten |
| Wiederholtes Setup | Bereits gespeichertes, deaktiviertes Profil bleibt unverändert |
| Entfernen | Profil nach Entfernen und anschließendem Neustart weiterhin abwesend |
| Host verabschiedet sich | `standby` wechselt unmittelbar von `usb` nach `waiting_wifi` |
| Diagnoseabfragen | `get_views` und Statusabfragen übernehmen die Anzeige nicht |
| Host kehrt zurück | Gültiges `set_views` stellt Zustand `usb` wieder her |
| Display-Zähler | `frameGlitches: 0` an allen abgefragten Messpunkten |

Der kleinste abgefragte freie Heap betrug 149.540 Bytes. Das ist ein Stichprobenwert
ohne TLS-Last, kein gemessener Mindest-Heap oder Nachweis ausreichender
Speicherreserve während HTTPS. Neustarts erfolgten per Gerätebefehl; die Tests
simulieren keinen Stromausfall während eines Schreibvorgangs.

Nach dieser ersten Phase wurden Testprofil und Testansicht entfernt und die
installierte Companion-App wieder gestartet.

## Sichtprüfung und WLAN-/HTTPS-Prüfung

Anschließend wurde das S3 für die fortgesetzte Abnahme mit dem vom Nutzer
angegebenen WLAN eingerichtet. Das Passwort wurde über eine geschützte
Einmaleingabe übertragen und deren temporäre Datei anschließend gelöscht.
Zugangsdaten und Rohprotokolle werden nicht im Repository veröffentlicht.

Der Nutzer bestätigte für die erneut angezeigten sieben Zeilen
`ÄÖÜ äöü ß 12 °C` in den Schriftgrößen 12, 14, 16, 20, 24, 36 und 48:
**alles lesbar, Bild stabil**. Das ergänzt die technische Frame-Bestätigung um
eine tatsächliche Sichtprüfung auf diesem S3.

| Prüfung | Beobachtetes Ergebnis |
|---|---|
| WLAN und Uhrzeit | `wifiConnected: true`, `timeSynced: true`; keine Host-Zeit gesetzt |
| Öffentliche Statusquelle | GitHub-Statusprofil wird `fresh`, ohne Fehler und mit Erfolgsalter |
| Wiederholte Aktualisierung | Gepaarte Laufzeit-/Altersabfragen ergeben mindestens zwei Aktualisierungen im Abstand von etwa 60–61 Sekunden |
| Wetterquelle | Open-Meteo-Profil für den öffentlichen Beispielort Köln wird `fresh`; kein Nutzerstandort verwendet |
| Neustart mit WLAN | Nach Gerätebefehl-Neustart WLAN, vertrauenswürdige Uhrzeit und gespeichertes Wetterprofil wieder aktiv; bei Laufzeit 15 s bereits ein erfolgreicher Abruf |
| Abgelaufenes Zertifikat | `expired.badssl.com` ergibt `tls_error`; Geräteprotokoll bestätigt X.509-Prüffehler und fehlgeschlagenen TLS-Handshake |
| Falscher Zertifikats-Hostname | `wrong.host.badssl.com` ergibt nur `request_timeout`; kein Nachweis einer Hostnamen-Ablehnung |
| USB während verzögertem Abruf | Fünf-Sekunden-Quelle zunächst `loading`; `set_views` und UTF-8-Szene akzeptiert, danach `usb` ohne akzeptiertes Netzwerkergebnis; nach `standby` wieder `fresh` |
| Antwort in Teilstücken | Profil mit `https://httpbin.org/stream/1` wird `fresh`; separate Host-Abfrage bestätigt Chunked-Framing ohne Content-Length |
| Zu große Antwort | 9.000-Byte-Quelle `https://httpbin.org/stream-bytes/9000?chunk_size=1024` wird mit `response_too_large` abgelehnt |
| Ungültige JSON-Daten | HTML-Antwort von `https://httpbin.org/html` wird mit `json_root` abgelehnt |
| Komprimierte Antwort | `https://httpbin.org/gzip` wird mit `http_encoding` abgelehnt; separate Host-Abfrage bestätigt gzip |
| Umleitungsquelle | `https://httpbin.org/redirect/1` wird mit `http_status` abgelehnt; separate Host-Abfrage liefert 302, der konkrete Gerätestatus wurde nicht aufgezeichnet |
| Display-Zähler | Weiterhin `frameGlitches: 0` an allen abgefragten Messpunkten |
| S3-Touch: Einstellungen und Rückkehr | Nutzer bestätigt: Langes Drücken öffnet die Geräteeinstellungen; „Zurück“ führt wieder zur Plugin-Anzeige |

Die Refresh-Messreihe enthält die Paare Geräte-Laufzeit/Erfolgsalter
`305/15`, `334/44`, `364/13`, `393/42`, `422/11` Sekunden. Abfragen erfolgen
nacheinander und erlauben keine millisekundengenaue Intervallmessung.

Der kleinste abgefragte freie Heap der manuellen WLAN-Tests vor dem
24-Stunden-Dauerlauf betrug 103.432 Bytes
(UTF-8-Frame-ACK während der USB-Übernahme). Das ist weiterhin nur ein
Stichprobenwert: minimaler interner Heap, größter freier Block und Worker-Stack
wurden nicht instrumentiert. Beim USB-Test wurden Zustandswechsel beobachtet,
kein genauer Zeitpunkt eines Socket-Abbruchs. Die HTTP-Antwortheader wurden
am Host geprüft, nicht aus dem verschlüsselten Geräteverkehr mitgeschnitten.

Die Negativtests ersetzen jeweils das Profil und löschen damit die vorherige
Szene. Sie belegen keine Erhaltung alter Daten bei einem Ausfall derselben
Quelle. Der anfängliche Zustand `waiting_time` wurde nicht beobachtet und die
NTP-Sperre ohne erreichbaren Zeitserver somit nicht physisch geprüft.

## Fortgesetzter Test und offene Abnahme

Die Entwicklungsfirmware und die neu eingerichtete WLAN-Verbindung bleiben
auf dem S3. Für die fortgesetzten Standalone-Tests ist die installierte
Companion-App vorübergehend geschlossen. Die vollständige Rücksicherung ist
verfügbar; sie stammt von vor der WLAN-Einrichtung.

Nach den Negativtests wurde das Wetterprofil wieder erfolgreich geladen. Die
ursprüngliche Fensterkonfiguration ist bereits wiederhergestellt; `standby`
überlässt dem Standalone-Profil die Anzeige. Ein separater 24-Stunden-Dauerlauf
startete nach erneut bestätigter WLAN-/NTP-/Profilbereitschaft am **14.11.2026
um 09:44:52 MEZ**, vorgesehenes Ende **15.11.2026 um 09:44:52 MEZ**. Er ist zum
Zeitpunkt dieses Berichts **gestartet, nicht bestanden**.

Ein separater Recorder fragt alle 30 Sekunden ausschließlich `get_info` und
`standalone_status` ab. Er zeichnet Zeitstempel, Laufzeit, freien Heap,
Bildfehlerzähler, Verbindungszustand und Erfolgsalter auf. Er verändert keine
Profile, setzt keine Host-Zeit, übernimmt USB nicht und öffnet bei einem
Verbindungsfehler den Port nicht erneut. Der Mac wird für die Messung wach
gehalten; die Stromversorgung erfolgt weiterhin über USB. Diese Messung ist
kein separater Netzteiltest und keine durchgehende Sicht- oder Touchprüfung.
Bereits die ersten vier Dauerlauf-Stichproben enthalten einen niedrigeren
freien Heap von 55.668 Bytes; der endgültige Messbereich und Verlauf werden
erst nach Ende der Beobachtung bewertet.

Weiterhin offen sind:

- Netzwerkunterbrechung und Wiederherstellung mit derselben Quelle sowie die
  sichtbare Erhaltung alter Daten; fehlendes NTP und eindeutiger
  Zertifikats-Hostnamenfehler.
- Interne Speicher- und Stackreserven unter gleichzeitiger HTTPS-,
  Dateisystem- und Display-Last.
- Stromunterbrechung während eines Speichervorgangs, Kaltstart am separaten
  Netzteil, Touch-Abnahme auf CYD sowie der 24-Stunden-Dauerlauf einschließlich
  wiederholter Touch-Bedienung. Die einzelne S3-Prüfung für Öffnen/Zurück ist
  bestätigt; sie ersetzt keine Touch-Dauerprüfung.
- Sichtbare Umlaute, Zeilenhöhen und Clipping auf den CYD-Panels.

Die drei CYD-/S3-Firmwarebuilds und nativen Regressionen ersetzen diese offenen
Geräteprüfungen nicht. Es wurde kein Release erstellt.
