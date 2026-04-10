#ifndef API_COMMON_H
#define API_COMMON_H

#include <Arduino.h>
#include <time.h>

// ============================================================
// timegm replacement for ESP32 (newlib doesn't have timegm)
// Converts struct tm (UTC) to time_t without timezone adjustment
// ============================================================
inline time_t timegm_compat(struct tm *tm) {
    // Save and override TZ to UTC
    const char *tz = getenv("TZ");
    setenv("TZ", "UTC0", 1);
    tzset();
    time_t t = mktime(tm);
    if (tz) {
        setenv("TZ", tz, 1);
    } else {
        unsetenv("TZ");
    }
    tzset();
    return t;
}

// ============================================================
// Shared data structures for AI provider API clients
// ============================================================

struct UsageData {
    float  five_hour_utilization;    // 0.0 - 1.0 (Session)
    char   five_hour_resets_at[32];  // ISO 8601
    time_t five_hour_reset_epoch;    // Parsed for countdown

    float  seven_day_utilization;    // 0.0 - 1.0 (Weekly)
    char   seven_day_resets_at[32];
    time_t seven_day_reset_epoch;

    bool  has_extra_usage;
    float extra_utilization;         // 0.0 - 1.0
    float extra_monthly_limit;       // USD
    float extra_used_credits;        // USD

    bool          valid;             // true if data was fetched successfully
    unsigned long last_fetch;        // millis() of last successful fetch
    char          error[64];         // Error message if !valid
};

// Overall monitor state
struct MonitorState {
    UsageData usage;
    uint8_t   provider;
    bool      is_fetching;           // true while an API call is in progress
    bool      token_valid;
    char      status[48];            // "Idle", "Fetching...", etc.
};

// ============================================================
// Helper: parse ISO 8601 UTC string to epoch
// Supports format: "2026-04-10T15:00:00Z"
// ============================================================
inline time_t iso8601_to_epoch(const char *iso) {
    if (!iso || iso[0] == '\0') return 0;
    struct tm t = {};
    // sscanf parses: YYYY-MM-DDTHH:MM:SSZ
    if (sscanf(iso, "%4d-%2d-%2dT%2d:%2d:%2dZ",
               &t.tm_year, &t.tm_mon, &t.tm_mday,
               &t.tm_hour, &t.tm_min, &t.tm_sec) != 6) {
        return 0;
    }
    t.tm_year -= 1900;
    t.tm_mon  -= 1;
    return timegm_compat(&t);
}

// ============================================================
// Helper: zero-init a UsageData struct
// ============================================================
inline void usage_data_clear(UsageData &d) {
    d.five_hour_utilization  = 0.0f;
    d.five_hour_resets_at[0] = '\0';
    d.five_hour_reset_epoch  = 0;

    d.seven_day_utilization  = 0.0f;
    d.seven_day_resets_at[0] = '\0';
    d.seven_day_reset_epoch  = 0;

    d.has_extra_usage      = false;
    d.extra_utilization    = 0.0f;
    d.extra_monthly_limit  = 0.0f;
    d.extra_used_credits   = 0.0f;

    d.valid      = false;
    d.last_fetch = 0;
    d.error[0]   = '\0';
}

#endif // API_COMMON_H
