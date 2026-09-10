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
