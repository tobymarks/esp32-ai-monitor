/**
 * Anthropic API Client
 *
 * Fetches usage (tokens) and cost data from the Anthropic Admin API.
 * Uses WiFiClientSecure + HTTPClient for HTTPS requests.
 * ArduinoJson for memory-efficient stream parsing.
 *
 * API docs: https://docs.anthropic.com/en/api/admin-api
 */

#include "api_anthropic.h"
#include "config.h"
#include "ntp_time.h"

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
static const char *TAG = "Anthropic";
static const char *API_BASE = "https://api.anthropic.com/v1/organizations";
static const char *API_VERSION = "2023-06-01";
static const int HTTP_TIMEOUT_MS = 15000;
static const int MAX_RETRIES = 3;
static const int RETRY_BASE_MS = 2000;  // Exponential backoff base

// ============================================================
// Build ISO 8601 timestamp from epoch (UTC)
// ============================================================
static void epoch_to_iso8601(time_t epoch, char *buf, size_t len) {
    struct tm utc;
    gmtime_r(&epoch, &utc);
    strftime(buf, len, "%Y-%m-%dT%H:%M:%SZ", &utc);
}

// ============================================================
// Create a configured WiFiClientSecure (heap-managed)
// ============================================================
static WiFiClientSecure* create_client() {
    WiFiClientSecure *client = new WiFiClientSecure();
    if (client) {
        // TODO: Embed root CA certificate for api.anthropic.com
        // For now, skip certificate verification
        client->setInsecure();
        client->setTimeout(HTTP_TIMEOUT_MS / 1000);
    }
    return client;
}

// ============================================================
// Perform HTTP GET with retry + backoff
// Returns HTTP status code, or negative on error
// Response body is available via http.getStream()
// ============================================================
static int http_get_with_retry(HTTPClient &http, WiFiClientSecure *client,
                               const String &url, char *error_buf, size_t error_len) {
    for (int attempt = 1; attempt <= MAX_RETRIES; attempt++) {
        if (attempt > 1) {
            int wait = RETRY_BASE_MS * (1 << (attempt - 2));  // 2s, 4s
            Serial.printf("[%s] Retry %d/%d in %dms\n", TAG, attempt, MAX_RETRIES, wait);
            delay(wait);
        }

        if (!http.begin(*client, url)) {
            Serial.printf("[%s] HTTPClient.begin() failed\n", TAG);
            snprintf(error_buf, error_len, "HTTP begin failed");
            continue;
        }

        // Set headers
        http.addHeader("anthropic-version", API_VERSION);
        http.addHeader("x-api-key", g_config.anthropic_key);
        http.setTimeout(HTTP_TIMEOUT_MS);

        int httpCode = http.GET();
        Serial.printf("[%s] GET %s -> %d\n", TAG, url.c_str(), httpCode);

        if (httpCode == 200) {
            return httpCode;
        }

        // Log error body for debugging
        if (httpCode > 0) {
            String body = http.getString();
            Serial.printf("[%s] Error body: %s\n", TAG, body.c_str());
            snprintf(error_buf, error_len, "HTTP %d", httpCode);
        } else {
            Serial.printf("[%s] Connection error: %s\n", TAG, http.errorToString(httpCode).c_str());
            snprintf(error_buf, error_len, "%s", http.errorToString(httpCode).c_str());
        }

        http.end();

        // Don't retry on auth errors
        if (httpCode == 401 || httpCode == 403) {
            snprintf(error_buf, error_len, "Auth error %d", httpCode);
            return httpCode;
        }
    }

    return -1;  // All retries failed
}

// ============================================================
// Parse usage response JSON from stream
// Accumulates tokens into UsageData (additive — call for today, then month)
// is_today: true = accumulate into today_* fields, false = month_*
// ============================================================
static bool parse_usage_response(WiFiClient &stream, UsageData &data, bool is_today) {
    // Use a filter to reduce memory usage
    JsonDocument filter;
    filter["data"][0]["input_tokens"] = true;
    filter["data"][0]["output_tokens"] = true;
    filter["data"][0]["cache_read_input_tokens"] = true;
    filter["data"][0]["cache_creation_input_tokens"] = true;
    filter["data"][0]["model"] = true;

    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, stream, DeserializationOption::Filter(filter));

    if (err) {
        Serial.printf("[%s] JSON parse error: %s\n", TAG, err.c_str());
        return false;
    }

    JsonArray dataArr = doc["data"].as<JsonArray>();
    if (dataArr.isNull()) {
        Serial.printf("[%s] No 'data' array in response\n", TAG);
        return false;
    }

    for (JsonObject item : dataArr) {
        uint32_t in_tok  = item["input_tokens"] | (uint32_t)0;
        uint32_t out_tok = item["output_tokens"] | (uint32_t)0;
        uint32_t cache_read = item["cache_read_input_tokens"] | (uint32_t)0;
        uint32_t cache_create = item["cache_creation_input_tokens"] | (uint32_t)0;
        uint32_t cached = cache_read + cache_create;
        const char *model = item["model"] | "unknown";

        if (is_today) {
            data.today_input_tokens  += in_tok;
            data.today_output_tokens += out_tok;
            data.today_cached_tokens += cached;
        } else {
            data.month_input_tokens  += in_tok;
            data.month_output_tokens += out_tok;
            data.month_cached_tokens += cached;
        }

        // Add to per-model breakdown (month totals)
        if (!is_today) {
            ModelUsage *m = usage_find_or_add_model(data, model);
            if (m) {
                m->input_tokens  += in_tok;
                m->output_tokens += out_tok;
                m->cached_tokens += cached;
            }
        }
    }

    Serial.printf("[%s] Parsed %d usage buckets (%s)\n", TAG,
                  dataArr.size(), is_today ? "today" : "month");
    return true;
}

// ============================================================
// Fetch usage data for a time range
// ============================================================
static bool fetch_usage_range(UsageData &data, time_t start, time_t end, bool is_today) {
    char start_str[32], end_str[32];
    epoch_to_iso8601(start, start_str, sizeof(start_str));
    epoch_to_iso8601(end, end_str, sizeof(end_str));

    String url = String(API_BASE) + "/usage_report/messages"
                 "?starting_at=" + String(start_str) +
                 "&ending_at=" + String(end_str) +
                 "&bucket_width=1d"
                 "&group_by[]=model";

    Serial.printf("[%s] Fetching usage: %s to %s\n", TAG, start_str, end_str);

    WiFiClientSecure *client = create_client();
    if (!client) {
        snprintf(data.error, sizeof(data.error), "Out of memory");
        return false;
    }

    HTTPClient http;
    int code = http_get_with_retry(http, client, url, data.error, sizeof(data.error));
    bool ok = false;

    if (code == 200) {
        WiFiClient &stream = http.getStream();
        ok = parse_usage_response(stream, data, is_today);
        if (!ok) {
            snprintf(data.error, sizeof(data.error), "JSON parse failed");
        }
    }

    http.end();
    delete client;
    return ok;
}

// ============================================================
// Public: Fetch Anthropic usage (today + month)
// ============================================================
bool anthropic_fetch_usage(UsageData &data) {
    if (strlen(g_config.anthropic_key) == 0) {
        snprintf(data.error, sizeof(data.error), "No API key");
        Serial.printf("[%s] Skipping usage fetch — no API key configured\n", TAG);
        return false;
    }

    if (!ntp_is_synced()) {
        snprintf(data.error, sizeof(data.error), "NTP not synced");
        return false;
    }

    // Clear previous token data (keep costs)
    data.today_input_tokens  = 0;
    data.today_output_tokens = 0;
    data.today_cached_tokens = 0;
    data.today_requests      = 0;
    data.month_input_tokens  = 0;
    data.month_output_tokens = 0;
    data.month_cached_tokens = 0;
    data.month_requests      = 0;
    data.model_count         = 0;

    time_t now = ntp_get_epoch();
    time_t day_start = ntp_get_day_start();
    time_t month_start = ntp_get_month_start();

    // Convert local times to UTC for API (API expects UTC)
    // ntp_get_day_start() returns local epoch, need UTC boundaries
    // We use gmtime on the local epoch to get UTC 00:00 of today
    struct tm utc_now;
    gmtime_r(&now, &utc_now);

    // UTC start of today
    struct tm utc_day = utc_now;
    utc_day.tm_hour = 0;
    utc_day.tm_min  = 0;
    utc_day.tm_sec  = 0;
    time_t utc_day_start = timegm_compat(&utc_day);

    // UTC start of this month
    struct tm utc_month = utc_now;
    utc_month.tm_mday = 1;
    utc_month.tm_hour = 0;
    utc_month.tm_min  = 0;
    utc_month.tm_sec  = 0;
    time_t utc_month_start = timegm_compat(&utc_month);

    // Fetch today's usage
    bool ok_today = fetch_usage_range(data, utc_day_start, now, true);

    // Fetch month usage
    bool ok_month = fetch_usage_range(data, utc_month_start, now, false);

    // Also copy today's totals into month totals (today is part of month)
    // Actually the month query already includes today, so no double-add needed

    if (ok_today || ok_month) {
        data.valid = true;
        data.last_fetch = millis();
        data.error[0] = '\0';

        Serial.printf("[%s] Usage OK — Today: %u in / %u out / %u cached | Month: %u in / %u out\n",
                      TAG, data.today_input_tokens, data.today_output_tokens, data.today_cached_tokens,
                      data.month_input_tokens, data.month_output_tokens);
        return true;
    }

    return false;
}

// ============================================================
// Parse cost response JSON
// ============================================================
static bool parse_cost_response(WiFiClient &stream, float &cost_out) {
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, stream);

    if (err) {
        Serial.printf("[%s] Cost JSON parse error: %s\n", TAG, err.c_str());
        return false;
    }

    cost_out = 0.0f;
    JsonArray dataArr = doc["data"].as<JsonArray>();
    if (dataArr.isNull()) return false;

    for (JsonObject bucket : dataArr) {
        // Each bucket may have a "cost_usd" or similar field
        // The cost_report returns buckets with cost values
        float bucket_cost = bucket["cost_usd"] | 0.0f;
        cost_out += bucket_cost;
    }

    Serial.printf("[%s] Parsed cost: $%.4f\n", TAG, cost_out);
    return true;
}

// ============================================================
// Fetch costs for a time range
// ============================================================
static bool fetch_cost_range(float &cost_out, time_t start, time_t end, char *error_buf, size_t error_len) {
    char start_str[32], end_str[32];
    epoch_to_iso8601(start, start_str, sizeof(start_str));
    epoch_to_iso8601(end, end_str, sizeof(end_str));

    String url = String(API_BASE) + "/cost_report"
                 "?starting_at=" + String(start_str) +
                 "&ending_at=" + String(end_str) +
                 "&bucket_width=1d";

    Serial.printf("[%s] Fetching costs: %s to %s\n", TAG, start_str, end_str);

    WiFiClientSecure *client = create_client();
    if (!client) {
        snprintf(error_buf, error_len, "Out of memory");
        return false;
    }

    HTTPClient http;
    int code = http_get_with_retry(http, client, url, error_buf, error_len);
    bool ok = false;

    if (code == 200) {
        WiFiClient &stream = http.getStream();
        ok = parse_cost_response(stream, cost_out);
        if (!ok) {
            snprintf(error_buf, error_len, "Cost JSON parse failed");
        }
    }

    http.end();
    delete client;
    return ok;
}

// ============================================================
// Public: Fetch Anthropic costs (today + month)
// ============================================================
bool anthropic_fetch_costs(UsageData &data) {
    if (strlen(g_config.anthropic_key) == 0) {
        Serial.printf("[%s] Skipping cost fetch — no API key\n", TAG);
        return false;
    }

    if (!ntp_is_synced()) return false;

    time_t now = ntp_get_epoch();

    // UTC boundaries (same logic as usage fetch)
    struct tm utc_now;
    gmtime_r(&now, &utc_now);

    struct tm utc_day = utc_now;
    utc_day.tm_hour = 0; utc_day.tm_min = 0; utc_day.tm_sec = 0;
    time_t utc_day_start = timegm_compat(&utc_day);

    struct tm utc_month = utc_now;
    utc_month.tm_mday = 1; utc_month.tm_hour = 0; utc_month.tm_min = 0; utc_month.tm_sec = 0;
    time_t utc_month_start = timegm_compat(&utc_month);

    float today_cost = 0.0f, month_cost = 0.0f;
    bool ok_today = fetch_cost_range(today_cost, utc_day_start, now, data.error, sizeof(data.error));
    bool ok_month = fetch_cost_range(month_cost, utc_month_start, now, data.error, sizeof(data.error));

    if (ok_today) data.today_cost = today_cost;
    if (ok_month) data.month_cost = month_cost;

    if (ok_today || ok_month) {
        Serial.printf("[%s] Costs OK — Today: $%.4f | Month: $%.4f\n", TAG, data.today_cost, data.month_cost);
        return true;
    }

    return false;
}
