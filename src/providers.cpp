#include "providers.h"

#include <string.h>

// ============================================================
// Central provider table
// ------------------------------------------------------------
// One row per provider. To add a provider:
//   1. Add a PROVIDER_* id in config.h.
//   2. Add a COLOR_* brand color in config.h (optional; reuse ok).
//   3. Append one entry below.
// No other file needs to change.
// ============================================================
static const ProviderInfo PROVIDERS[] = {
    {
        /* id          */ PROVIDER_CLAUDE,
        /* wire_keys   */ { "claude", nullptr },
        /* label       */ "CLAUDE",
        /* row_titles  */ { "Session", "Weekly", "Tertiary" },
        /* overflow    */ "Window",
        /* bar_color   */ COLOR_ANTHROPIC,
    },
    {
        /* id          */ PROVIDER_OPENAI,
        /* wire_keys   */ { "codex", nullptr },
        /* label       */ "CODEX",
        /* row_titles  */ { "Session", "Weekly", "Tertiary" },
        /* overflow    */ "Window",
        /* bar_color   */ COLOR_OPENAI,
    },
    {
        /* id          */ PROVIDER_ANTIGRAVITY,
        /* wire_keys   */ { "antigravity", nullptr },
        /* label       */ "ANTIGRAVITY",
        /* row_titles  */ { "Claude", "Gemini Pro", "Gemini Flash" },
        /* overflow    */ "Model",
        /* bar_color   */ COLOR_ANTIGRAVITY,
    },
};

static const size_t PROVIDER_COUNT = sizeof(PROVIDERS) / sizeof(PROVIDERS[0]);

// Index 0 is the canonical default (Claude). Kept explicit so the
// fallback path is obvious and never depends on enum value ordering.
static const ProviderInfo &default_provider() {
    return PROVIDERS[0];
}

const ProviderInfo* provider_info_for_id(uint8_t provider) {
    for (size_t i = 0; i < PROVIDER_COUNT; i++) {
        if (PROVIDERS[i].id == provider) {
            return &PROVIDERS[i];
        }
    }
    return &default_provider();
}

uint8_t provider_from_string(const char *raw) {
    if (raw == nullptr || raw[0] == '\0') return default_provider().id;

    char normalized[16];
    size_t i = 0;
    while (raw[i] != '\0' && i < sizeof(normalized) - 1) {
        char c = raw[i];
        if (c >= 'A' && c <= 'Z') c = c - 'A' + 'a';
        normalized[i++] = c;
    }
    normalized[i] = '\0';

    for (size_t p = 0; p < PROVIDER_COUNT; p++) {
        for (size_t k = 0; k < PROVIDER_WIRE_ALIAS_MAX; k++) {
            const char *key = PROVIDERS[p].wire_keys[k];
            if (key != nullptr && strcmp(normalized, key) == 0) {
                return PROVIDERS[p].id;
            }
        }
    }
    return default_provider().id;
}

const char* provider_label_from_id(uint8_t provider) {
    return provider_info_for_id(provider)->label;
}

const char* default_row_title_for_provider(uint8_t provider, uint8_t index) {
    const ProviderInfo *info = provider_info_for_id(provider);
    if (index < 3) return info->row_titles[index];
    return info->row_title_overflow;
}
