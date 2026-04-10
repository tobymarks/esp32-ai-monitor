/**
 * UI Common - Shared styles, formatters, and UI component builders
 */

#include "ui_common.h"
#include "config.h"
#include <Arduino.h>
#include <stdio.h>
#include <time.h>

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

    // Panel style: dark card with rounded corners
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
        snprintf(buf, len, "never");
        return;
    }

    unsigned long now = millis();
    unsigned long elapsed_ms = now - last_fetch_ms;
    unsigned long elapsed_sec = elapsed_ms / 1000;

    if (elapsed_sec < 30) {
        snprintf(buf, len, "just now");
    } else if (elapsed_sec < 60) {
        snprintf(buf, len, "%lus ago", elapsed_sec);
    } else if (elapsed_sec < 3600) {
        unsigned long mins = elapsed_sec / 60;
        snprintf(buf, len, "%lum ago", mins);
    } else if (elapsed_sec < 86400) {
        unsigned long hours = elapsed_sec / 3600;
        snprintf(buf, len, "%luh ago", hours);
    } else {
        unsigned long days = elapsed_sec / 86400;
        snprintf(buf, len, "%lud ago", days);
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
