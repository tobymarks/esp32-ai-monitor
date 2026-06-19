#ifndef PROVIDERS_H
#define PROVIDERS_H

#include <Arduino.h>

// ============================================================
// Central provider registry
// ------------------------------------------------------------
// Adding a new provider should require ONLY a new entry in the
// PROVIDERS[] table (see providers.cpp). All provider-specific
// behaviour (wire key + aliases, display label, default row
// titles, brand/bar color) is read from this table.
// ============================================================

// Provider id enum values are defined in config.h
// (PROVIDER_CLAUDE / PROVIDER_OPENAI / PROVIDER_ANTIGRAVITY).
#include "config.h"

#define PROVIDER_WIRE_ALIAS_MAX 2   // max number of accepted wire strings per provider

struct ProviderInfo {
    uint8_t     id;                              // PROVIDER_* enum value
    // Accepted lowercase wire keys (e.g. {"codex", "openai"}). The first
    // entry is the canonical key. Unused slots are nullptr.
    const char *wire_keys[PROVIDER_WIRE_ALIAS_MAX];
    const char *label;                           // Uppercase display label, e.g. "CODEX"
    const char *row_titles[3];                   // Default per-row titles (index 0..2)
    const char *row_title_overflow;              // Default title for index >= 3
    uint32_t    bar_color;                       // Brand/bar color (0xRRGGBB, matches COLOR_*)
};

// Look up a provider by id. Returns the matching entry, or the
// default (Claude) entry if the id is unknown. Never returns null.
const ProviderInfo* provider_info_for_id(uint8_t provider);

// Map a raw wire string (case-insensitive) to a provider id.
// Falls back to PROVIDER_CLAUDE for null/empty/unknown input.
uint8_t provider_from_string(const char *raw);

// Convenience accessors backed by the table.
const char* provider_label_from_id(uint8_t provider);
const char* default_row_title_for_provider(uint8_t provider, uint8_t index);

#endif // PROVIDERS_H
