/**
 * UI Settings - System status and config screen
 *
 * Adapts to both orientations:
 *   Portrait  (240x320): QR code below info rows, bigger QR
 *   Landscape (320x240): QR code to the right, compact layout
 *
 * Accessed via long-press on dashboard.
 */

#include "ui_settings.h"
#include "ui_common.h"
#include "ui_dashboard.h"
#include "config.h"
#include "ntp_time.h"
#include "wifi_setup.h"
#include "web_server.h"
#include "qr_display.h"

#include <lvgl.h>
#include <qrcode.h>
#include <Arduino.h>
#include <stdio.h>

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
// Helper: draw inline QR code on the settings screen
// ============================================================
static void draw_settings_qr(lv_obj_t *parent, const String &url, int16_t x, int16_t y, uint16_t target_size = 80) {
    QRCode qrcode;
    const uint8_t qr_version = 4;
    uint8_t qrcodeData[qrcode_getBufferSize(qr_version)];
    qrcode_initText(&qrcode, qrcodeData, qr_version, ECC_LOW, url.c_str());

    uint8_t modules = qrcode.size;
    uint8_t px_size = target_size / modules;
    if (px_size < 1) px_size = 1;
    uint16_t qr_px = modules * px_size;
    uint16_t padding = 4;

    // White background container
    lv_obj_t *qr_cont = lv_obj_create(parent);
    lv_obj_set_size(qr_cont, qr_px + padding * 2, qr_px + padding * 2);
    lv_obj_set_pos(qr_cont, x, y);
    lv_obj_set_style_bg_color(qr_cont, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(qr_cont, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_border_width(qr_cont, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(qr_cont, 4, LV_PART_MAIN);
    lv_obj_set_style_pad_all(qr_cont, padding, LV_PART_MAIN);
    lv_obj_clear_flag(qr_cont, LV_OBJ_FLAG_SCROLLABLE);

    // Draw modules
    for (uint8_t row = 0; row < modules; row++) {
        for (uint8_t col = 0; col < modules; col++) {
            if (qrcode_getModule(&qrcode, col, row)) {
                lv_obj_t *px = lv_obj_create(qr_cont);
                lv_obj_set_size(px, px_size, px_size);
                lv_obj_set_pos(px, col * px_size, row * px_size);
                lv_obj_set_style_bg_color(px, lv_color_hex(0x000000), LV_PART_MAIN);
                lv_obj_set_style_bg_opa(px, LV_OPA_COVER, LV_PART_MAIN);
                lv_obj_set_style_border_width(px, 0, LV_PART_MAIN);
                lv_obj_set_style_radius(px, 0, LV_PART_MAIN);
                lv_obj_set_style_pad_all(px, 0, LV_PART_MAIN);
                lv_obj_clear_flag(px, LV_OBJ_FLAG_SCROLLABLE);
            }
        }
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
    bool is_portrait = (sw < sh);

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
    lv_label_set_text(lbl_title, "SETTINGS");
    lv_obj_set_style_text_color(lbl_title, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_title, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_set_pos(lbl_title, 34, 8);

    // Time
    lv_obj_t *lbl_time = lv_label_create(header);
    String t = ntp_get_time();
    if (t.length() >= 5) {
        lv_label_set_text(lbl_time, t.substring(0, 5).c_str());
    } else {
        lv_label_set_text(lbl_time, "--:--");
    }
    lv_obj_set_style_text_color(lbl_time, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_time, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(lbl_time, LV_ALIGN_TOP_RIGHT, -8, 9);

    // ---- Divider ----
    ui_create_divider(scr, 32);

    // ---- Info rows ----
    // Provider row
    const MonitorState &ms = ui_dashboard_get_last_state();
    create_info_row(scr, "Provider:", ms.provider == 1 ? "OpenAI" : "Claude", 40);

    // Token validity
    {
        char tok_buf[40];
        if (ms.token_valid) {
            snprintf(tok_buf, sizeof(tok_buf), "Gueltig");
        } else {
            snprintf(tok_buf, sizeof(tok_buf), "Abgelaufen");
        }
        create_info_row(scr, "Token:", tok_buf, 58);
    }

    char wifi_buf[48];
    snprintf(wifi_buf, sizeof(wifi_buf), "%s  %d dBm",
             wifi_get_ssid().c_str(), wifi_get_rssi());
    create_info_row(scr, "WiFi:", wifi_buf, 76);

    create_info_row(scr, "IP:", wifi_get_ip().c_str(), 94);

    char mdns_buf[48];
    snprintf(mdns_buf, sizeof(mdns_buf), "%s.local", MDNS_HOSTNAME);
    create_info_row(scr, "Web:", mdns_buf, 112);

    // ---- QR Code ----
    String config_url = webserver_get_url();

    if (is_portrait) {
        // Portrait: QR code centered below info rows (shifted down due to extra rows)
        int16_t qr_x = (sw - 100) / 2;
        draw_settings_qr(scr, config_url, qr_x, 130, 100);

        // System info below QR
        char heap_buf[48];
        snprintf(heap_buf, sizeof(heap_buf), "%u KB / Min: %u KB",
                 ESP.getFreeHeap() / 1024, ESP.getMinFreeHeap() / 1024);
        create_info_row(scr, "Heap:", heap_buf, 240);

        char uptime_buf[32];
        format_uptime(uptime_buf, sizeof(uptime_buf));
        create_info_row(scr, "Uptime:", uptime_buf, 258);

        char poll_buf[48];
        snprintf(poll_buf, sizeof(poll_buf), "%lus | NTP: %s",
                 (unsigned long)g_config.poll_interval_sec,
                 ntp_is_synced() ? "synced" : "not synced");
        create_info_row(scr, "Poll:", poll_buf, 276);

    } else {
        // Landscape: QR code to the right (80px)
        draw_settings_qr(scr, config_url, sw - 100, 40, 80);

        // System info
        char heap_buf[48];
        snprintf(heap_buf, sizeof(heap_buf), "%u KB / Min: %u KB",
                 ESP.getFreeHeap() / 1024, ESP.getMinFreeHeap() / 1024);
        create_info_row(scr, "Heap:", heap_buf, 130);

        char uptime_buf[32];
        format_uptime(uptime_buf, sizeof(uptime_buf));
        create_info_row(scr, "Uptime:", uptime_buf, 148);

        char poll_buf[48];
        snprintf(poll_buf, sizeof(poll_buf), "%lus | NTP: %s",
                 (unsigned long)g_config.poll_interval_sec,
                 ntp_is_synced() ? "synced" : "not synced");
        create_info_row(scr, "Poll:", poll_buf, 166);
    }

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
