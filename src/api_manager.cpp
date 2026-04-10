/**
 * API Manager
 *
 * Coordinates Claude OAuth token management and usage fetching.
 * Timer-based polling with configurable interval.
 * Sequential execution to conserve heap — WiFiClientSecure uses ~45KB.
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
// State
// ============================================================
static MonitorState state;
static unsigned long last_fetch_time = 0;
static bool initialized = false;
static bool first_fetch_done = false;

// Minimum interval between fetches (60 seconds)
static const unsigned long MIN_FETCH_INTERVAL_MS = 60000;

// Cooldown after rate-limiting: wait at least 60s before next poll
static const unsigned long RATE_LIMIT_COOLDOWN_MS = 60000;
static bool last_cycle_rate_limited = false;

// Token expiry lookahead: refresh if within 5 minutes of expiry
static const uint32_t TOKEN_REFRESH_MARGIN_SEC = 300;

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
    last_fetch_time = 0;  // Force immediate first fetch

    Serial.println("[APIManager] Initialized");
    Serial.printf("[APIManager] Poll interval: %u sec\n", g_config.poll_interval_sec);
    Serial.printf("[APIManager] Access token: %s\n", state.token_valid ? "configured" : "not set");
}

// ============================================================
// Fetch usage (with token refresh if needed)
// ============================================================
void api_manager_fetch() {
    if (!wifi_is_connected()) {
        strlcpy(state.status, "WiFi disconnected", sizeof(state.status));
        Serial.println("[APIManager] Skipping fetch — WiFi not connected");
        return;
    }

    state.is_fetching = true;

    Serial.println("[APIManager] ======= Starting fetch cycle =======");
    Serial.printf("[APIManager] Free heap before: %u bytes\n", ESP.getFreeHeap());

    // --- Token check ---
    if (strlen(g_config.access_token) == 0) {
        strlcpy(state.status, "No token", sizeof(state.status));
        strlcpy(state.usage.error, "No access token", sizeof(state.usage.error));
        state.token_valid    = false;
        state.is_fetching    = false;
        // Mark first fetch as done so tick() doesn't retry every loop cycle
        // when there is deliberately no token configured.
        first_fetch_done     = true;
        last_fetch_time      = millis();
        Serial.println("[APIManager] No access token — skipping fetch");
        return;
    }

    // --- Token refresh if near expiry ---
    uint32_t now_epoch = (uint32_t)time(nullptr);
    if (g_config.expires_at > 0 && now_epoch >= g_config.expires_at - TOKEN_REFRESH_MARGIN_SEC) {
        strlcpy(state.status, "Refreshing token...", sizeof(state.status));
        Serial.println("[APIManager] Token near expiry — refreshing");
        if (!claude_refresh_token()) {
            Serial.println("[APIManager] Token refresh failed");
            state.token_valid = false;
            strlcpy(state.status, "Token refresh failed", sizeof(state.status));
            state.is_fetching = false;
            return;
        }
        state.token_valid = true;
    }

    // --- Fetch usage ---
    strlcpy(state.status, "Fetching usage...", sizeof(state.status));
    Serial.println("[APIManager] --- Claude OAuth Usage ---");
    claude_fetch_usage(state.usage);

    Serial.printf("[APIManager] Heap after usage fetch: %u bytes\n", ESP.getFreeHeap());

    // Track if this cycle was rate-limited (affects next poll interval)
    last_cycle_rate_limited = claude_was_rate_limited();
    if (last_cycle_rate_limited) {
        Serial.printf("[APIManager] Rate-limited — next poll delayed by %lu sec cooldown\n",
                      RATE_LIMIT_COOLDOWN_MS / 1000UL);
    }

    state.token_valid  = state.usage.valid;
    state.is_fetching  = false;
    strlcpy(state.status, "Idle", sizeof(state.status));
    last_fetch_time   = millis();
    first_fetch_done  = true;

    Serial.println("[APIManager] ======= Fetch cycle complete =======");
    Serial.printf("[APIManager] 5h: %.0f%% | 7d: %.0f%% | extra: %.0f%%\n",
                  state.usage.five_hour_utilization  * 100.0f,
                  state.usage.seven_day_utilization  * 100.0f,
                  state.usage.extra_utilization      * 100.0f);
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

    // Enforce minimum interval (60s), extend if last cycle was rate-limited
    unsigned long interval_ms = (unsigned long)g_config.poll_interval_sec * 1000UL;
    if (interval_ms < MIN_FETCH_INTERVAL_MS) {
        interval_ms = MIN_FETCH_INTERVAL_MS;
    }
    if (last_cycle_rate_limited && interval_ms < RATE_LIMIT_COOLDOWN_MS) {
        interval_ms = RATE_LIMIT_COOLDOWN_MS;
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
