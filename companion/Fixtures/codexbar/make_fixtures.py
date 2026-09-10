#!/usr/bin/env python3
"""Erzeugt die CodexBar-Fixtures mit frischen Zeitstempeln.

Aufruf: python3 make_fixtures.py [zielverzeichnis]
Die Strukturen folgen dem CodexBar-Quellcode (Stand 0.57):
  Gemini  -> GeminiStatusProbe.toUsageSnapshot()
  Copilot -> CopilotUsageFetcher.fetch()
  Cursor  -> CursorStatusProbe.toUsageSnapshot()
Die App verwirft Daten, deren updatedAt aelter als 15 Minuten ist — deshalb
vor jedem Testlauf neu erzeugen.
"""
import datetime as dt
import json
import os
import sys

out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
now = dt.datetime.now(dt.timezone.utc)
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
upd = iso(now)


def win(used, resets, minutes=None, desc=None):
    w = {"usedPercent": used, "resetsAt": iso(resets)}
    if minutes is not None:
        w["windowMinutes"] = minutes
    if desc:
        w["resetDescription"] = desc
    return w


day = now + dt.timedelta(hours=9, minutes=12)
month_end = now + dt.timedelta(days=17, hours=5)
cycle = 30 * 24 * 60

fixtures = {
    # Pro / Flash / Flash Lite, je 24-h-Fenster
    "gemini": [{"provider": "gemini", "source": "auto", "usage": {
        "primary": win(62.0, day, 1440, "Resets in 9h 12m"),
        "secondary": win(18.5, day, 1440, "Resets in 9h 12m"),
        "tertiary": win(3.0, day, 1440, "Resets in 9h 12m"),
        "updatedAt": upd}}],
    # Copilot Pro: Premium Requests monatlich, Chat unbegrenzt (nil), keine windowMinutes
    "copilot": [{"provider": "copilot", "source": "auto", "usage": {
        "primary": win(71.0, month_end),
        "updatedAt": upd}}],
    # Copilot mit reinem Chat-Kontingent: primary fehlt
    "copilot-chat-only": [{"provider": "copilot", "source": "auto", "usage": {
        "secondary": win(40.0, month_end),
        "updatedAt": upd}}],
    # Cursor, nutzungsbasierter Plan: Plan / Auto / API plus Grok-Bot-Wochenfenster
    "cursor": [{"provider": "cursor", "source": "web", "usage": {
        "primary": win(54.0, month_end, cycle, "Resets Sep 27 at 9:00AM"),
        "secondary": win(61.0, month_end, cycle, "Resets Sep 27 at 9:00AM"),
        "tertiary": win(12.0, month_end, cycle, "Resets Sep 27 at 9:00AM"),
        "extraRateWindows": [{"id": "grok-bot", "title": "Grok Bot",
                              "window": win(20.0, now + dt.timedelta(days=4), 10080)}],
        "updatedAt": upd}}],
    # Cursor, alter Request-Plan: nur primary
    "cursor-legacy": [{"provider": "cursor", "source": "web", "usage": {
        "primary": win(46.0, month_end, cycle, "230 / 500 requests"),
        "updatedAt": upd}}],
}
for name, data in fixtures.items():
    path = os.path.join(out, f"{name}.json")
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print(path)
