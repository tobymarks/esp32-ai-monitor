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

## Ergebnisse am laufenden Gerät

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

## Zustand nach dem Test und offene Abnahme

Das Testprofil wurde entfernt, die ursprüngliche Fensterkonfiguration
wiederhergestellt und die installierte Companion-App wieder gestartet.
Die geprüfte Entwicklungsfirmware bleibt auf dem S3. Der Plugin-Speicher ist
initialisiert; es sind keine Standalone-Profile aktiv und keine WLAN-Zugangsdaten
hinzugefügt worden. Die vollständige Rücksicherung ist verfügbar.

Die Sichtprüfung der tatsächlichen Zeichen und des Bildes wurde angefragt,
aber noch nicht bestätigt. Ein ACK ist kein Nachweis lesbarer Panel-Ausgabe.
WLAN-Zugangsdaten wurden noch nicht bereitgestellt. Somit bleiben offen:

- Tatsächlicher WLAN-/NTP-/TLS-Betrieb, Zertifikatsfehler, Netzwerkunterbrechung
  und Wiederherstellung, Live-Daten und Aktualisierungsintervalle.
- USB-Übernahme während eines laufenden Netzwerkabrufs und Laufzeit-Heap
  unter gleichzeitiger HTTPS-, Dateisystem- und Display-Last.
- Stromunterbrechung während eines Speichervorgangs, Betrieb am Netzteil,
  Touch-Abnahme auf S3 und CYD sowie der 24-Stunden-Dauerlauf.
- Sichtbare Umlaute, Zeilenhöhen und Clipping auf den physischen Panels.

Die drei CYD-/S3-Firmwarebuilds und nativen Regressionen ersetzen diese offenen
Geräteprüfungen nicht. Es wurde kein Release erstellt.
