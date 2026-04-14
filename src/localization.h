#ifndef LOCALIZATION_H
#define LOCALIZATION_H

#include <stdint.h>

// Language options
#define LANG_DE 0
#define LANG_EN 1

// Current language (stored in NVS, default: DE)
extern uint8_t g_language;

// String IDs
enum StrId {
    STR_SESSION,
    STR_WEEKLY,
    STR_RESETS_IN,        // "Reset in %s" / "Resets in %s"
    STR_UPDATED,          // "Aktualisiert %s" / "Updated %s"
    STR_CONNECTING,       // "Verbinde..." / "Connecting..."
    STR_AI_MONITOR,       // "AI Monitor"
    STR_SETTINGS,         // "EINSTELLUNGEN" / "SETTINGS"
    STR_SESSION_5H,       // "Sitzung (5h)" / "Session (5h)"
    STR_WEEKLY_7D,        // "Woche (7d)" / "Weekly (7d)"
    STR_EXTRA_MONTHLY,    // "Extra (monatl.)" / "Extra (monthly)"
    STR_SOURCE_USB,       // "USB Seriell" / "USB Serial"
    STR_SOURCE,           // "Quelle:" / "Source:"
    STR_LAST_DATA,        // "Letzte Daten:" / "Last data:"
    STR_STATUS,           // "Status:" / "Status:"
    STR_ORIENTATION,      // "Ausricht.:" / "Orient.:"
    STR_LANDSCAPE,        // "Querformat" / "Landscape"
    STR_PORTRAIT,         // "Hochformat" / "Portrait"
    STR_LANDSCAPE_LEFT,   // "Querformat <-" / "Landscape <-"
    STR_LANDSCAPE_RIGHT,  // "Querformat ->" / "Landscape ->"
    STR_HEAP,             // "Heap:" (stays same)
    STR_UPTIME,           // "Laufzeit:" / "Uptime:"
    STR_POLL,             // "Abfrage:" / "Poll:"
    STR_JUST_NOW,         // "gerade eben" / "just now"
    STR_NO_DATA,          // "keine Daten" / "no data"
    STR_NEVER,            // "nie" / "never"
    STR_WAITING,          // "Warte auf Daten..." / "Waiting for data..."
    STR_USB_CONNECTED,    // "USB verbunden..." / "USB connected..."
    STR_INITIALIZING,     // "Initialisiere..." / "Initializing..."
    STR_AGO,              // "vor" / "ago" (for time formatting)
    _STR_COUNT
};

// Get localized string
const char* L(StrId id);

#endif
