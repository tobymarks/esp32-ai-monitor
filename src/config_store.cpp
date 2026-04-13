/**
 * Config Store - NVS-based configuration storage
 *
 * Stores orientation and poll_interval in ESP32 NVS (Preferences).
 * No WiFi, no tokens — USB-Serial only.
 */

#include "config_store.h"
#include "config.h"
#include <Preferences.h>

// ============================================================
// Global config instance
// ============================================================
AppConfig g_config;

static Preferences prefs;

// ============================================================
// Load config from NVS
// ============================================================
void config_load(AppConfig &cfg) {
    prefs.begin(NVS_NAMESPACE, true);  // read-only

    cfg.poll_interval_sec = prefs.getUInt("poll_sec", DEFAULT_POLL_INTERVAL_SEC);
    cfg.orientation       = prefs.getUChar("orient", ORIENTATION_PORTRAIT);
    cfg.theme             = prefs.getUChar("theme", THEME_DARK);

    prefs.end();

    Serial.println("[Config] Loaded from NVS");
    Serial.printf("[Config] Poll interval: %u sec\n", cfg.poll_interval_sec);
    Serial.printf("[Config] Orientation: %s\n",
                  cfg.orientation == ORIENTATION_LANDSCAPE ? "landscape" : "portrait");
    Serial.printf("[Config] Theme: %s\n",
                  cfg.theme == THEME_LIGHT ? "light" : "dark");
}

// ============================================================
// Save config to NVS
// ============================================================
void config_save(const AppConfig &cfg) {
    prefs.begin(NVS_NAMESPACE, false);  // read-write

    prefs.putUInt("poll_sec", cfg.poll_interval_sec);
    prefs.putUChar("orient",  cfg.orientation);
    prefs.putUChar("theme",   cfg.theme);

    prefs.end();
    Serial.println("[Config] Saved to NVS");
}
