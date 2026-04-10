/**
 * WiFi Setup - WiFiManager + NVS Config Storage + mDNS
 *
 * Handles first-boot AP config portal with custom parameters,
 * stores credentials and API keys in NVS (Preferences),
 * and sets up mDNS for easy access.
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

// Buffers for custom parameter values (WiFiManager needs char arrays)
static char buf_anthropic_key[NVS_VAL_MAX_LEN]  = "";
static char buf_anthropic_org[NVS_VAL_MAX_LEN]   = "";
static char buf_openai_key[NVS_VAL_MAX_LEN]      = "";
static char buf_openai_org[NVS_VAL_MAX_LEN]       = "";
static char buf_poll_interval[8]                   = "300";

// ============================================================
// Load config from NVS
// ============================================================
void config_load(AppConfig &cfg) {
    prefs.begin(NVS_NAMESPACE, true);  // read-only

    strlcpy(cfg.anthropic_key, prefs.getString("anth_key", "").c_str(), sizeof(cfg.anthropic_key));
    strlcpy(cfg.anthropic_org, prefs.getString("anth_org", "").c_str(), sizeof(cfg.anthropic_org));
    strlcpy(cfg.openai_key, prefs.getString("oai_key", "").c_str(), sizeof(cfg.openai_key));
    strlcpy(cfg.openai_org, prefs.getString("oai_org", "").c_str(), sizeof(cfg.openai_org));
    cfg.poll_interval_sec = prefs.getUInt("poll_sec", DEFAULT_POLL_INTERVAL_SEC);

    prefs.end();

    Serial.println("[Config] Loaded from NVS");
    Serial.printf("[Config] Anthropic key: %s\n", strlen(cfg.anthropic_key) > 0 ? "(set)" : "(empty)");
    Serial.printf("[Config] OpenAI key: %s\n", strlen(cfg.openai_key) > 0 ? "(set)" : "(empty)");
    Serial.printf("[Config] Poll interval: %u sec\n", cfg.poll_interval_sec);
}

// ============================================================
// Save config to NVS
// ============================================================
void config_save(const AppConfig &cfg) {
    prefs.begin(NVS_NAMESPACE, false);  // read-write

    prefs.putString("anth_key", cfg.anthropic_key);
    prefs.putString("anth_org", cfg.anthropic_org);
    prefs.putString("oai_key", cfg.openai_key);
    prefs.putString("oai_org", cfg.openai_org);
    prefs.putUInt("poll_sec", cfg.poll_interval_sec);

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

    // Copy loaded values to buffers for WiFiManager
    strlcpy(buf_anthropic_key, g_config.anthropic_key, sizeof(buf_anthropic_key));
    strlcpy(buf_anthropic_org, g_config.anthropic_org, sizeof(buf_anthropic_org));
    strlcpy(buf_openai_key, g_config.openai_key, sizeof(buf_openai_key));
    strlcpy(buf_openai_org, g_config.openai_org, sizeof(buf_openai_org));
    snprintf(buf_poll_interval, sizeof(buf_poll_interval), "%u", g_config.poll_interval_sec);

    // Create WiFiManager
    WiFiManager wm;
    wm.setConfigPortalTimeout(WIFIMANAGER_TIMEOUT_SEC);
    wm.setSaveConfigCallback(saveConfigCallback);
    wm.setAPStaticIPConfig(IPAddress(192, 168, 4, 1),
                           IPAddress(192, 168, 4, 1),
                           IPAddress(255, 255, 255, 0));

    // Custom parameters
    WiFiManagerParameter param_header("<h2>AI Monitor Config</h2>");
    WiFiManagerParameter param_anth_header("<h3>Anthropic</h3>");
    WiFiManagerParameter p_anthropic_key("anth_key", "Anthropic API Key", buf_anthropic_key, NVS_VAL_MAX_LEN - 1);
    WiFiManagerParameter p_anthropic_org("anth_org", "Anthropic Org ID", buf_anthropic_org, NVS_VAL_MAX_LEN - 1);
    WiFiManagerParameter param_oai_header("<h3>OpenAI</h3>");
    WiFiManagerParameter p_openai_key("oai_key", "OpenAI API Key", buf_openai_key, NVS_VAL_MAX_LEN - 1);
    WiFiManagerParameter p_openai_org("oai_org", "OpenAI Org ID", buf_openai_org, NVS_VAL_MAX_LEN - 1);
    WiFiManagerParameter param_settings_header("<h3>Settings</h3>");
    WiFiManagerParameter p_poll("poll_sec", "Poll Interval (seconds)", buf_poll_interval, 7);

    wm.addParameter(&param_header);
    wm.addParameter(&param_anth_header);
    wm.addParameter(&p_anthropic_key);
    wm.addParameter(&p_anthropic_org);
    wm.addParameter(&param_oai_header);
    wm.addParameter(&p_openai_key);
    wm.addParameter(&p_openai_org);
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

    // Save custom parameters if config portal was used
    if (shouldSaveConfig) {
        strlcpy(g_config.anthropic_key, p_anthropic_key.getValue(), sizeof(g_config.anthropic_key));
        strlcpy(g_config.anthropic_org, p_anthropic_org.getValue(), sizeof(g_config.anthropic_org));
        strlcpy(g_config.openai_key, p_openai_key.getValue(), sizeof(g_config.openai_key));
        strlcpy(g_config.openai_org, p_openai_org.getValue(), sizeof(g_config.openai_org));

        uint32_t poll = atoi(p_poll.getValue());
        if (poll >= 10 && poll <= 86400) {
            g_config.poll_interval_sec = poll;
        }

        config_save(g_config);
        Serial.println("[WiFi] Config saved from portal");
    }

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
