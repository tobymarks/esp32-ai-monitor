/**
 * UI Common - Shared styles, formatters, and UI component builders
 */

#include "ui_common.h"
#include "config.h"
#include "localization.h"
#include <Arduino.h>
#include <stdio.h>
#include <time.h>

// ============================================================
// Runtime color variables (default: dark theme)
// ============================================================
lv_color_t UI_COLOR_BG         = lv_color_hex(0x2B2A27);
lv_color_t UI_COLOR_PANEL      = lv_color_hex(0x353432);
lv_color_t UI_COLOR_HEADER_BG  = lv_color_hex(0x1F1E1B);
lv_color_t UI_COLOR_ACCENT     = lv_color_hex(0xD97757);
lv_color_t UI_COLOR_TEXT       = lv_color_hex(0xF4F3EE);
lv_color_t UI_COLOR_TEXT_SEC   = lv_color_hex(0x8A8880);
lv_color_t UI_COLOR_TEXT_DIM   = lv_color_hex(0x5A5955);
lv_color_t UI_COLOR_ANTHROPIC  = lv_color_hex(0xD97757);
lv_color_t UI_COLOR_OPENAI     = lv_color_hex(0x0ACF83);
lv_color_t UI_COLOR_BAR_BG     = lv_color_hex(0x3A3937);
lv_color_t UI_COLOR_BAR_GREEN  = lv_color_hex(0x27AE60);
lv_color_t UI_COLOR_BAR_YELLOW = lv_color_hex(0xF1C40F);
lv_color_t UI_COLOR_BAR_ORANGE = lv_color_hex(0xE67E22);
lv_color_t UI_COLOR_BAR_RED    = lv_color_hex(0xE74C3C);
lv_color_t UI_COLOR_SUCCESS    = lv_color_hex(0x27AE60);
lv_color_t UI_COLOR_ERROR      = lv_color_hex(0xE74C3C);
lv_color_t UI_COLOR_FETCHING   = lv_color_hex(0xF1C40F);
lv_color_t UI_COLOR_DIVIDER    = lv_color_hex(0x3A3937);

// ============================================================
// Theme application — sets all color variables
// ============================================================
void ui_apply_theme(uint8_t theme) {
    if (theme == THEME_LIGHT) {
        // Light theme — tuned for contrast & readability on CYD 2.8"
        // WCAG AA: Text >=4.5:1, UI-Komponenten/Bars >=3:1
        UI_COLOR_BG         = lv_color_hex(0xFAF9F5);  // warmes Off-White
        UI_COLOR_PANEL      = lv_color_hex(0xEFEDE4);  // deutlicher abgesetzt ggue. BG
        UI_COLOR_HEADER_BG  = lv_color_hex(0xE4E1D4);  // klar sichtbare Header-Abgrenzung
        UI_COLOR_ACCENT     = lv_color_hex(0xB04E2E);  // dunkleres Anthropic-Orange, 5.1:1 auf BG
        UI_COLOR_TEXT       = lv_color_hex(0x141413);  // 19:1 auf BG (AAA)
        UI_COLOR_TEXT_SEC   = lv_color_hex(0x5A5954);  // 7.1:1 auf BG (AAA)
        UI_COLOR_TEXT_DIM   = lv_color_hex(0x8A8880);  // 3.5:1 (fuer dekorative Labels ok)
        UI_COLOR_ANTHROPIC  = lv_color_hex(0xB04E2E);  // synchron mit ACCENT
        UI_COLOR_OPENAI     = lv_color_hex(0x04875F);  // 4.6:1 auf BG
        UI_COLOR_BAR_BG     = lv_color_hex(0xD8D5C8);  // deutlicher Bar-Track
        UI_COLOR_BAR_GREEN  = lv_color_hex(0x1B7A44);  // 4.9:1 auf BAR_BG
        UI_COLOR_BAR_YELLOW = lv_color_hex(0xB8860B);  // DarkGoldenrod, 3.4:1 auf BAR_BG
        UI_COLOR_BAR_ORANGE = lv_color_hex(0xB85A16);  // 4.2:1 auf BAR_BG
        UI_COLOR_BAR_RED    = lv_color_hex(0xB23127);  // 5.4:1 auf BAR_BG
        UI_COLOR_SUCCESS    = lv_color_hex(0x1B7A44);
        UI_COLOR_ERROR      = lv_color_hex(0xB23127);
        UI_COLOR_FETCHING   = lv_color_hex(0xB8860B);
        UI_COLOR_DIVIDER    = lv_color_hex(0xC9C6B8);  // sichtbarer Divider
    } else {
        // Dark theme (default)
        UI_COLOR_BG         = lv_color_hex(0x2B2A27);
        UI_COLOR_PANEL      = lv_color_hex(0x353432);
        UI_COLOR_HEADER_BG  = lv_color_hex(0x1F1E1B);
        UI_COLOR_ACCENT     = lv_color_hex(0xD97757);
        UI_COLOR_TEXT       = lv_color_hex(0xF4F3EE);
        UI_COLOR_TEXT_SEC   = lv_color_hex(0x8A8880);
        UI_COLOR_TEXT_DIM   = lv_color_hex(0x5A5955);
        UI_COLOR_ANTHROPIC  = lv_color_hex(0xD97757);
        UI_COLOR_OPENAI     = lv_color_hex(0x0ACF83);
        UI_COLOR_BAR_BG     = lv_color_hex(0x3A3937);
        UI_COLOR_BAR_GREEN  = lv_color_hex(0x27AE60);
        UI_COLOR_BAR_YELLOW = lv_color_hex(0xF1C40F);
        UI_COLOR_BAR_ORANGE = lv_color_hex(0xE67E22);
        UI_COLOR_BAR_RED    = lv_color_hex(0xE74C3C);
        UI_COLOR_SUCCESS    = lv_color_hex(0x27AE60);
        UI_COLOR_ERROR      = lv_color_hex(0xE74C3C);
        UI_COLOR_FETCHING   = lv_color_hex(0xF1C40F);
        UI_COLOR_DIVIDER    = lv_color_hex(0x3A3937);
    }
    Serial.printf("[UI] Theme applied: %s\n", theme == THEME_LIGHT ? "light" : "dark");
}

// ============================================================
// Static styles (must be persistent, not stack-allocated)
// ============================================================
static lv_style_t style_panel;
static lv_style_t style_bar_bg;
static bool styles_initialized = false;

// ============================================================
// Style initialization
// ============================================================
void ui_styles_init() {
    if (styles_initialized) return;

    // Panel style: card with rounded corners
    lv_style_init(&style_panel);
    lv_style_set_bg_color(&style_panel, UI_COLOR_PANEL);
    lv_style_set_bg_opa(&style_panel, LV_OPA_COVER);
    lv_style_set_radius(&style_panel, 8);
    lv_style_set_border_width(&style_panel, 0);
    lv_style_set_pad_all(&style_panel, 8);
    lv_style_set_pad_gap(&style_panel, 4);

    // Bar background style
    lv_style_init(&style_bar_bg);
    lv_style_set_bg_color(&style_bar_bg, UI_COLOR_PANEL);
    lv_style_set_bg_opa(&style_bar_bg, LV_OPA_COVER);
    lv_style_set_radius(&style_bar_bg, 6);

    styles_initialized = true;
}

// ============================================================
// Reset styles (for theme change — forces re-init with new colors)
// ============================================================
void ui_styles_reset() {
    if (styles_initialized) {
        lv_style_reset(&style_panel);
        lv_style_reset(&style_bar_bg);
        styles_initialized = false;
    }
}

// ============================================================
// Token formatting: "847", "847K", "1.2M"
// ============================================================
void format_tokens(uint32_t tokens, char *buf, size_t len) {
    if (tokens < 1000) {
        snprintf(buf, len, "%lu", (unsigned long)tokens);
    } else if (tokens < 1000000) {
        snprintf(buf, len, "%luK", (unsigned long)(tokens / 1000));
    } else {
        float m = tokens / 1000000.0f;
        if (m < 10.0f) {
            snprintf(buf, len, "%.1fM", m);
        } else {
            snprintf(buf, len, "%.0fM", m);
        }
    }
}

// ============================================================
// Cost formatting: "$0.00", "$1.23", "$12.34", "$123"
// ============================================================
void format_cost(float cost, char *buf, size_t len) {
    if (cost < 0.01f) {
        snprintf(buf, len, "$0.00");
    } else if (cost < 100.0f) {
        snprintf(buf, len, "$%.2f", cost);
    } else {
        snprintf(buf, len, "$%.0f", cost);
    }
}

// ============================================================
// Time-ago formatting from millis() timestamp
// ============================================================
void format_time_ago(unsigned long last_fetch_ms, char *buf, size_t len) {
    if (last_fetch_ms == 0) {
        snprintf(buf, len, "%s", L(STR_NEVER));
        return;
    }

    unsigned long now = millis();
    unsigned long elapsed_ms = now - last_fetch_ms;
    unsigned long elapsed_sec = elapsed_ms / 1000;

    if (elapsed_sec < 30) {
        snprintf(buf, len, "%s", L(STR_JUST_NOW));
    } else if (elapsed_sec < 60) {
        if (g_language == LANG_DE) {
            snprintf(buf, len, "vor %lus", elapsed_sec);
        } else {
            snprintf(buf, len, "%lus ago", elapsed_sec);
        }
    } else if (elapsed_sec < 3600) {
        unsigned long mins = elapsed_sec / 60;
        if (g_language == LANG_DE) {
            snprintf(buf, len, "vor %lum", mins);
        } else {
            snprintf(buf, len, "%lum ago", mins);
        }
    } else if (elapsed_sec < 86400) {
        unsigned long hours = elapsed_sec / 3600;
        if (g_language == LANG_DE) {
            snprintf(buf, len, "vor %luh", hours);
        } else {
            snprintf(buf, len, "%luh ago", hours);
        }
    } else {
        unsigned long days = elapsed_sec / 86400;
        if (g_language == LANG_DE) {
            snprintf(buf, len, "vor %lud", days);
        } else {
            snprintf(buf, len, "%lud ago", days);
        }
    }
}

// ============================================================
// Percentage formatting: 0.73 -> "73%"
// ============================================================
void format_percentage(float utilization, char *buf, size_t len) {
    int pct = (int)(utilization * 100.0f + 0.5f);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    snprintf(buf, len, "%d%%", pct);
}

// ============================================================
// Countdown formatting from reset epoch: "2h 14m", "4d 12h"
// ============================================================
void format_countdown(time_t reset_epoch, char *buf, size_t len) {
    if (reset_epoch <= 0) {
        snprintf(buf, len, "--");
        return;
    }
    time_t now = time(nullptr);
    long diff = (long)(reset_epoch - now);
    if (diff <= 0) {
        snprintf(buf, len, "soon");
        return;
    }
    long days  = diff / 86400;
    long hours = (diff % 86400) / 3600;
    long mins  = (diff % 3600) / 60;

    if (days > 0) {
        snprintf(buf, len, "%ldd %ldh", days, hours);
    } else if (hours > 0) {
        snprintf(buf, len, "%ldh %ldm", hours, mins);
    } else {
        snprintf(buf, len, "%ldm", mins > 0 ? mins : 1);
    }
}

// ============================================================
// Countdown long: "2 Stunden 14 Minuten" / "2 Hours 14 Minutes"
// ============================================================
void format_countdown_long(time_t reset_epoch, char *buf, size_t len) {
    if (reset_epoch <= 0) {
        snprintf(buf, len, "--");
        return;
    }
    time_t now = time(nullptr);
    long diff = (long)(reset_epoch - now);
    if (diff <= 0) {
        snprintf(buf, len, g_language == LANG_DE ? "bald" : "soon");
        return;
    }
    long hours = diff / 3600;
    long mins  = (diff % 3600) / 60;

    if (g_language == LANG_DE) {
        const char *h_unit = (hours == 1) ? "Stunde" : "Stunden";
        const char *m_unit = (mins == 1) ? "Minute" : "Minuten";
        if (hours > 0 && mins > 0) {
            snprintf(buf, len, "%ld %s %ld %s", hours, h_unit, mins, m_unit);
        } else if (hours > 0) {
            snprintf(buf, len, "%ld %s", hours, h_unit);
        } else {
            snprintf(buf, len, "%ld %s", mins, m_unit);
        }
    } else {
        const char *h_unit = (hours == 1) ? "Hour" : "Hours";
        const char *m_unit = (mins == 1) ? "Minute" : "Minutes";
        if (hours > 0 && mins > 0) {
            snprintf(buf, len, "%ld %s %ld %s", hours, h_unit, mins, m_unit);
        } else if (hours > 0) {
            snprintf(buf, len, "%ld %s", hours, h_unit);
        } else {
            snprintf(buf, len, "%ld %s", mins, m_unit);
        }
    }
}

// ============================================================
// Reset date: "Freitag, 18:00 Uhr" / "Friday, 6:00 PM"
// ============================================================
void format_reset_date(time_t reset_epoch, char *buf, size_t len) {
    if (reset_epoch <= 0) {
        snprintf(buf, len, "--");
        return;
    }

    struct tm reset_tm;
    localtime_r(&reset_epoch, &reset_tm);

    if (g_language == LANG_DE) {
        static const char* wochentage[] = {
            "Sonntag", "Montag", "Dienstag", "Mittwoch",
            "Donnerstag", "Freitag", "Samstag"
        };
        snprintf(buf, len, "%s, %02d:%02d Uhr",
                 wochentage[reset_tm.tm_wday],
                 reset_tm.tm_hour, reset_tm.tm_min);
    } else {
        static const char* weekdays[] = {
            "Sunday", "Monday", "Tuesday", "Wednesday",
            "Thursday", "Friday", "Saturday"
        };
        int hour12 = reset_tm.tm_hour % 12;
        if (hour12 == 0) hour12 = 12;
        const char *ampm = (reset_tm.tm_hour < 12) ? "AM" : "PM";
        snprintf(buf, len, "%s, %d:%02d %s",
                 weekdays[reset_tm.tm_wday],
                 hour12, reset_tm.tm_min, ampm);
    }
}

// ============================================================
// Bar color based on utilization level
// ============================================================
lv_color_t ui_bar_color(float utilization) {
    if (utilization >= 0.95f) return UI_COLOR_BAR_RED;
    if (utilization >= 0.80f) return UI_COLOR_BAR_ORANGE;
    if (utilization >= 0.50f) return UI_COLOR_BAR_YELLOW;
    return UI_COLOR_BAR_GREEN;
}

// ============================================================
// Create styled panel
// ============================================================
lv_obj_t* ui_create_panel(lv_obj_t *parent) {
    lv_obj_t *panel = lv_obj_create(parent);
    lv_obj_add_style(panel, &style_panel, LV_PART_MAIN);
    lv_obj_set_scrollbar_mode(panel, LV_SCROLLBAR_MODE_OFF);
    return panel;
}

// ============================================================
// Create progress bar with custom indicator color
// ============================================================
lv_obj_t* ui_create_bar(lv_obj_t *parent, lv_color_t color) {
    lv_obj_t *bar = lv_bar_create(parent);
    lv_obj_set_height(bar, 12);
    lv_bar_set_range(bar, 0, 100);
    lv_bar_set_value(bar, 0, LV_ANIM_OFF);

    // Background (track)
    lv_obj_set_style_bg_color(bar, UI_COLOR_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(bar, 6, LV_PART_MAIN);

    // Indicator (fill)
    lv_obj_set_style_bg_color(bar, color, LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, LV_PART_INDICATOR);
    lv_obj_set_style_radius(bar, 6, LV_PART_INDICATOR);

    return bar;
}

// ============================================================
// Create horizontal divider line
// ============================================================
lv_obj_t* ui_create_divider(lv_obj_t *parent, int16_t y_pos) {
    // IMPORTANT: lv_line_set_points() stores a pointer to the points array —
    // it must remain valid for the lifetime of the line object.
    // Using a single static array caused all dividers to share state and
    // corrupted each other on every call.  Use a small heap allocation instead
    // so every divider owns its own independent point data.
    lv_point_precise_t *pts = (lv_point_precise_t *)lv_malloc(2 * sizeof(lv_point_precise_t));
    if (pts == nullptr) {
        Serial.println("[UI] ui_create_divider: lv_malloc failed");
        return nullptr;
    }
    pts[0] = {0, 0};
    pts[1] = {(lv_value_precise_t)SCREEN_WIDTH, 0};

    lv_obj_t *line = lv_line_create(parent);
    lv_line_set_points(line, pts, 2);
    lv_obj_set_style_line_color(line, UI_COLOR_DIVIDER, LV_PART_MAIN);
    lv_obj_set_style_line_width(line, 1, LV_PART_MAIN);
    lv_obj_set_pos(line, 0, y_pos);
    return line;
}

// ============================================================
// Screen navigation helpers
// ============================================================
void ui_screen_load_forward(lv_obj_t *scr) {
    lv_screen_load_anim(scr, LV_SCR_LOAD_ANIM_MOVE_LEFT, 250, 0, false);
}

void ui_screen_load_back(lv_obj_t *scr) {
    lv_screen_load_anim(scr, LV_SCR_LOAD_ANIM_MOVE_RIGHT, 250, 0, false);
}

void ui_screen_load_fade(lv_obj_t *scr) {
    lv_screen_load_anim(scr, LV_SCR_LOAD_ANIM_FADE_IN, 300, 0, false);
}
