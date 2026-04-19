#ifndef API_COMMON_H
#define API_COMMON_H

#include <Arduino.h>
#include <time.h>

// ============================================================
// timegm replacement for ESP32 (newlib doesn't have timegm)
// Converts struct tm (UTC) to time_t without timezone adjustment.
// Pure arithmetic — no TZ manipulation needed.
// ============================================================
inline time_t timegm_compat(struct tm *tm) {
    // Days from 1970-01-01 to the start of each month (non-leap year)
    static const int mdays[12] = {0,31,59,90,120,151,181,212,243,273,304,334};
    int y = tm->tm_year + 1900;
    int m = tm->tm_mon;        // 0-11
    int d = tm->tm_mday;       // 1-31

    // Years since 1970
    long days = (y - 1970) * 365L;
    // Add leap days for years before this one
    // Leap year if divisible by 4, not by 100, or by 400
    for (int i = 1970; i < y; i++) {
        if ((i % 4 == 0 && i % 100 != 0) || i % 400 == 0) days++;
    }
    // Add days for months in this year
    days += mdays[m];
    // Add leap day if after Feb in a leap year
    if (m > 1 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)) days++;
    days += d - 1;

    return (time_t)(days * 86400L + tm->tm_hour * 3600 + tm->tm_min * 60 + tm->tm_sec);
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
    uint8_t   provider;              // Legacy enum (PROVIDER_CLAUDE / PROVIDER_OPENAI)
    char      provider_label[16];    // Dynamic uppercase display label (e.g. "CLAUDE", "CODEX")
                                     // Set from the Mac envelope's `provider` field (v2.9.0+).
                                     // Fallback: "CLAUDE" when absent (old companion app).
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
