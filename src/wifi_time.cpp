/**
 * WiFi Time - optional WiFi/NTP support for standalone clock mode.
 *
 * Usage data remains USB-only. WiFi is used only to keep the device clock
 * accurate when the display has power but the Mac app is not connected.
 */

#include "wifi_time.h"
#include "config.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <WiFi.h>
#include <time.h>

static const char *TZ_INFO = "CET-1CEST,M3.5.0,M10.5.0/3";
static const char *NTP_SERVER_1 = "pool.ntp.org";
static const char *NTP_SERVER_2 = "time.nist.gov";
static const unsigned long WIFI_RECONNECT_INTERVAL_MS = 30000;
static const uint8_t WIFI_SCAN_MAX_RESULTS = 16;

static Preferences prefs;
static char stored_ssid[33] = "";
static char stored_password[65] = "";
static bool has_credentials = false;
static bool ntp_configured = false;
static bool time_synced = false;
static unsigned long last_connect_attempt = 0;

static bool system_time_is_valid() {
    time_t now = time(nullptr);
    return now > CLOCK_VALID_EPOCH;  // post-2023
}

static void load_credentials() {
    prefs.begin(NVS_NAMESPACE, true);
    String ssid = prefs.getString("wifi_ssid", "");
    String pass = prefs.getString("wifi_pass", "");
    prefs.end();

    strlcpy(stored_ssid, ssid.c_str(), sizeof(stored_ssid));
    strlcpy(stored_password, pass.c_str(), sizeof(stored_password));
    has_credentials = stored_ssid[0] != '\0';
}

static void start_connect() {
    if (!has_credentials) return;

    WiFi.mode(WIFI_STA);
    WiFi.setSleep(false);
    WiFi.begin(stored_ssid, stored_password);
    last_connect_attempt = millis();
    ntp_configured = false;
    time_synced = false;
    Serial.printf("[WiFi] Connecting to SSID '%s'\n", stored_ssid);
}

static void ensure_ntp_started() {
    if (ntp_configured || WiFi.status() != WL_CONNECTED) return;

    setenv("TZ", TZ_INFO, 1);
    tzset();
    configTzTime(TZ_INFO, NTP_SERVER_1, NTP_SERVER_2);
    ntp_configured = true;
    Serial.println("[NTP] Sync configured");
}

void wifi_time_init() {
    load_credentials();
    WiFi.mode(WIFI_STA);
    WiFi.setSleep(false);

    if (has_credentials) {
        start_connect();
    } else {
        Serial.println("[WiFi] No stored credentials");
    }
}

void wifi_time_tick() {
    if (!has_credentials) return;

    if (WiFi.status() == WL_CONNECTED) {
        ensure_ntp_started();
        if (!time_synced && system_time_is_valid()) {
            time_synced = true;
            struct tm local;
            time_t now = time(nullptr);
            localtime_r(&now, &local);
            char buf[32];
            strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &local);
            Serial.printf("[NTP] Time synced: %s\n", buf);
        }
        return;
    }

    unsigned long now_ms = millis();
    if (now_ms - last_connect_attempt >= WIFI_RECONNECT_INTERVAL_MS) {
        start_connect();
    }
}

bool wifi_time_has_credentials() {
    return has_credentials;
}

bool wifi_time_is_connected() {
    return WiFi.status() == WL_CONNECTED;
}

bool wifi_time_is_synced() {
    if (time_synced) return true;
    time_synced = system_time_is_valid();
    return time_synced;
}

void wifi_time_save_credentials(const char *ssid, const char *password) {
    if (ssid == nullptr) ssid = "";
    if (password == nullptr) password = "";

    strlcpy(stored_ssid, ssid, sizeof(stored_ssid));
    strlcpy(stored_password, password, sizeof(stored_password));
    has_credentials = stored_ssid[0] != '\0';

    prefs.begin(NVS_NAMESPACE, false);
    prefs.putString("wifi_ssid", stored_ssid);
    prefs.putString("wifi_pass", stored_password);
    prefs.end();

    ntp_configured = false;
    time_synced = system_time_is_valid();
    if (has_credentials) {
        start_connect();
    }
}

void wifi_time_forget_credentials() {
    prefs.begin(NVS_NAMESPACE, false);
    prefs.remove("wifi_ssid");
    prefs.remove("wifi_pass");
    prefs.end();

    stored_ssid[0] = '\0';
    stored_password[0] = '\0';
    has_credentials = false;
    ntp_configured = false;
    WiFi.disconnect(true, true);
    WiFi.mode(WIFI_STA);
    Serial.println("[WiFi] Credentials forgotten");
}

bool wifi_time_connect_now(uint32_t timeout_ms) {
    if (!has_credentials) return false;

    start_connect();
    unsigned long start = millis();
    while (millis() - start < timeout_ms) {
        if (WiFi.status() == WL_CONNECTED) {
            ensure_ntp_started();
            return true;
        }
        delay(100);
    }
    return WiFi.status() == WL_CONNECTED;
}

void wifi_time_print_status(const char *type) {
    JsonDocument out;
    out["type"] = type ? type : "wifi_status";
    out["configured"] = has_credentials;
    out["connected"] = WiFi.status() == WL_CONNECTED;
    out["ssid"] = (WiFi.status() == WL_CONNECTED) ? WiFi.SSID() : stored_ssid;
    out["ip"] = (WiFi.status() == WL_CONNECTED) ? WiFi.localIP().toString() : "";
    out["rssi"] = (WiFi.status() == WL_CONNECTED) ? WiFi.RSSI() : 0;
    out["timeSynced"] = wifi_time_is_synced();

    serializeJson(out, Serial);
    Serial.println();
}

void wifi_time_print_scan() {
    WiFi.mode(WIFI_STA);
    int found = WiFi.scanNetworks(false, true);

    JsonDocument out;
    out["type"] = "wifi_scan";
    JsonArray networks = out["networks"].to<JsonArray>();

    if (found > 0) {
        uint8_t limit = (found < WIFI_SCAN_MAX_RESULTS) ? found : WIFI_SCAN_MAX_RESULTS;
        for (uint8_t i = 0; i < limit; i++) {
            JsonObject item = networks.add<JsonObject>();
            item["ssid"] = WiFi.SSID(i);
            item["rssi"] = WiFi.RSSI(i);
            item["secure"] = WiFi.encryptionType(i) != WIFI_AUTH_OPEN;
        }
    }

    WiFi.scanDelete();
    serializeJson(out, Serial);
    Serial.println();
}
