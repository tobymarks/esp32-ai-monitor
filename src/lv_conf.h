/**
 * LVGL v9 Configuration
 * ESP32-2432S028R (CYD 2.8") - AI Usage Monitor
 *
 * Minimal config: only needed widgets enabled to save Flash.
 */

#ifndef LV_CONF_H
#define LV_CONF_H

#include <stdint.h>

// ============================================================
// Color settings
// ============================================================
#define LV_COLOR_DEPTH 16

// ============================================================
// Memory
// ============================================================
#define LV_MEM_CUSTOM 0
#define LV_MEM_SIZE (48 * 1024)  // 48 KB for LVGL internal heap

// ============================================================
// Display refresh
// ============================================================
#define LV_DEF_REFR_PERIOD 33  // ~30 fps

// ============================================================
// Input device
// ============================================================
#define LV_INDEV_DEF_READ_PERIOD 50  // ms between touch reads

// ============================================================
// Drawing
// ============================================================
#define LV_DRAW_BUF_STRIDE_ALIGN 1
#define LV_DRAW_BUF_ALIGN 4

// ============================================================
// Logging (disable in production for performance)
// ============================================================
#define LV_USE_LOG 0

// ============================================================
// Asserts (disable in production)
// ============================================================
#define LV_USE_ASSERT_NULL          1
#define LV_USE_ASSERT_MALLOC        1
#define LV_USE_ASSERT_STYLE         0
#define LV_USE_ASSERT_MEM_INTEGRITY 0
#define LV_USE_ASSERT_OBJ           0

// ============================================================
// Fonts - Montserrat built-in
// ============================================================
#define LV_FONT_MONTSERRAT_8   0
#define LV_FONT_MONTSERRAT_10  0
#define LV_FONT_MONTSERRAT_12  0
#define LV_FONT_MONTSERRAT_14  1
#define LV_FONT_MONTSERRAT_16  1
#define LV_FONT_MONTSERRAT_18  0
#define LV_FONT_MONTSERRAT_20  1
#define LV_FONT_MONTSERRAT_22  0
#define LV_FONT_MONTSERRAT_24  1
#define LV_FONT_MONTSERRAT_26  0
#define LV_FONT_MONTSERRAT_28  0
#define LV_FONT_MONTSERRAT_30  0
#define LV_FONT_MONTSERRAT_32  0
#define LV_FONT_MONTSERRAT_34  0
#define LV_FONT_MONTSERRAT_36  1
#define LV_FONT_MONTSERRAT_38  0
#define LV_FONT_MONTSERRAT_40  0
#define LV_FONT_MONTSERRAT_42  0
#define LV_FONT_MONTSERRAT_44  0
#define LV_FONT_MONTSERRAT_46  0
#define LV_FONT_MONTSERRAT_48  1

#define LV_FONT_DEFAULT &lv_font_montserrat_14

// ============================================================
// Widgets - enable only what we need
// ============================================================

// Core widgets (always needed)
#define LV_USE_LABEL    1
#define LV_USE_BTN      1
#define LV_USE_IMAGE    1
#define LV_USE_LINE     1
#define LV_USE_OBJ      1

// Widgets for usage dashboard
#define LV_USE_ARC      1
#define LV_USE_BAR      1
#define LV_USE_CHART    1
#define LV_USE_TABLE    1
#define LV_USE_TEXTAREA 0

// Disabled widgets to save Flash
#define LV_USE_ANIMIMAGE    0
#define LV_USE_CALENDAR     0
#define LV_USE_CANVAS       1
#define LV_USE_CHECKBOX     0
#define LV_USE_DROPDOWN     0
#define LV_USE_IMAGEBUTTON  0
#define LV_USE_KEYBOARD     0
#define LV_USE_LED          0
#define LV_USE_LIST         0
#define LV_USE_MENU         0
#define LV_USE_MSGBOX       0
#define LV_USE_ROLLER       0
#define LV_USE_SCALE        0
#define LV_USE_SLIDER       0
#define LV_USE_SPAN         0
#define LV_USE_SPINBOX      0
#define LV_USE_SPINNER      0
#define LV_USE_SWITCH       0
#define LV_USE_TABVIEW      0
#define LV_USE_TILEVIEW     0
#define LV_USE_WIN          0

// ============================================================
// Themes
// ============================================================
#define LV_USE_THEME_DEFAULT 1

// ============================================================
// Layouts
// ============================================================
#define LV_USE_FLEX 1
#define LV_USE_GRID 1

// ============================================================
// Others
// ============================================================
#define LV_USE_FS_STDIO 0
#define LV_USE_PNG      0
#define LV_USE_BMP      0
#define LV_USE_GIF      0

// Tick — LVGL v9 removed LV_TICK_CUSTOM macros.
// We must call lv_tick_set_cb() in setup() instead.
// (Leaving old macros here commented out for reference)
// #define LV_TICK_CUSTOM     1
// #define LV_TICK_CUSTOM_INCLUDE "Arduino.h"
// #define LV_TICK_CUSTOM_SYS_TIME_EXPR (millis())

#endif // LV_CONF_H
