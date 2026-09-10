#!/usr/bin/env python3
"""Synthetische Win-CodexBar-Fixtures (snake_case), solange keine echten
Aufnahmen von einem Windows-Rechner vorliegen.

Die Struktur folgt rust/src/core/usage_snapshot.rs und rate_window.rs aus
Win-CodexBar (Stand 0.56.8): `usage` mit primary/secondary/tertiary,
extra_rate_windows [{id, title, window}], updated_at; Fehler als String.
Zeitstempel sind fest, die Tests übergeben ihr eigenes "jetzt". Für einen
Lauf der App im Fixture-Modus die Stempel mit --fresh auf die aktuelle Zeit
setzen, sonst gelten die Daten als veraltet.

Aufruf: python3 make_synthetic.py [--fresh] [zielverzeichnis]
"""
import datetime as dt
import json
import os
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
fresh = "--fresh" in sys.argv
out = args[0] if args else os.path.dirname(os.path.abspath(__file__))

now = dt.datetime.now(dt.timezone.utc) if fresh else dt.datetime(2026, 9, 11, 8, 0, 0, tzinfo=dt.timezone.utc)
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"  # chrono schreibt Bruchteile
upd = iso(now)


def win(used, resets, minutes=None, desc=None):
    w = {"used_percent": used}
    if minutes is not None:
        w["window_minutes"] = minutes
    if resets is not None:
        w["resets_at"] = iso(resets)
    if desc:
        w["reset_description"] = desc
    w["is_informational"] = False
    return w


def ok(provider, source, usage, **extra):
    u = dict(usage)
    u["updated_at"] = upd
    r = {"provider": provider, "version": "0.56.8", "source": source, "usage": u, "cost": None}
    r.update(extra)
    return [r]


h5 = now + dt.timedelta(hours=2, minutes=13)
week = now + dt.timedelta(days=3, hours=1)
day = now + dt.timedelta(hours=9, minutes=12)
month_end = now + dt.timedelta(days=17, hours=5)
cycle = 30 * 24 * 60

fixtures = {
    "claude": ok("claude", "oauth", {
        "primary": win(37.4, h5, 300, "Resets in 2h 13m"),
        "secondary": win(62.0, week, 10080, "Resets Sep 14 at 9:00 AM"),
        "extra_rate_windows": [
            {"id": "fable-weekly", "title": "Fable weekly", "window": win(12.0, week, 10080)}
        ],
        "login_method": "oauth",
        "account_email": "user@example.com",
    }),
    "codex": ok("codex", "oauth", {
        "primary": win(48.0, h5, 300),
        "secondary": win(21.0, week, 10080),
        "login_method": "chatgpt",
    }),
    "antigravity": ok("antigravity", "lsp", {
        "primary": win(5.0, h5, 300),
        "extra_rate_windows": [
            {"id": "claude", "title": "Claude/GPT weekly", "window": win(20.0, week, 10080)},
            {"id": "gemini-pro", "title": "Gemini 5-hour", "window": win(55.0, h5, 300)},
            {"id": "gemini-flash", "title": "Gemini Flash", "window": win(1.0, None)},
        ],
    }),
    "gemini": ok("gemini", "auto", {
        "primary": win(62.0, day, 1440, "Resets in 9h 12m"),
        "secondary": win(18.5, day, 1440, "Resets in 9h 12m"),
        "tertiary": win(3.0, day, 1440, "Resets in 9h 12m"),
    }),
    "copilot": ok("copilot", "auto", {"primary": win(71.0, month_end)}),
    "copilot-chat-only": ok("copilot", "auto", {"secondary": win(40.0, month_end)}),
    "cursor": ok("cursor", "web", {
        "primary": win(54.0, month_end, cycle, "Resets Sep 27 at 9:00AM"),
        "secondary": win(61.0, month_end, cycle, "Resets Sep 27 at 9:00AM"),
        "tertiary": win(12.0, month_end, cycle, "Resets Sep 27 at 9:00AM"),
        "extra_rate_windows": [
            {"id": "grok-bot", "title": "Grok Bot", "window": win(20.0, now + dt.timedelta(days=4), 10080)}
        ],
    }),
    "cursor-legacy": ok("cursor", "web", {"primary": win(46.0, month_end, cycle, "230 / 500 requests")}),
    "cursor-error": [{"provider": "cursor", "error": "No credentials found for cursor"}],
    "claude-stale": ok("claude", "oauth", {"primary": win(10.0, h5, 300)}),
}
fixtures["claude-stale"][0]["usage"]["updated_at"] = iso(now - dt.timedelta(hours=1))

for name, data in fixtures.items():
    path = os.path.join(out, f"{name}.json")
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(path)
