/**
 * UI Settings - System status and config screen
 *
 * Shows system info: Source (USB Serial), Orientation, Heap, Uptime, Version.
 * No WiFi, no QR code, no mDNS.
 *
 * Accessed via long-press on dashboard.
 */

#include "ui_settings.h"
#include "ui_common.h"
#include "ui_dashboard.h"
#include "config.h"
#include "config_store.h"
#include "localization.h"
#include "serial_receiver.h"

#include <lvgl.h>
#include <Arduino.h>
#include <stdio.h>
#include <time.h>

// External config
extern AppConfig g_config;

// ============================================================
// Back button handler
// ============================================================
static void on_back_tap(lv_event_t *e) {
    (void)e;
    ui_dashboard_load_back();
    lv_obj_t *old_scr = (lv_obj_t *)lv_event_get_user_data(e);
    if (old_scr != nullptr) {
        lv_obj_delete_async(old_scr);
    }
}

// ============================================================
// Helper: format uptime from millis()
// ============================================================
static void format_uptime(char *buf, size_t len) {
    unsigned long sec = millis() / 1000;
    unsigned long days = sec / 86400;
    sec %= 86400;
    unsigned long hours = sec / 3600;
    sec %= 3600;
    unsigned long mins = sec / 60;

    if (days > 0) {
        snprintf(buf, len, "%lud %luh %lum", days, hours, mins);
    } else if (hours > 0) {
        snprintf(buf, len, "%luh %lum", hours, mins);
    } else {
        snprintf(buf, len, "%lum", mins);
    }
}

// ============================================================
// Helper: create an info row (label: value)
// ============================================================
static lv_obj_t* create_info_row(lv_obj_t *parent, const char *label, const char *value, int16_t y) {
    lv_obj_t *lbl = lv_label_create(parent);
    lv_label_set_text(lbl, label);
    lv_obj_set_style_text_color(lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl, 12, y);

    lv_obj_t *val = lv_label_create(parent);
    lv_label_set_text(val, value);
    lv_obj_set_style_text_color(val, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(val, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(val, 120, y);

    return val;
}

// ============================================================
// Create settings screen
// ============================================================
void ui_settings_create() {
    ui_styles_init();

    int16_t sw = SCREEN_WIDTH;
    int16_t sh = SCREEN_HEIGHT;

    lv_obj_t *scr = lv_obj_create(nullptr);
    lv_obj_set_style_bg_color(scr, UI_COLOR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    // ---- Header ----
    lv_obj_t *header = lv_obj_create(scr);
    lv_obj_set_size(header, sw, 32);
    lv_obj_set_pos(header, 0, 0);
    lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(header, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(header, 0, LV_PART_MAIN);
    lv_obj_clear_flag(header, LV_OBJ_FLAG_SCROLLABLE);

    // Back button
    lv_obj_t *btn_back = lv_label_create(header);
    lv_label_set_text(btn_back, LV_SYMBOL_LEFT);
    lv_obj_set_style_text_color(btn_back, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(btn_back, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_set_pos(btn_back, 8, 6);
    lv_obj_add_flag(btn_back, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_ext_click_area(btn_back, 15);
    lv_obj_add_event_cb(btn_back, on_back_tap, LV_EVENT_CLICKED, scr);

    lv_obj_t *lbl_title = lv_label_create(header);
    lv_label_set_text(lbl_title, L(STR_SETTINGS));
    lv_obj_set_style_text_color(lbl_title, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_title, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_set_pos(lbl_title, 34, 8);

    // Time — uses getLocalTime() (works after settimeofday)
    lv_obj_t *lbl_time = lv_label_create(header);
    {
        struct tm timeinfo;
        if (getLocalTime(&timeinfo, 0)) {
            char tbuf[6];
            strftime(tbuf, sizeof(tbuf), "%H:%M", &timeinfo);
            lv_label_set_text(lbl_time, tbuf);
        } else {
            lv_label_set_text(lbl_time, "--:--");
        }
    }
    lv_obj_set_style_text_color(lbl_time, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_time, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(lbl_time, LV_ALIGN_TOP_RIGHT, -8, 9);

    // ---- Divider ----
    ui_create_divider(scr, 32);

    // ---- Info rows ----
    int16_t y = 40;

    // Source
    create_info_row(scr, L(STR_SOURCE), L(STR_SOURCE_USB), y);
    y += 18;

    // Last data
    {
        MonitorState ms = serial_get_state();
        char data_buf[32];
        if (ms.usage.valid && ms.usage.last_fetch > 0) {
            unsigned long ago_sec = (millis() - ms.usage.last_fetch) / 1000;
            if (ago_sec < 60) {
                snprintf(data_buf, sizeof(data_buf), "%s", L(STR_JUST_NOW));
            } else {
                if (g_language == LANG_DE) {
                    snprintf(data_buf, sizeof(data_buf), "vor %lum", ago_sec / 60);
                } else {
                    snprintf(data_buf, sizeof(data_buf), "%lum ago", ago_sec / 60);
                }
            }
        } else {
            snprintf(data_buf, sizeof(data_buf), "%s", L(STR_NO_DATA));
        }
        create_info_row(scr, L(STR_LAST_DATA), data_buf, y);
    }
    y += 18;

    // Status
    {
        MonitorState ms = serial_get_state();
        create_info_row(scr, L(STR_STATUS), ms.status, y);
    }
    y += 18;

    // Orientation
    create_info_row(scr, L(STR_ORIENTATION),
                    g_config.orientation == ORIENTATION_LANDSCAPE ? L(STR_LANDSCAPE) : L(STR_PORTRAIT), y);
    y += 18;

    // ---- Divider ----
    ui_create_divider(scr, y + 4);
    y += 12;

    // ---- System info ----
    char heap_buf[48];
    snprintf(heap_buf, sizeof(heap_buf), "%u KB / Min: %u KB",
             ESP.getFreeHeap() / 1024, ESP.getMinFreeHeap() / 1024);
    create_info_row(scr, L(STR_HEAP), heap_buf, y);
    y += 18;

    char uptime_buf[32];
    format_uptime(uptime_buf, sizeof(uptime_buf));
    create_info_row(scr, L(STR_UPTIME), uptime_buf, y);
    y += 18;

    char poll_buf[32];
    snprintf(poll_buf, sizeof(poll_buf), "%us", (unsigned)g_config.poll_interval_sec);
    create_info_row(scr, L(STR_POLL), poll_buf, y);

    // ---- Divider above footer ----
    int16_t footer_div_y = sh - 42;
    ui_create_divider(scr, footer_div_y);

    // ---- Footer: Version ----
    lv_obj_t *lbl_ver = lv_label_create(scr);
    char ver_buf[24];
    snprintf(ver_buf, sizeof(ver_buf), "v%s", APP_VERSION);
    lv_label_set_text(lbl_ver, ver_buf);
    lv_obj_set_style_text_color(lbl_ver, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_ver, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl_ver, 12, sh - 30);

    // ---- Load with slide animation ----
    ui_screen_load_forward(scr);

    Serial.println("[UI] Settings screen created");
}
