# Win-CodexBar-Fixtures

Echte JSON-Antworten von `codexbar-cli.exe usage -p <provider> -f json --pretty`
(Win-CodexBar, https://github.com/nesszer/Win-CodexBar), aufgenommen auf einem
Windows-Rechner. Sie sind die Referenz für die Mapping-Schicht der Windows-App
und für den Schema-Test in der CI.

Erwartete Dateien nach dem Aufnehmen mit `collect_fixtures.ps1`:

| Datei | Inhalt |
|---|---|
| `claude.json`, `codex.json`, `antigravity.json`, `gemini.json`, `copilot.json`, `cursor.json` | Erfolgsfall je Provider |
| `<provider>-error.json` | Fehlerfall, Provider in Win-CodexBar nicht eingerichtet |
| `cli-version.txt` | Ausgabe von `codexbar-cli --version` |

Unterschiede zu den Mac-Fixtures unter `companion/Fixtures/codexbar/`:

- Feldnamen in snake_case: `used_percent`, `resets_at`, `window_minutes`,
  `reset_description`, `updated_at`, `extra_rate_windows`, `login_method`
- Fehler als String im Feld `error`, nicht als Objekt mit `code`, `message`, `kind`
- Zusätzliche Felder wie `cost`, `pace`, `status`, `version` können vorkommen
  und werden von der App ignoriert

Die Dateien enthalten Kontostände und E-Mail-Adressen des aufnehmenden Kontos.
Vor dem Commit `account_email` und `account_organization` durch Platzhalter
ersetzen. `collect_fixtures.ps1` macht das automatisch.
