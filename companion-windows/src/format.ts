// Zeitformatierung für Countdown und "aktualisiert vor".

import type { Translate } from "./i18n";

/// Dauer in Sekunden als kurze Angabe ("2 h 13 min", "45 min", "12 s").
export function formatDuration(t: Translate, seconds: number): string {
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return t("time.seconds", { s });
  const minutes = Math.floor(s / 60);
  if (minutes < 60) return t("time.minutes", { m: minutes });
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return t("time.hours", { h: hours, m: minutes % 60 });
  const days = Math.floor(hours / 24);
  return t("time.days", { d: days, h: hours % 24 });
}

/// Countdown bis zu einem ISO-Zeitpunkt, gemessen an `now`.
export function formatCountdown(t: Translate, iso: string | null, now: number): string {
  if (!iso) return t("ov.reset.unknown");
  const target = Date.parse(iso);
  if (Number.isNaN(target)) return t("ov.reset.unknown");
  const diff = (target - now) / 1000;
  if (diff <= 0) return t("ov.reset.due");
  return t("ov.reset.in", { time: formatDuration(t, diff) });
}

/// "aktualisiert vor x min" aus einem ISO-Zeitpunkt.
export function formatAgo(t: Translate, iso: string | null, now: number): string {
  if (!iso) return t("ov.updated.never");
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return t("ov.updated.never");
  const diff = (now - then) / 1000;
  if (diff < 30) return t("ov.updated.now");
  return t("ov.updated.ago", { time: formatDuration(t, diff) });
}

export function formatMs(ms: number): string {
  return ms >= 1000 ? `${(ms / 1000).toFixed(1)} s` : `${ms} ms`;
}
