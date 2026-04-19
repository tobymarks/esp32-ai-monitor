/**
 * Serial Receiver - USB-Serial JSON data receiver
 *
 * Reads single-line JSON from Serial (Mac sends via USB).
 * Parses usage data and updates MonitorState.
 * Sets ESP32 system clock from the "time" field.
 *
 * Expected JSON format (one line, terminated with \n):
 * {"time":"2026-04-12T15:30:00Z","data":[{"source":"oauth","usage":{...},"provider":"claude"}]}
 */

#include "serial_receiver.h"
#include "api_common.h"
#include "config.h"
#include "config_store.h"
#include "localization.h"
#include "ui_common.h"
#include "ui_dashboard.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <esp_mac.h>
#include <sys/time.h>

// ============================================================
// Constants
// ============================================================
static const size_t SERIAL_BUF_SIZE = 2048;
static const unsigned long DATA_TIMEOUT_MS = 300000;  // 5 minutes

// ============================================================
// State
// ============================================================
static char serial_buf[SERIAL_BUF_SIZE];
static size_t serial_buf_pos = 0;

static MonitorState state;
static bool new_data_flag = false;
static char display_time[6] = "--:--";

// ============================================================
// Getter: display time string sent by Mac companion app
// ============================================================
const char* serial_get_display_time() {
    return display_time;
}

// ============================================================
// Helper: parse and execute serial commands
// Returns true if a command was handled (caller should skip
// usage-data parsing).
// ============================================================
static bool parse_command(JsonDocument &doc) {
    if (!doc["cmd"].is<const char*>()) return false;

    const char *cmd = doc["cmd"];
    Serial.printf("[Serial] Command received: %s\n", cmd);

    // --- set_orientation (dynamic — no reboot) ---
    if (strcmp(cmd, "set_orientation") == 0) {
        const char *val = doc["value"];
        if (!val) {
            Serial.println("{\"type\":\"error\",\"message\":\"set_orientation: missing value\"}");
            return true;
        }
        uint8_t new_orient;
        if (strcmp(val, "portrait") == 0) {
            new_orient = ORIENTATION_PORTRAIT;
        } else if (strcmp(val, "landscape_left") == 0 || strcmp(val, "landscape") == 0) {
            new_orient = ORIENTATION_LANDSCAPE_LEFT;
        } else if (strcmp(val, "landscape_right") == 0) {
            new_orient = ORIENTATION_LANDSCAPE_RIGHT;
        } else {
            Serial.printf("{\"type\":\"error\",\"message\":\"set_orientation: invalid value '%s'\"}\n", val);
            return true;
        }
        if (new_orient != g_config.orientation) {
            g_config.orientation = new_orient;
            config_save(g_config);
            apply_orientation(new_orient);  // live rotation — no ESP.restart()
        }
        Serial.printf("{\"type\":\"ok\",\"cmd\":\"set_orientation\",\"value\":\"%s\"}\n", val);
        return true;
    }

    // --- set_brightness (0..100 percent, persisted in NVS) ---
    if (strcmp(cmd, "set_brightness") == 0) {
        if (!doc["value"].is<int>()) {
            Serial.println("{\"type\":\"error\",\"message\":\"set_brightness: missing or invalid value\"}");
            return true;
        }
        int val = doc["value"];
        if (val < BRIGHTNESS_MIN_PERCENT) val = BRIGHTNESS_MIN_PERCENT;
        if (val > BRIGHTNESS_MAX_PERCENT) val = BRIGHTNESS_MAX_PERCENT;
        g_config.brightness_pct = (uint8_t)val;
        config_save(g_config);
        backlight_apply_percent(g_config.brightness_pct);
        Serial.printf("{\"type\":\"ok\",\"cmd\":\"set_brightness\",\"value\":%d}\n", val);
        return true;
    }

    // --- set_theme ---
    if (strcmp(cmd, "set_theme") == 0) {
        const char *val = doc["value"];
        if (!val) {
            Serial.println("{\"type\":\"error\",\"message\":\"set_theme: missing value\"}");
            return true;
        }
        uint8_t new_theme;
        if (strcmp(val, "light") == 0) {
            new_theme = THEME_LIGHT;
        } else if (strcmp(val, "dark") == 0) {
            new_theme = THEME_DARK;
        } else {
            Serial.printf("{\"type\":\"error\",\"message\":\"set_theme: invalid value '%s'\"}\n", val);
            return true;
        }
        g_config.theme = new_theme;
        config_save(g_config);
        ui_apply_theme(new_theme);
        // Recreate dashboard with new colors
        ui_dashboard_recreate();
        Serial.printf("{\"type\":\"ok\",\"cmd\":\"set_theme\",\"value\":\"%s\"}\n", val);
        return true;
    }

    // --- set_language ---
    if (strcmp(cmd, "set_language") == 0) {
        const char *val = doc["value"];
        if (!val) {
            Serial.println("{\"type\":\"error\",\"message\":\"set_language: missing value\"}");
            return true;
        }
        uint8_t new_lang;
        if (strcmp(val, "de") == 0) {
            new_lang = LANG_DE;
        } else if (strcmp(val, "en") == 0) {
            new_lang = LANG_EN;
        } else {
            Serial.printf("{\"type\":\"error\",\"message\":\"set_language: invalid value '%s'\"}\n", val);
            return true;
        }
        g_language = new_lang;
        g_config.language = new_lang;
        config_save(g_config);
        ui_dashboard_recreate();
        Serial.printf("{\"type\":\"ok\",\"cmd\":\"set_language\",\"value\":\"%s\"}\n", val);
        return true;
    }

    // --- get_info ---
    if (strcmp(cmd, "get_info") == 0) {
        const char *orient;
        switch (g_config.orientation) {
            case ORIENTATION_LANDSCAPE_LEFT:  orient = "landscape_left";  break;
            case ORIENTATION_LANDSCAPE_RIGHT: orient = "landscape_right"; break;
            case ORIENTATION_PORTRAIT:
            default:                          orient = "portrait";        break;
        }
        const char *theme = (g_config.theme == THEME_LIGHT) ? "light" : "dark";
        const char *lang = (g_config.language == LANG_EN) ? "en" : "de";
        // MAC (Wi-Fi STA, lowercase-Hex mit Doppelpunkten) als Device-ID fuer
        // Per-Device-Profile in der Mac-App (ab App v1.14.0 / FW v2.10.0).
        uint8_t mac[6] = {0};
        esp_read_mac(mac, ESP_MAC_WIFI_STA);
        char mac_str[18];
        snprintf(mac_str, sizeof(mac_str), "%02x:%02x:%02x:%02x:%02x:%02x",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        Serial.printf("{\"type\":\"info\",\"version\":\"%s\",\"mac\":\"%s\","
                      "\"orientation\":\"%s\","
                      "\"theme\":\"%s\",\"language\":\"%s\",\"brightness\":%u,"
                      "\"uptime\":%lu,\"heap\":%u}\n",
                      APP_VERSION, mac_str, orient, theme, lang,
                      (unsigned)g_config.brightness_pct,
                      (unsigned long)(millis() / 1000),
                      (unsigned)ESP.getFreeHeap());
        return true;
    }

    // --- reboot ---
    if (strcmp(cmd, "reboot") == 0) {
        Serial.println("{\"type\":\"ok\",\"cmd\":\"reboot\"}");
        delay(200);
        ESP.restart();
        return true;
    }

    // --- unknown command ---
    Serial.printf("{\"type\":\"error\",\"message\":\"Unknown command: %s\"}\n", cmd);
    return true;
}

// ============================================================
// Helper: parse JSON and update state
// ============================================================
static void parse_json(const char *json_str) {
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, json_str);

    if (err) {
        Serial.printf("[Serial] JSON parse error: %s\n", err.c_str());
        strlcpy(state.status, "JSON Error", sizeof(state.status));
        strlcpy(state.usage.error, err.c_str(), sizeof(state.usage.error));
        state.usage.valid = false;
        return;
    }

    // Check for command — if handled, skip usage-data parsing
    if (parse_command(doc)) return;

    // Read display time from Mac companion app
    const char *dtime = doc["displayTime"];
    if (dtime) {
        strlcpy(display_time, dtime, sizeof(display_time));
    }

    // Set system clock from ISO "time" field (needed for countdown calculations)
    const char *time_str = doc["time"];
    if (time_str) {
        time_t epoch = iso8601_to_epoch(time_str);
        if (epoch > 0) {
            struct timeval tv = { .tv_sec = epoch, .tv_usec = 0 };
            settimeofday(&tv, nullptr);
        }
    }

    // Navigate to data[0].usage
    JsonObject data0 = doc["data"][0];
    if (data0.isNull()) {
        Serial.println("[Serial] No data[0] in JSON");
        strlcpy(state.status, "JSON Error", sizeof(state.status));
        strlcpy(state.usage.error, "Missing data[0]", sizeof(state.usage.error));
        state.usage.valid = false;
        return;
    }

    JsonObject usage = data0["usage"];
    if (usage.isNull()) {
        Serial.println("[Serial] No usage object in data[0]");
        strlcpy(state.status, "JSON Error", sizeof(state.status));
        strlcpy(state.usage.error, "Missing usage", sizeof(state.usage.error));
        state.usage.valid = false;
        return;
    }

    // --- Primary (Session / 5h) ---
    JsonObject primary = usage["primary"];
    if (!primary.isNull()) {
        float usedPct = primary["usedPercent"] | 0.0f;
        state.usage.five_hour_utilization = usedPct / 100.0f;

        const char *resetsAt = primary["resetsAt"];
        if (resetsAt) {
            strlcpy(state.usage.five_hour_resets_at, resetsAt, sizeof(state.usage.five_hour_resets_at));
            state.usage.five_hour_reset_epoch = iso8601_to_epoch(resetsAt);
        }
    }

    // --- Weekly: find field with windowMinutes >= 10080 ---
    // Check secondary first, then tertiary
    JsonObject weekly_source;
    int sec_window = usage["secondary"]["windowMinutes"] | 0;
    int ter_window = usage["tertiary"]["windowMinutes"] | 0;

    if (sec_window >= 10080) {
        weekly_source = usage["secondary"];
    } else if (ter_window >= 10080) {
        weekly_source = usage["tertiary"];
    } else {
        // Fallback: use secondary
        weekly_source = usage["secondary"];
    }

    if (!weekly_source.isNull()) {
        float usedPct = weekly_source["usedPercent"] | 0.0f;
        state.usage.seven_day_utilization = usedPct / 100.0f;

        const char *resetsAt = weekly_source["resetsAt"];
        if (resetsAt) {
            strlcpy(state.usage.seven_day_resets_at, resetsAt, sizeof(state.usage.seven_day_resets_at));
            state.usage.seven_day_reset_epoch = iso8601_to_epoch(resetsAt);
        }
    }

    // --- Extra usage (providerCost) ---
    JsonObject cost = usage["providerCost"];
    if (!cost.isNull()) {
        float used  = cost["used"] | 0.0f;
        float limit = cost["limit"] | 0.0f;

        if (limit > 0) {
            state.usage.has_extra_usage    = true;
            state.usage.extra_used_credits = used;
            state.usage.extra_monthly_limit = limit;
            state.usage.extra_utilization  = used / limit;
        } else {
            state.usage.has_extra_usage = false;
        }
    }

    // --- Login method as provider info ---
    const char *loginMethod = usage["loginMethod"];
    if (loginMethod) {
        Serial.printf("[Serial] Login: %s\n", loginMethod);
    }

    // --- Provider label (v2.9.0+ envelope field) ---
    // Companion-App sendet "claude" oder "codex" pro Frame. Fallback "claude"
    // für alte App-Versionen ohne das Feld. Label wird für das Display-Header-
    // Rendering uppercase gespeichert.
    const char *prov = data0["provider"];
    if (!prov) prov = "claude";
    // Uppercase-Copy in state.provider_label (max 15 Zeichen + NUL)
    size_t n = 0;
    while (prov[n] != '\0' && n < sizeof(state.provider_label) - 1) {
        char c = prov[n];
        if (c >= 'a' && c <= 'z') c = c - 'a' + 'A';
        state.provider_label[n] = c;
        n++;
    }
    state.provider_label[n] = '\0';
    // Legacy-enum für bestehende Checks im Dashboard weiter pflegen
    state.provider = (strcmp(prov, "codex") == 0) ? PROVIDER_OPENAI : PROVIDER_CLAUDE;

    // Mark data as valid
    state.usage.valid = true;
    state.usage.last_fetch = millis();
    state.usage.error[0] = '\0';
    state.token_valid = true;
    state.is_fetching = false;
    strlcpy(state.status, "OK (USB)", sizeof(state.status));
    new_data_flag = true;

    Serial.printf("[Serial] Parsed: Session=%.0f%% Weekly=%.0f%%\n",
                  state.usage.five_hour_utilization * 100.0f,
                  state.usage.seven_day_utilization * 100.0f);
}

// ============================================================
// Init
// ============================================================
void serial_receiver_init() {
    serial_buf_pos = 0;
    memset(&state, 0, sizeof(state));
    usage_data_clear(state.usage);
    state.is_fetching = false;
    state.token_valid = false;

    // Set timezone for localtime_r() — CET/CEST (Germany)
    setenv("TZ", "CET-1CEST,M3.5.0,M10.5.0/3", 1);
    tzset();
    g_language = g_config.language;  // Apply saved language
    state.provider = PROVIDER_CLAUDE;
    strlcpy(state.provider_label, "CLAUDE", sizeof(state.provider_label));
    strlcpy(state.status, L(STR_WAITING), sizeof(state.status));
    new_data_flag = false;
    strlcpy(display_time, "--:--", sizeof(display_time));

    Serial.println("[Serial] Receiver initialized — waiting for USB data");
}

// ============================================================
// Tick — call from loop()
// ============================================================
void serial_receiver_tick() {
    while (Serial.available()) {
        char c = Serial.read();

        if (c == '\n') {
            // Terminate and parse
            if (serial_buf_pos > 0) {
                serial_buf[serial_buf_pos] = '\0';
                parse_json(serial_buf);
            }
            serial_buf_pos = 0;
        } else if (c != '\r') {
            // Accumulate (guard overflow)
            if (serial_buf_pos < SERIAL_BUF_SIZE - 1) {
                serial_buf[serial_buf_pos++] = c;
            } else {
                // Buffer overflow — discard and reset
                Serial.println("[Serial] Buffer overflow — discarding");
                serial_buf_pos = 0;
            }
        }
    }

    // Check for data timeout
    if (state.usage.valid && state.usage.last_fetch > 0) {
        unsigned long elapsed = millis() - state.usage.last_fetch;
        if (elapsed > DATA_TIMEOUT_MS) {
            strlcpy(state.status, "No data (timeout)", sizeof(state.status));
        }
    }
}

// ============================================================
// Get state copy
// ============================================================
MonitorState serial_get_state() {
    MonitorState copy;
    memcpy(&copy, &state, sizeof(MonitorState));
    return copy;
}

// ============================================================
// Recent data check (< 5 minutes)
// ============================================================
bool serial_has_recent_data() {
    if (!state.usage.valid || state.usage.last_fetch == 0) return false;
    return (millis() - state.usage.last_fetch) < DATA_TIMEOUT_MS;
}

// ============================================================
// New data flag (auto-resets on read)
// ============================================================
bool serial_has_new_data() {
    if (new_data_flag) {
        new_data_flag = false;
        return true;
    }
    return false;
}
