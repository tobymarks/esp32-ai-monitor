/**
 * WiFi Setup - WiFiManager + NVS Config Storage + mDNS
 *
 * Handles first-boot AP config portal (WLAN-only),
 * stores API key and settings in NVS (Preferences),
 * and sets up mDNS for easy access.
 * API key setup runs via web config portal at /api/key.
 */

#include "wifi_setup.h"
#include "config.h"
#include <WiFi.h>
#include <WiFiManager.h>
#include <Preferences.h>
#include <ESPmDNS.h>

// ============================================================
// NVS Storage
// ============================================================
static Preferences prefs;

// Buffer for poll interval (WiFiManager needs char array)
static char buf_poll_interval[8] = "120";

// ============================================================
// Load config from NVS
// ============================================================
void config_load(AppConfig &cfg) {
    prefs.begin(NVS_NAMESPACE, true);  // read-only

    strlcpy(cfg.access_token, prefs.getString("access_tkn", "").c_str(), sizeof(cfg.access_token));
    cfg.provider          = prefs.getUChar("provider", PROVIDER_CLAUDE);
    cfg.poll_interval_sec = prefs.getUInt("poll_sec", DEFAULT_POLL_INTERVAL_SEC);
    cfg.orientation       = prefs.getUChar("orient", ORIENTATION_PORTRAIT);

    prefs.end();

    Serial.println("[Config] Loaded from NVS");
    Serial.printf("[Config] Access token: %s\n", strlen(cfg.access_token) > 0 ? "(set)" : "(empty)");
    Serial.printf("[Config] Provider: %s\n", cfg.provider == PROVIDER_OPENAI ? "OpenAI" : "Claude");
    Serial.printf("[Config] Poll interval: %u sec\n", cfg.poll_interval_sec);
    Serial.printf("[Config] Orientation: %s\n", cfg.orientation == ORIENTATION_LANDSCAPE ? "landscape" : "portrait");
}

// ============================================================
// Save config to NVS
// ============================================================
void config_save(const AppConfig &cfg) {
    prefs.begin(NVS_NAMESPACE, false);  // read-write

    prefs.putString("access_tkn",  cfg.access_token);
    prefs.putUChar("provider",     cfg.provider);
    prefs.putUInt("poll_sec",      cfg.poll_interval_sec);
    prefs.putUChar("orient",       cfg.orientation);

    prefs.end();
    Serial.println("[Config] Saved to NVS");
}

// ============================================================
// Global config instance
// ============================================================
AppConfig g_config;

// ============================================================
// WiFiManager save callback
// ============================================================
static bool shouldSaveConfig = false;

static void saveConfigCallback() {
    shouldSaveConfig = true;
}

// ============================================================
// WiFi Setup Init
// ============================================================
bool wifi_setup_init() {
    // Load existing config from NVS
    config_load(g_config);

    // Copy poll interval to buffer for WiFiManager
    snprintf(buf_poll_interval, sizeof(buf_poll_interval), "%u", g_config.poll_interval_sec);

    // WiFiManager in its own scope so destructor runs and releases port 80
    {
        WiFiManager wm;
        wm.setConfigPortalTimeout(WIFIMANAGER_TIMEOUT_SEC);
        wm.setSaveConfigCallback(saveConfigCallback);
        wm.setAPStaticIPConfig(IPAddress(192, 168, 4, 1),
                               IPAddress(192, 168, 4, 1),
                               IPAddress(255, 255, 255, 0));

        // WiFiManager fragt nur WLAN-Credentials ab.
        // Token-Push läuft über das Web-Config-Portal (/api/token).
        WiFiManagerParameter param_header("<h2>AI Monitor – WLAN Setup</h2><p style='color:#aaa;font-size:.85em'>Token-Konfiguration nach der Verbindung unter http://ai-monitor.local/</p>");
        WiFiManagerParameter param_settings_header("<h3>Settings</h3>");
        WiFiManagerParameter p_poll("poll_sec", "Poll Interval (Sekunden)", buf_poll_interval, 7);

        wm.addParameter(&param_header);
        wm.addParameter(&param_settings_header);
        wm.addParameter(&p_poll);

        Serial.println("[WiFi] Starting WiFiManager autoConnect...");

        // Try to connect with stored credentials, or open AP portal
        bool connected = wm.autoConnect(WIFI_AP_NAME);

        if (!connected) {
            Serial.println("[WiFi] Failed to connect. Rebooting in 3 seconds...");
            delay(3000);
            ESP.restart();
            return false;
        }

        Serial.printf("[WiFi] Connected! IP: %s\n", WiFi.localIP().toString().c_str());

        // Save settings if config portal was used
        if (shouldSaveConfig) {
            uint32_t poll = atoi(p_poll.getValue());
            if (poll >= 10 && poll <= 86400) {
                g_config.poll_interval_sec = poll;
            }

            config_save(g_config);
            Serial.println("[WiFi] Config saved from portal");
        }
    } // WiFiManager destructor runs here — releases port 80

    // Give TCP stack time to release the socket
    delay(200);
    Serial.println("[WiFi] WiFiManager cleaned up, port 80 released");

    // Setup mDNS
    if (MDNS.begin(MDNS_HOSTNAME)) {
        MDNS.addService("http", "tcp", 80);
        Serial.printf("[mDNS] Responder started: http://%s.local/\n", MDNS_HOSTNAME);
    } else {
        Serial.println("[mDNS] Failed to start responder");
    }

    return true;
}

// ============================================================
// Start config portal manually (e.g. double-reset)
// ============================================================
void wifi_start_config_portal() {
    WiFiManager wm;
    wm.setConfigPortalTimeout(WIFIMANAGER_TIMEOUT_SEC);
    wm.startConfigPortal(WIFI_AP_NAME);
}

// ============================================================
// Check WiFi and reconnect
// ============================================================
static unsigned long lastReconnectAttempt = 0;

void wifi_check_connection() {
    if (WiFi.status() == WL_CONNECTED) return;

    unsigned long now = millis();
    if (now - lastReconnectAttempt < 10000) return;  // Try every 10s
    lastReconnectAttempt = now;

    Serial.println("[WiFi] Connection lost. Reconnecting...");
    WiFi.reconnect();
}

// ============================================================
// Getters
// ============================================================
String wifi_get_ip() {
    return WiFi.localIP().toString();
}

int wifi_get_rssi() {
    return WiFi.RSSI();
}

String wifi_get_ssid() {
    return WiFi.SSID();
}

bool wifi_is_connected() {
    return WiFi.status() == WL_CONNECTED;
}
