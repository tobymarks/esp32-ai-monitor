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
    cfg.language          = prefs.getUChar("lang", LANG_DE);
    cfg.brightness_pct    = prefs.getUChar("bright", BRIGHTNESS_DEFAULT_PERCENT);
    if (cfg.brightness_pct < BRIGHTNESS_MIN_PERCENT) cfg.brightness_pct = BRIGHTNESS_MIN_PERCENT;
    if (cfg.brightness_pct > BRIGHTNESS_MAX_PERCENT) cfg.brightness_pct = BRIGHTNESS_MAX_PERCENT;

    prefs.end();

    Serial.println("[Config] Loaded from NVS");
    Serial.printf("[Config] Poll interval: %u sec\n", cfg.poll_interval_sec);
    const char *orient_str;
    switch (cfg.orientation) {
        case ORIENTATION_LANDSCAPE_LEFT:  orient_str = "landscape_left";  break;
        case ORIENTATION_LANDSCAPE_RIGHT: orient_str = "landscape_right"; break;
        case ORIENTATION_PORTRAIT:
        default:                          orient_str = "portrait";        break;
    }
    Serial.printf("[Config] Orientation: %s\n", orient_str);
    Serial.printf("[Config] Theme: %s\n",
                  cfg.theme == THEME_LIGHT ? "light" : "dark");
    Serial.printf("[Config] Language: %s\n",
                  cfg.language == LANG_EN ? "en" : "de");
    Serial.printf("[Config] Brightness: %u%%\n", cfg.brightness_pct);
}

// ============================================================
// Save config to NVS
// ============================================================
void config_save(const AppConfig &cfg) {
    prefs.begin(NVS_NAMESPACE, false);  // read-write

    prefs.putUInt("poll_sec", cfg.poll_interval_sec);
    prefs.putUChar("orient",  cfg.orientation);
    prefs.putUChar("theme",   cfg.theme);
    prefs.putUChar("lang",    cfg.language);
    prefs.putUChar("bright",  cfg.brightness_pct);

    prefs.end();
    Serial.println("[Config] Saved to NVS");
}
