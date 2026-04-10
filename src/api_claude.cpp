/**
 * Claude OAuth API Client
 *
 * Handles OAuth token refresh and usage fetching via the Claude OAuth API.
 * Uses WiFiClientSecure + HTTPClient for HTTPS requests.
 * ArduinoJson v7 for JSON parsing.
 */

#include "api_claude.h"
#include "config.h"
#include "wifi_setup.h"

#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>

// ============================================================
// External config + save function
// ============================================================
extern AppConfig g_config;
extern void config_save(const AppConfig &cfg);

// ============================================================
// Constants
// ============================================================
static const char *TAG             = "Claude";
static const int  HTTP_TIMEOUT_MS  = 15000;
static const int  MAX_RETRIES      = 3;
static const int  RETRY_BASE_MS    = 2000;

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
// Public: Refresh OAuth access token
// POST https://platform.claude.com/v1/oauth/token
// ============================================================
bool claude_refresh_token() {
    if (strlen(g_config.refresh_token) == 0) {
        Serial.printf("[%s] No refresh token — cannot refresh\n", TAG);
        return false;
    }

    WiFiClientSecure *client = create_client();
    if (!client) {
        Serial.printf("[%s] OOM creating client\n", TAG);
        return false;
    }

    HTTPClient http;
    bool ok = false;

    String url = "https://platform.claude.com/v1/oauth/token";

    if (!http.begin(*client, url)) {
        Serial.printf("[%s] token refresh: HTTP begin failed\n", TAG);
        delete client;
        return false;
    }

    http.addHeader("Content-Type", "application/x-www-form-urlencoded");
    http.setTimeout(HTTP_TIMEOUT_MS);

    String body = String("grant_type=refresh_token")
                + "&refresh_token=" + String(g_config.refresh_token)
                + "&client_id=" + String(CLAUDE_OAUTH_CLIENT_ID);

    int httpCode = http.POST(body);
    Serial.printf("[%s] POST token -> %d\n", TAG, httpCode);

    if (httpCode == 200) {
        JsonDocument doc;
        DeserializationError err = deserializeJson(doc, http.getStream());

        if (err) {
            Serial.printf("[%s] Token JSON parse error: %s\n", TAG, err.c_str());
        } else {
            const char *access_token  = doc["access_token"]  | "";
            const char *refresh_token = doc["refresh_token"] | "";
            uint32_t    expires_in    = doc["expires_in"]    | (uint32_t)0;

            if (strlen(access_token) > 0) {
                strlcpy(g_config.access_token,  access_token,  sizeof(g_config.access_token));
                if (strlen(refresh_token) > 0) {
                    strlcpy(g_config.refresh_token, refresh_token, sizeof(g_config.refresh_token));
                }
                g_config.expires_at = (uint32_t)time(nullptr) + expires_in;
                config_save(g_config);

                Serial.printf("[%s] Token refreshed, expires in %u sec\n", TAG, expires_in);
                ok = true;
            } else {
                Serial.printf("[%s] Token response missing access_token\n", TAG);
            }
        }
    } else if (httpCode == 401) {
        Serial.printf("[%s] Refresh token invalid (401) — re-auth required\n", TAG);
        // No retry — token is genuinely invalid
    } else {
        if (httpCode > 0) {
            String errBody = http.getString();
            Serial.printf("[%s] Token error body: %s\n", TAG, errBody.c_str());
        } else {
            Serial.printf("[%s] Token connection error: %s\n", TAG, http.errorToString(httpCode).c_str());
        }
    }

    http.end();
    delete client;
    return ok;
}

// ============================================================
// Internal: Attempt a single usage fetch
// Returns HTTP status code, fills data on 200
// ============================================================
static int fetch_usage_once(UsageData &data) {
    WiFiClientSecure *client = create_client();
    if (!client) {
        snprintf(data.error, sizeof(data.error), "Out of memory");
        return -1;
    }

    HTTPClient http;
    int httpCode = -1;

    String url = "https://api.anthropic.com/api/oauth/usage";

    if (!http.begin(*client, url)) {
        Serial.printf("[%s] usage: HTTP begin failed\n", TAG);
        snprintf(data.error, sizeof(data.error), "HTTP begin failed");
        delete client;
        return -1;
    }

    http.addHeader("Authorization", String("Bearer ") + String(g_config.access_token));
    http.addHeader("anthropic-beta", "oauth-2025-04-20");
    http.setTimeout(HTTP_TIMEOUT_MS);

    httpCode = http.GET();
    Serial.printf("[%s] GET usage -> %d\n", TAG, httpCode);

    if (httpCode == 200) {
        JsonDocument doc;
        DeserializationError err = deserializeJson(doc, http.getStream());

        if (err) {
            Serial.printf("[%s] Usage JSON parse error: %s\n", TAG, err.c_str());
            snprintf(data.error, sizeof(data.error), "JSON parse error: %s", err.c_str());
            httpCode = -2;  // signal parse failure, not HTTP error
        } else {
            // five_hour
            data.five_hour_utilization = doc["five_hour"]["utilization"] | 0.0f;
            const char *fh_resets = doc["five_hour"]["resets_at"] | "";
            strlcpy(data.five_hour_resets_at, fh_resets, sizeof(data.five_hour_resets_at));
            data.five_hour_reset_epoch = iso8601_to_epoch(fh_resets);

            // seven_day
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

            Serial.printf("[%s] Usage OK — 5h: %.0f%% | 7d: %.0f%% | extra: %.0f%% (enabled: %d)\n",
                          TAG,
                          data.five_hour_utilization  * 100.0f,
                          data.seven_day_utilization  * 100.0f,
                          data.extra_utilization      * 100.0f,
                          (int)data.has_extra_usage);
        }
    } else if (httpCode > 0) {
        String errBody = http.getString();
        Serial.printf("[%s] Usage error body: %s\n", TAG, errBody.c_str());
        snprintf(data.error, sizeof(data.error), "HTTP %d", httpCode);
    } else {
        Serial.printf("[%s] Usage connection error: %s\n", TAG, http.errorToString(httpCode).c_str());
        snprintf(data.error, sizeof(data.error), "%s", http.errorToString(httpCode).c_str());
    }

    http.end();
    delete client;
    return httpCode;
}

// ============================================================
// Public: Fetch Claude OAuth usage data
// Retry up to MAX_RETRIES with backoff; on 401 refresh token and retry once
// ============================================================
bool claude_fetch_usage(UsageData &data) {
    if (strlen(g_config.access_token) == 0) {
        snprintf(data.error, sizeof(data.error), "No access token");
        Serial.printf("[%s] Skipping usage fetch — no access token\n", TAG);
        return false;
    }

    bool token_refreshed = false;

    for (int attempt = 1; attempt <= MAX_RETRIES; attempt++) {
        if (attempt > 1) {
            int wait = RETRY_BASE_MS * (1 << (attempt - 2));  // 2s, 4s
            Serial.printf("[%s] Retry %d/%d in %dms\n", TAG, attempt, MAX_RETRIES, wait);
            delay(wait);
        }

        int code = fetch_usage_once(data);

        if (data.valid) {
            return true;  // Success
        }

        if (code == 401) {
            if (!token_refreshed) {
                Serial.printf("[%s] 401 — attempting token refresh\n", TAG);
                if (claude_refresh_token()) {
                    token_refreshed = true;
                    // Retry immediately after refresh (don't consume an attempt slot)
                    int retry_code = fetch_usage_once(data);
                    if (data.valid) return true;
                    // If still failing (not 401), fall through to backoff retries
                    if (retry_code == 401) {
                        Serial.printf("[%s] Still 401 after refresh — aborting\n", TAG);
                        return false;
                    }
                } else {
                    Serial.printf("[%s] Token refresh failed — aborting\n", TAG);
                    return false;
                }
            } else {
                // Already refreshed, still 401 — abort
                Serial.printf("[%s] 401 after token refresh — aborting\n", TAG);
                return false;
            }
        }

        // Non-401 failure: continue retry loop (unless last attempt)
        if (code == -2) {
            // Parse error — no point retrying
            return false;
        }
    }

    return false;
}
