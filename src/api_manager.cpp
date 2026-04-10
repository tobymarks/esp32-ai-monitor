/**
 * API Manager
 *
 * Coordinates sequential fetching of Anthropic + OpenAI usage/cost data.
 * Timer-based polling with configurable interval.
 * Sequential (not parallel) to conserve heap — WiFiClientSecure uses ~45KB.
 */

#include "api_manager.h"
#include "api_anthropic.h"
#include "api_openai.h"
#include "config.h"
#include "ntp_time.h"
#include "wifi_setup.h"

#include <Arduino.h>

// ============================================================
// External config
// ============================================================
extern AppConfig g_config;

// ============================================================
// State
// ============================================================
static MonitorState state;
static unsigned long last_fetch_time = 0;
static bool initialized = false;
static bool first_fetch_done = false;

// Minimum interval between fetches (60 seconds, per Anthropic recommendation)
static const unsigned long MIN_FETCH_INTERVAL_MS = 60000;

// ============================================================
// Init
// ============================================================
void api_manager_init() {
    memset(&state, 0, sizeof(state));
    usage_data_clear(state.anthropic);
    usage_data_clear(state.openai);
    state.is_fetching = false;
    strlcpy(state.status, "Initializing", sizeof(state.status));

    initialized = true;
    first_fetch_done = false;
    last_fetch_time = 0;  // Force immediate first fetch

    Serial.println("[APIManager] Initialized");
    Serial.printf("[APIManager] Poll interval: %u sec\n", g_config.poll_interval_sec);
    Serial.printf("[APIManager] Anthropic key: %s\n", strlen(g_config.anthropic_key) > 0 ? "configured" : "not set");
    Serial.printf("[APIManager] OpenAI key: %s\n", strlen(g_config.openai_key) > 0 ? "configured" : "not set");
}

// ============================================================
// Fetch all APIs sequentially
// ============================================================
void api_manager_fetch() {
    if (!wifi_is_connected()) {
        strlcpy(state.status, "WiFi disconnected", sizeof(state.status));
        Serial.println("[APIManager] Skipping fetch — WiFi not connected");
        return;
    }

    if (!ntp_is_synced()) {
        strlcpy(state.status, "NTP not synced", sizeof(state.status));
        Serial.println("[APIManager] Skipping fetch — NTP not synced");
        return;
    }

    state.is_fetching = true;

    Serial.println("[APIManager] ======= Starting fetch cycle =======");
    Serial.printf("[APIManager] Free heap before: %u bytes\n", ESP.getFreeHeap());

    // --- Anthropic ---
    if (strlen(g_config.anthropic_key) > 0) {
        strlcpy(state.status, "Fetching Anthropic...", sizeof(state.status));
        Serial.println("[APIManager] --- Anthropic Usage ---");
        anthropic_fetch_usage(state.anthropic);

        Serial.printf("[APIManager] Heap after Anthropic usage: %u bytes\n", ESP.getFreeHeap());

        Serial.println("[APIManager] --- Anthropic Costs ---");
        anthropic_fetch_costs(state.anthropic);

        Serial.printf("[APIManager] Heap after Anthropic costs: %u bytes\n", ESP.getFreeHeap());
    } else {
        strlcpy(state.anthropic.error, "No API key", sizeof(state.anthropic.error));
    }

    // --- OpenAI ---
    if (strlen(g_config.openai_key) > 0) {
        strlcpy(state.status, "Fetching OpenAI...", sizeof(state.status));
        Serial.println("[APIManager] --- OpenAI Usage ---");
        openai_fetch_usage(state.openai);

        Serial.printf("[APIManager] Heap after OpenAI usage: %u bytes\n", ESP.getFreeHeap());

        Serial.println("[APIManager] --- OpenAI Costs ---");
        openai_fetch_costs(state.openai);

        Serial.printf("[APIManager] Heap after OpenAI costs: %u bytes\n", ESP.getFreeHeap());
    } else {
        strlcpy(state.openai.error, "No API key", sizeof(state.openai.error));
    }

    // --- Calculate totals ---
    state.total_today_cost = state.anthropic.today_cost + state.openai.today_cost;
    state.total_month_cost = state.anthropic.month_cost + state.openai.month_cost;

    state.is_fetching = false;
    strlcpy(state.status, "Idle", sizeof(state.status));
    last_fetch_time = millis();
    first_fetch_done = true;

    Serial.println("[APIManager] ======= Fetch cycle complete =======");
    Serial.printf("[APIManager] Total cost today: $%.4f | month: $%.4f\n",
                  state.total_today_cost, state.total_month_cost);
    Serial.printf("[APIManager] Free heap after: %u bytes\n", ESP.getFreeHeap());
}

// ============================================================
// Tick — call from loop(), checks if it's time to fetch
// ============================================================
void api_manager_tick() {
    if (!initialized) return;
    if (state.is_fetching) return;

    unsigned long now = millis();

    // First fetch immediately after init
    if (!first_fetch_done) {
        api_manager_fetch();
        return;
    }

    // Enforce minimum interval (60s)
    unsigned long interval_ms = (unsigned long)g_config.poll_interval_sec * 1000UL;
    if (interval_ms < MIN_FETCH_INTERVAL_MS) {
        interval_ms = MIN_FETCH_INTERVAL_MS;
    }

    // Check if interval elapsed (handle millis() overflow)
    if (now - last_fetch_time >= interval_ms) {
        api_manager_fetch();
    }
}

// ============================================================
// Get current state
// ============================================================
const MonitorState& api_manager_get_state() {
    return state;
}
