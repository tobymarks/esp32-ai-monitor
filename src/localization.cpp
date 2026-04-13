#include "localization.h"

uint8_t g_language = LANG_DE;  // Default: German

static const char* strings_de[] = {
    "Sitzung",              // STR_SESSION
    "Woche",                // STR_WEEKLY
    "Reset in %s",          // STR_RESETS_IN
    "Aktualisiert %s",      // STR_UPDATED
    "Verbinde...",           // STR_CONNECTING
    "AI Monitor",            // STR_AI_MONITOR
    "EINSTELLUNGEN",         // STR_SETTINGS
    "Sitzung (5h)",          // STR_SESSION_5H
    "Woche (7d)",            // STR_WEEKLY_7D
    "Extra (monatl.)",       // STR_EXTRA_MONTHLY
    "USB Seriell",           // STR_SOURCE_USB
    "Quelle:",               // STR_SOURCE
    "Letzte Daten:",         // STR_LAST_DATA
    "Status:",               // STR_STATUS
    "Ausricht.:",            // STR_ORIENTATION
    "Querformat",            // STR_LANDSCAPE
    "Hochformat",            // STR_PORTRAIT
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
};

static const char* strings_en[] = {
    "Session",               // STR_SESSION
    "Weekly",                // STR_WEEKLY
    "Resets in %s",          // STR_RESETS_IN
    "Updated %s",            // STR_UPDATED
    "Connecting...",         // STR_CONNECTING
    "AI Monitor",            // STR_AI_MONITOR
    "SETTINGS",              // STR_SETTINGS
    "Session (5h)",          // STR_SESSION_5H
    "Weekly (7d)",           // STR_WEEKLY_7D
    "Extra (monthly)",       // STR_EXTRA_MONTHLY
    "USB Serial",            // STR_SOURCE_USB
    "Source:",               // STR_SOURCE
    "Last data:",            // STR_LAST_DATA
    "Status:",               // STR_STATUS
    "Orient.:",              // STR_ORIENTATION
    "Landscape",             // STR_LANDSCAPE
    "Portrait",              // STR_PORTRAIT
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
};

const char* L(StrId id) {
    if (id < 0 || id >= _STR_COUNT) return "???";
    if (g_language == LANG_EN) return strings_en[id];
    return strings_de[id];
}
