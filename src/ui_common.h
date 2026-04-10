#ifndef UI_COMMON_H
#define UI_COMMON_H

#include <lvgl.h>
#include "api_common.h"

// ============================================================
// Color definitions (LVGL-ready)
// ============================================================
#define UI_COLOR_BG            lv_color_hex(0x1A1A2E)
#define UI_COLOR_PANEL         lv_color_hex(0x16213E)
#define UI_COLOR_HEADER_BG     lv_color_hex(0x16213E)
#define UI_COLOR_ACCENT        lv_color_hex(0xE94560)
#define UI_COLOR_TEXT          lv_color_hex(0xFFFFFF)
#define UI_COLOR_TEXT_SEC      lv_color_hex(0x9090B0)
#define UI_COLOR_TEXT_DIM      lv_color_hex(0x666666)
#define UI_COLOR_ANTHROPIC     lv_color_hex(0xE94560)
#define UI_COLOR_OPENAI        lv_color_hex(0x0ACF83)
#define UI_COLOR_BAR_BG        lv_color_hex(0x2A2A4A)
#define UI_COLOR_BAR_GREEN     lv_color_hex(0x27AE60)
#define UI_COLOR_BAR_YELLOW    lv_color_hex(0xF1C40F)
#define UI_COLOR_BAR_ORANGE    lv_color_hex(0xE67E22)
#define UI_COLOR_BAR_RED       lv_color_hex(0xE74C3C)
#define UI_COLOR_SUCCESS       lv_color_hex(0x27AE60)
#define UI_COLOR_ERROR         lv_color_hex(0xE74C3C)
#define UI_COLOR_FETCHING      lv_color_hex(0xF1C40F)
#define UI_COLOR_DIVIDER       lv_color_hex(0x2A2A4A)

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

#endif // UI_COMMON_H
