# CodexBar-Fixtures

JSON-Antworten im Format von `codexbar usage --provider <p> --json`, abgeleitet
aus dem CodexBar-Quellcode (`*StatusProbe.toUsageSnapshot()` bzw.
`CopilotUsageFetcher.fetch()`). Sie dienen dazu, Provider ohne eigenes Konto
bis aufs Display durchzuspielen.

Nutzung: App mit gesetzter Umgebungsvariable starten, dann liest sie statt des
CLI die Datei `<dir>/<provider>.json`:

    AIMONITOR_CODEXBAR_FIXTURE_DIR="$PWD/companion/Fixtures/codexbar" \
      "/Applications/AI Monitor.app/Contents/MacOS/AIMonitor"

Varianten wie `copilot-chat-only.json` oder `cursor-legacy.json` vorher auf den
Provider-Namen kopieren. Die Zeitstempel sind relativ zum Erzeugungszeitpunkt
und werden mit `make_fixtures.py` frisch gesetzt — vor jedem Testlauf neu erzeugen,
sonst gelten die Daten nach 15 Minuten als veraltet.
