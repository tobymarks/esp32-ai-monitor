#ifndef UI_COMMON_H
#define UI_COMMON_H

#include <lvgl.h>
#include "api_common.h"

// ============================================================
// Color definitions — runtime variables for theme switching
// ============================================================
extern lv_color_t UI_COLOR_BG;
extern lv_color_t UI_COLOR_PANEL;
extern lv_color_t UI_COLOR_HEADER_BG;
extern lv_color_t UI_COLOR_ACCENT;
extern lv_color_t UI_COLOR_TEXT;
extern lv_color_t UI_COLOR_TEXT_SEC;
extern lv_color_t UI_COLOR_TEXT_DIM;
extern lv_color_t UI_COLOR_ANTHROPIC;
extern lv_color_t UI_COLOR_OPENAI;
extern lv_color_t UI_COLOR_BAR_BG;
extern lv_color_t UI_COLOR_BAR_GREEN;
extern lv_color_t UI_COLOR_BAR_YELLOW;
extern lv_color_t UI_COLOR_BAR_ORANGE;
extern lv_color_t UI_COLOR_BAR_RED;
extern lv_color_t UI_COLOR_SUCCESS;
extern lv_color_t UI_COLOR_ERROR;
extern lv_color_t UI_COLOR_FETCHING;
extern lv_color_t UI_COLOR_DIVIDER;

// ============================================================
// Formatting helpers (static buffers — NOT thread-safe)
// ============================================================

// Format token count: "847", "847K", "1.2M"
void format_tokens(uint32_t tokens, char *buf, size_t len);

// Format cost: "$0.00", "$1.23", "$12.34", "$123"
void format_cost(float cost, char *buf, size_t len);

// Format "time ago" from millis timestamp: "just now", "2m ago", "15m ago"
void format_time_ago(unsigned long last_fetch_ms, char *buf, size_t len);

// Format utilization float to percentage string: 0.73 -> "73%"
void format_percentage(float utilization, char *buf, size_t len);

// Format countdown from reset epoch to "2h 14m" or "4d 12h"
void format_countdown(time_t reset_epoch, char *buf, size_t len);

// Format countdown long: "2 Stunden 14 Minuten" / "2 Hours 14 Minutes"
void format_countdown_long(time_t reset_epoch, char *buf, size_t len);

// Format reset as target date: "Freitag, 18:00 Uhr" / "Friday, 6:00 PM"
void format_reset_date(time_t reset_epoch, char *buf, size_t len);

// Return bar color based on utilization level
lv_color_t ui_bar_color(float utilization);

// ============================================================
// UI component builders
// ============================================================

// Create a styled panel (rounded, dark background)
lv_obj_t* ui_create_panel(lv_obj_t *parent);

// Create a progress bar with provider color
lv_obj_t* ui_create_bar(lv_obj_t *parent, lv_color_t color);

// Create a horizontal divider line at given y position
lv_obj_t* ui_create_divider(lv_obj_t *parent, int16_t y_pos);

// ============================================================
// Screen navigation with animation
// ============================================================

// Navigate to a screen (slide left = forward, slide right = back)
void ui_screen_load_forward(lv_obj_t *scr);
void ui_screen_load_back(lv_obj_t *scr);
void ui_screen_load_fade(lv_obj_t *scr);

// ============================================================
// Style initialization (call once at startup)
// ============================================================
void ui_styles_init();

// Reset styles so they are re-initialized with current theme colors
void ui_styles_reset();

// ============================================================
// Theme switching — applies dark or light color palette
// ============================================================
void ui_apply_theme(uint8_t theme);

#endif // UI_COMMON_H
