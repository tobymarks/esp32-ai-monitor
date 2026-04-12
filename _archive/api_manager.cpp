/**
 * API Manager
 *
 * Coordinates OAuth usage fetching (read-only, no token refresh).
 * Token is pushed from Mac via /api/token endpoint.
 */

#include "api_manager.h"
#include "api_claude.h"
#include "config.h"
#include "ntp_time.h"
#include "wifi_setup.h"

#include <Arduino.h>

// ============================================================
// External config
// ============================================================
extern AppConfig g_config;

// ============================================================
// State  (accessed from main loop AND AsyncWebServer task)
// No spinlock needed — single-writer per field, atomic-safe copies.
// ============================================================
static volatile bool state_updating = false;
static MonitorState state;
static unsigned long last_fetch_time = 0;
static bool initialized = false;
static bool first_fetch_done = false;

static const unsigned long MIN_FETCH_INTERVAL_MS = 60000;
static const unsigned long RATE_LIMIT_COOLDOWN_MS = 60000;
static bool last_cycle_rate_limited = false;

// ============================================================
// Init
// ============================================================
void api_manager_init() {
    memset(&state, 0, sizeof(state));
    usage_data_clear(state.usage);
    state.is_fetching  = false;
    state.token_valid  = strlen(g_config.access_token) > 0;
    state.provider     = g_config.provider;
    strlcpy(state.status, "Initializing", sizeof(state.status));

    initialized     = true;
    first_fetch_done = false;
    last_fetch_time = 0;

    Serial.println("[APIManager] Initialized (read-only OAuth, no refresh)");
    Serial.printf("[APIManager] Poll interval: %u sec\n", g_config.poll_interval_sec);
    Serial.printf("[APIManager] Token: %s\n", state.token_valid ? "present" : "not set");
}

// ============================================================
// Fetch usage (read-only — never refreshes token)
// ============================================================
void api_manager_fetch() {
    if (!wifi_is_connected()) {
        strlcpy(state.status, "WiFi disconnected", sizeof(state.status));
        return;
    }

    state.is_fetching = true;

    Serial.println("[APIManager] ======= Fetch cycle =======");
    Serial.printf("[APIManager] Free heap: %u bytes\n", ESP.getFreeHeap());

    if (strlen(g_config.access_token) == 0) {
        strlcpy(state.status, "No token", sizeof(state.status));
        strlcpy(state.usage.error, "No token — push via /api/token", sizeof(state.usage.error));
        state.token_valid = false;
        state.is_fetching = false;
        first_fetch_done  = true;
        last_fetch_time   = millis();
        Serial.println("[APIManager] No access token");
        return;
    }

    strlcpy(state.status, "Fetching...", sizeof(state.status));
    claude_fetch_usage(state.usage);

    last_cycle_rate_limited = claude_was_rate_limited();
    if (last_cycle_rate_limited) {
        Serial.printf("[APIManager] Rate-limited — cooldown %lu sec\n", RATE_LIMIT_COOLDOWN_MS / 1000UL);
    }

    state.token_valid = state.usage.valid;
    state.is_fetching = false;
    strlcpy(state.status, state.usage.valid ? "OK" : state.usage.error, sizeof(state.status));
    last_fetch_time  = millis();
    first_fetch_done = true;

    Serial.printf("[APIManager] Session: %.0f%% | Weekly: %.0f%%\n",
                  state.usage.five_hour_utilization  * 100.0f,
                  state.usage.seven_day_utilization  * 100.0f);
    Serial.printf("[APIManager] Heap after: %u bytes\n", ESP.getFreeHeap());
}

// ============================================================
// Tick
// ============================================================
void api_manager_tick() {
    if (!initialized) return;
    if (state.is_fetching) return;

    unsigned long now = millis();

    if (!first_fetch_done) {
        api_manager_fetch();
        return;
    }

    unsigned long interval_ms = (unsigned long)g_config.poll_interval_sec * 1000UL;
    if (interval_ms < MIN_FETCH_INTERVAL_MS) interval_ms = MIN_FETCH_INTERVAL_MS;
    if (last_cycle_rate_limited && interval_ms < RATE_LIMIT_COOLDOWN_MS) interval_ms = RATE_LIMIT_COOLDOWN_MS;

    if (now - last_fetch_time >= interval_ms) {
        api_manager_fetch();
    }
}

// ============================================================
// Get state
// ============================================================
MonitorState api_manager_get_state() {
    MonitorState copy;
    memcpy(&copy, &state, sizeof(MonitorState));
    return copy;
}

// ============================================================
// Push usage (from companion app)
// ============================================================
void api_manager_push_usage(const UsageData &pushed) {
    state_updating = true;
    memcpy(&state.usage, &pushed, sizeof(UsageData));
    state.usage.valid = true;
    state.usage.last_fetch = millis();
    state.token_valid = true;
    state.is_fetching = false;
    strlcpy(state.status, "OK (pushed)", sizeof(state.status));
    last_fetch_time = millis();
    first_fetch_done = true;
    last_cycle_rate_limited = false;
    state_updating = false;
    Serial.printf("[APIManager] Usage pushed — Session: %.0f%% | Weekly: %.0f%%\n",
                  pushed.five_hour_utilization * 100.0f,
                  pushed.seven_day_utilization * 100.0f);
}
