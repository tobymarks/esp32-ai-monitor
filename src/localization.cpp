#include "localization.h"

#include <stdio.h>
#include <string.h>

uint8_t g_language = LANG_DE;  // Default: German

static const char* strings_de[] = {
    "Sitzung",              // STR_SESSION
    "Woche",                // STR_WEEKLY
    "Erneuert in %s",       // STR_RESETS_IN
    "Aktualisiert %s",      // STR_UPDATED
    "Verbinde...",           // STR_CONNECTING
    "AI Monitor",            // STR_AI_MONITOR
    "EINSTELLUNGEN",         // STR_SETTINGS
    "USB Seriell",           // STR_SOURCE_USB
    "Quelle:",               // STR_SOURCE
    "Letzte Daten:",         // STR_LAST_DATA
    "Status:",               // STR_STATUS
    "Ausricht.:",            // STR_ORIENTATION
    "Querformat",            // STR_LANDSCAPE
    "Hochformat",            // STR_PORTRAIT
    "Querf. <-",             // STR_LANDSCAPE_LEFT
    "Querf. ->",             // STR_LANDSCAPE_RIGHT
    "Heap:",                 // STR_HEAP
    "Laufzeit:",             // STR_UPTIME
    "Abfrage:",              // STR_POLL
    "gerade eben",           // STR_JUST_NOW
    "keine Daten",           // STR_NO_DATA
    "nie",                   // STR_NEVER
    "Warte auf Daten...",    // STR_WAITING
    "USB verbunden...",      // STR_USB_CONNECTED
    "Initialisiere...",      // STR_INITIALIZING
    "vor",                   // STR_AGO
    "im Plan",               // STR_ON_PACE
    "zu schnell",            // STR_TOO_FAST
    "%d %% der Zeit vergangen", // STR_TIME_ELAPSED
    "Prognose",              // STR_FORECAST
    "Tagesbudget",           // STR_DAILY_BUDGET
    "Reicht",                // STR_LASTS
    "bis zum Reset",         // STR_UNTIL_RESET
    "Leer",                  // STR_EMPTY
    "leer ab %s",            // STR_EMPTY_AT
    "Limit erreicht",        // STR_LIMIT_REACHED
    "pro Tag bis Reset",     // STR_PER_DAY
    "Rest bis Reset",        // STR_LEFT_UNTIL_RESET
    "noch zu früh",          // STR_TOO_EARLY
};

static const char* strings_en[] = {
    "Session",               // STR_SESSION
    "Weekly",                // STR_WEEKLY
    "Resets in %s",          // STR_RESETS_IN
    "Updated %s",            // STR_UPDATED
    "Connecting...",         // STR_CONNECTING
    "AI Monitor",            // STR_AI_MONITOR
    "SETTINGS",              // STR_SETTINGS
    "USB Serial",            // STR_SOURCE_USB
    "Source:",               // STR_SOURCE
    "Last data:",            // STR_LAST_DATA
    "Status:",               // STR_STATUS
    "Orient.:",              // STR_ORIENTATION
    "Landscape",             // STR_LANDSCAPE
    "Portrait",              // STR_PORTRAIT
    "Lands. <-",             // STR_LANDSCAPE_LEFT
    "Lands. ->",             // STR_LANDSCAPE_RIGHT
    "Heap:",                 // STR_HEAP
    "Uptime:",               // STR_UPTIME
    "Poll:",                 // STR_POLL
    "just now",              // STR_JUST_NOW
    "no data",               // STR_NO_DATA
    "never",                 // STR_NEVER
    "Waiting for data...",   // STR_WAITING
    "USB connected...",      // STR_USB_CONNECTED
    "Initializing...",       // STR_INITIALIZING
    "ago",                   // STR_AGO
    "On pace",               // STR_ON_PACE
    "Too fast",              // STR_TOO_FAST
    "%d%% of time elapsed",  // STR_TIME_ELAPSED
    "Forecast",              // STR_FORECAST
    "Daily budget",          // STR_DAILY_BUDGET
    "Lasts",                 // STR_LASTS
    "until reset",           // STR_UNTIL_RESET
    "Empty",                 // STR_EMPTY
    "empty at %s",           // STR_EMPTY_AT
    "Limit reached",         // STR_LIMIT_REACHED
    "per day until reset",   // STR_PER_DAY
    "left until reset",      // STR_LEFT_UNTIL_RESET
    "too early",             // STR_TOO_EARLY
};

const char* L(StrId id) {
    if (id < 0 || id >= _STR_COUNT) return "???";
    if (g_language == LANG_EN) return strings_en[id];
    return strings_de[id];
}

// Feste Titel der Provider-Tabellen (providers.cpp, CodexBarSource.swift,
// provider.rs). Markennamen wie "Pro", "Flash" oder "Premium" bleiben stehen.
// Die Montserrat-Schriften der Firmware haben keine Umlaute.
static const struct { const char *en; const char *de; } ROW_TITLES_DE[] = {
    { "Session",   "Sitzung" },
    { "Weekly",    "Woche" },
    { "Tertiary",  "Weitere" },
    { "Window",    "Fenster" },
    { "Model",     "Modell" },
    { "Quota",     "Kontingent" },
    { "Daily",     "Tag" },
    { "Monthly",   "Monat" },
};

static bool ends_with(const char *s, size_t len, const char *suffix, size_t *stem_len) {
    const size_t n = strlen(suffix);
    if (len <= n || strcmp(s + len - n, suffix) != 0) return false;
    *stem_len = len - n;
    return true;
}

const char* L_row_title(const char *title) {
    static char buf[24];
    if (title == nullptr || g_language != LANG_DE) return title;

    for (const auto &t : ROW_TITLES_DE) {
        if (strcmp(title, t.en) == 0) return t.de;
    }

    // Zusatzfenster aus CodexBar: "Fable only" -> "nur Fable",
    // "Fable weekly" -> "Fable Woche".
    const size_t len = strlen(title);
    size_t stem = 0;
    if (ends_with(title, len, " only", &stem)) {
        snprintf(buf, sizeof(buf), "nur %.*s", (int)stem, title);
        return buf;
    }
    if (ends_with(title, len, " weekly", &stem)) {
        snprintf(buf, sizeof(buf), "%.*s Woche", (int)stem, title);
        return buf;
    }
    return title;
}
