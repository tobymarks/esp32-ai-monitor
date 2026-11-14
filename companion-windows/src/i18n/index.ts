// Kleine Lokalisierung ohne Bibliothek: Schlüssel aus de.json/en.json,
// Platzhalter in geschweiften Klammern.

import de from "./de.json";
import en from "./en.json";
import type { Language } from "../api";

type Dict = Record<string, string>;
const dicts: Record<"de" | "en", Dict> = { de, en };

export type Locale = "de" | "en";

export function resolveLocale(language: Language): Locale {
  if (language === "de" || language === "en") return language;
  const nav = (navigator.language || "en").toLowerCase();
  return nav.startsWith("de") ? "de" : "en";
}

export type Translate = (key: string, vars?: Record<string, string | number>) => string;

export function makeTranslate(locale: Locale): Translate {
  const dict = dicts[locale];
  return (key, vars) => {
    let text = dict[key] ?? en[key as keyof typeof en] ?? key;
    if (vars) {
      for (const [name, value] of Object.entries(vars)) {
        text = text.replace(`{${name}}`, String(value));
      }
    }
    return text;
  };
}

/** Preserve technical detail while translating plugin compatibility errors. */
export function pluginError(error: unknown, t: Translate): string {
  const message = String(error);
  const newer = message.match(/This plugin requires a newer version of AI Monitor \(formatVersion (\d+)\)/);
  if (newer) return t("plugins.requiresNewer", { version: newer[1] });
  if (message.includes("attentionRules require formatVersion 2")) return t("plugins.rulesRequireV2");
  if (message.includes("source URL must be printable ASCII without whitespace (max 2048 bytes)")) return t("plugins.sourceAscii");
  if (message.includes("source must be an HTTPS URL without credentials or fragment")) return t("plugins.sourceHttps");
  if (message.includes("invalid source URL")) return t("plugins.sourceUrl");
  if (message.includes("URL placeholders must be numeric")) return t("plugins.sourceNumeric");
  if (message.includes("unknown URL placeholder")) return t("plugins.sourcePlaceholder");
  if (message.includes("source origin changed")) return t("plugins.sourceOrigin");
  if (message.includes("setting must be a URL")) return t("plugins.settingUrl");
  return message;
}
