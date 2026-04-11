/**
 * Claude OAuth API Client — Read-Only
 *
 * Fetches usage data from /api/oauth/usage using a Bearer token.
 * The ESP32 NEVER refreshes the token — it receives fresh tokens
 * via periodic push from the Mac (cron job → /api/token).
 * This avoids consuming the CLI's refresh token chain.
 */

#include "api_claude.h"
#include "config.h"
#include "wifi_setup.h"

#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>

// ============================================================
// External config
// ============================================================
extern AppConfig g_config;

// ============================================================
// Constants
// ============================================================
static const char *TAG             = "Claude";
static const int  HTTP_TIMEOUT_MS  = 15000;
static const int  MAX_RETRIES      = 2;
static const int  RETRY_DELAYS_MS[] = { 10000, 30000 };

// Rate-limit tracking
static int last_retry_after_sec = 0;
static bool last_fetch_was_rate_limited = false;

// ============================================================
// Create a configured WiFiClientSecure (heap-managed)
// ============================================================
static WiFiClientSecure* create_client() {
    WiFiClientSecure *client = new WiFiClientSecure();
    if (client) {
        client->setInsecure();
        client->setTimeout(HTTP_TIMEOUT_MS / 1000);
    }
    return client;
}

// ============================================================
// Internal: Single usage fetch
// GET https://api.anthropic.com/api/oauth/usage
// ============================================================
static int fetch_usage_once(UsageData &data) {
    WiFiClientSecure *client = create_client();
    if (!client) {
        snprintf(data.error, sizeof(data.error), "Out of memory");
        return -1;
    }

    HTTPClient http;
    int httpCode = -1;

    if (!http.begin(*client, CLAUDE_USAGE_ENDPOINT)) {
        Serial.printf("[%s] HTTP begin failed\n", TAG);
        snprintf(data.error, sizeof(data.error), "HTTP begin failed");
        delete client;
        return -1;
    }

    http.addHeader("Authorization", String("Bearer ") + String(g_config.access_token));
    http.addHeader("anthropic-beta", CLAUDE_OAUTH_BETA);
    http.setTimeout(HTTP_TIMEOUT_MS);

    // Collect Retry-After header
    const char *headerKeys[] = { "Retry-After" };
    http.collectHeaders(headerKeys, 1);

    httpCode = http.GET();
    Serial.printf("[%s] GET /api/oauth/usage -> %d\n", TAG, httpCode);

    // Reset retry-after tracking
    last_retry_after_sec = 0;

    if (httpCode == 429) {
        last_fetch_was_rate_limited = true;
        if (http.hasHeader("Retry-After")) {
            String retryAfter = http.header("Retry-After");
            last_retry_after_sec = retryAfter.toInt();
            Serial.printf("[%s] 429 Rate Limited — Retry-After: %d sec\n", TAG, last_retry_after_sec);
        }
        String errBody = http.getString();
        Serial.printf("[%s] 429 body: %s\n", TAG, errBody.c_str());
        snprintf(data.error, sizeof(data.error), "Rate limited (429)");

    } else if (httpCode == 401) {
        Serial.printf("[%s] 401 — Token expired, waiting for push\n", TAG);
        snprintf(data.error, sizeof(data.error), "Token expired");
        // Do NOT attempt refresh — wait for next push from Mac

    } else if (httpCode == 200) {
        JsonDocument doc;
        DeserializationError err = deserializeJson(doc, http.getStream());

        if (err) {
            Serial.printf("[%s] JSON parse error: %s\n", TAG, err.c_str());
            snprintf(data.error, sizeof(data.error), "JSON parse: %s", err.c_str());
            httpCode = -2;
        } else {
            // five_hour (Session)
            data.five_hour_utilization = doc["five_hour"]["utilization"] | 0.0f;
            const char *fh_resets = doc["five_hour"]["resets_at"] | "";
            strlcpy(data.five_hour_resets_at, fh_resets, sizeof(data.five_hour_resets_at));
            data.five_hour_reset_epoch = iso8601_to_epoch(fh_resets);

            // seven_day (Weekly)
            data.seven_day_utilization = doc["seven_day"]["utilization"] | 0.0f;
            const char *sd_resets = doc["seven_day"]["resets_at"] | "";
            strlcpy(data.seven_day_resets_at, sd_resets, sizeof(data.seven_day_resets_at));
            data.seven_day_reset_epoch = iso8601_to_epoch(sd_resets);

            // extra_usage
            data.has_extra_usage     = doc["extra_usage"]["is_enabled"]     | false;
            data.extra_monthly_limit = doc["extra_usage"]["monthly_limit"]  | 0.0f;
            data.extra_used_credits  = doc["extra_usage"]["used_credits"]   | 0.0f;
            data.extra_utilization   = doc["extra_usage"]["utilization"]    | 0.0f;

            data.valid      = true;
            data.last_fetch = millis();
            data.error[0]   = '\0';

            Serial.printf("[%s] Usage OK — Session: %.0f%% | Weekly: %.0f%% | Extra: %.0f%%\n",
                          TAG,
                          data.five_hour_utilization  * 100.0f,
                          data.seven_day_utilization  * 100.0f,
                          data.extra_utilization      * 100.0f);
        }
    } else if (httpCode > 0) {
        String errBody = http.getString();
        Serial.printf("[%s] Error: %s\n", TAG, errBody.c_str());
        snprintf(data.error, sizeof(data.error), "HTTP %d", httpCode);
    } else {
        Serial.printf("[%s] Connection error: %s\n", TAG, http.errorToString(httpCode).c_str());
        snprintf(data.error, sizeof(data.error), "%s", http.errorToString(httpCode).c_str());
    }

    http.end();
    delete client;
    return httpCode;
}

// ============================================================
// Public: Fetch Claude usage data (with retry)
// ============================================================
bool claude_fetch_usage(UsageData &data) {
    if (strlen(g_config.access_token) == 0) {
        snprintf(data.error, sizeof(data.error), "No token");
        Serial.printf("[%s] Skipping — no access token\n", TAG);
        return false;
    }

    last_fetch_was_rate_limited = false;

    for (int attempt = 1; attempt <= MAX_RETRIES; attempt++) {
        if (attempt > 1) {
            int wait_ms;
            if (last_retry_after_sec > 0) {
                wait_ms = last_retry_after_sec * 1000;
                Serial.printf("[%s] Retry %d/%d — Retry-After %d sec\n",
                              TAG, attempt, MAX_RETRIES, last_retry_after_sec);
            } else {
                int idx = (attempt - 2);
                if (idx >= (int)(sizeof(RETRY_DELAYS_MS) / sizeof(RETRY_DELAYS_MS[0]))) {
                    idx = (sizeof(RETRY_DELAYS_MS) / sizeof(RETRY_DELAYS_MS[0])) - 1;
                }
                wait_ms = RETRY_DELAYS_MS[idx];
                Serial.printf("[%s] Retry %d/%d in %dms\n", TAG, attempt, MAX_RETRIES, wait_ms);
            }
            delay(wait_ms);
        }

        int code = fetch_usage_once(data);

        if (data.valid) return true;

        // 401 = token expired, no point retrying (wait for push)
        if (code == 401) return false;

        // Parse error = no point retrying
        if (code == -2) return false;
    }

    return false;
}

// ============================================================
// Public: Check if last fetch was rate-limited
// ============================================================
bool claude_was_rate_limited() {
    return last_fetch_was_rate_limited;
}
