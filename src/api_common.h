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
// Shared data structures for Anthropic + OpenAI API clients
// ============================================================

// Per-model token breakdown
struct ModelUsage {
    char model[48];           // e.g. "claude-sonnet-4-6", "gpt-4o"
    uint32_t input_tokens;
    uint32_t output_tokens;
    uint32_t cached_tokens;   // cache_read (Anthropic) / input_cached (OpenAI)
    uint32_t requests;        // Number of requests (OpenAI only, 0 for Anthropic)
};

// Aggregated usage data for one provider
struct UsageData {
    // Today
    uint32_t today_input_tokens;
    uint32_t today_output_tokens;
    uint32_t today_cached_tokens;
    uint32_t today_requests;

    // This month
    uint32_t month_input_tokens;
    uint32_t month_output_tokens;
    uint32_t month_cached_tokens;
    uint32_t month_requests;

    // Per-model breakdown (max 8 models)
    ModelUsage models[8];
    uint8_t model_count;

    // Costs (USD)
    float today_cost;
    float month_cost;

    // Meta
    bool valid;               // true if data was fetched successfully
    unsigned long last_fetch; // millis() of last successful fetch
    char error[64];           // Error message if !valid
};

// Overall monitor state
struct MonitorState {
    UsageData anthropic;
    UsageData openai;
    float total_today_cost;
    float total_month_cost;
    bool is_fetching;         // true while an API call is in progress
    char status[48];          // "Idle", "Fetching Anthropic...", etc.
};

// ============================================================
// Helper: zero-init a UsageData struct
// ============================================================
inline void usage_data_clear(UsageData &d) {
    d.today_input_tokens  = 0;
    d.today_output_tokens = 0;
    d.today_cached_tokens = 0;
    d.today_requests      = 0;
    d.month_input_tokens  = 0;
    d.month_output_tokens = 0;
    d.month_cached_tokens = 0;
    d.month_requests      = 0;
    d.model_count         = 0;
    d.today_cost          = 0.0f;
    d.month_cost          = 0.0f;
    d.valid               = false;
    d.last_fetch          = 0;
    d.error[0]            = '\0';
    for (uint8_t i = 0; i < 8; i++) {
        d.models[i].model[0]      = '\0';
        d.models[i].input_tokens  = 0;
        d.models[i].output_tokens = 0;
        d.models[i].cached_tokens = 0;
        d.models[i].requests      = 0;
    }
}

// ============================================================
// Helper: find or add a model slot in UsageData
// Returns pointer to ModelUsage, or nullptr if full
// ============================================================
inline ModelUsage* usage_find_or_add_model(UsageData &d, const char *model_name) {
    // Search existing
    for (uint8_t i = 0; i < d.model_count; i++) {
        if (strncmp(d.models[i].model, model_name, sizeof(d.models[i].model)) == 0) {
            return &d.models[i];
        }
    }
    // Add new if space
    if (d.model_count < 8) {
        ModelUsage *m = &d.models[d.model_count];
        strlcpy(m->model, model_name, sizeof(m->model));
        m->input_tokens  = 0;
        m->output_tokens = 0;
        m->cached_tokens = 0;
        m->requests      = 0;
        d.model_count++;
        return m;
    }
    return nullptr;  // Model list full
}

#endif // API_COMMON_H
