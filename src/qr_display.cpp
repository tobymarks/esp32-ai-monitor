/**
 * QR Code Display - LVGL Screen with QR Code
 *
 * Uses the ricmoo/QRCode library to generate a QR code bitmap,
 * then draws it on an LVGL canvas. Shows the config URL below.
 */

#include "qr_display.h"
#include "config.h"
#include <lvgl.h>
#include <qrcode.h>

// ============================================================
// State
// ============================================================
static lv_obj_t *qr_screen = nullptr;
static bool qr_visible = false;

// ============================================================
// Draw QR code as LVGL rectangles on a container
// ============================================================
static void draw_qr_on_screen(lv_obj_t *parent, const String &url) {
    // QR Code generation
    QRCode qrcode;
    // Version 6 = up to 134 chars alphanumeric
    const uint8_t qr_version = 4;
    uint8_t qrcodeData[qrcode_getBufferSize(qr_version)];
    qrcode_initText(&qrcode, qrcodeData, qr_version, ECC_LOW, url.c_str());

    // Calculate pixel size: fit in ~180px area on 320x240 display
    uint8_t modules = qrcode.size;  // e.g., 33 for version 4
    uint8_t px_size = 160 / modules;  // pixel size per module
    if (px_size < 2) px_size = 2;
    uint16_t qr_px = modules * px_size;

    // Create a container for the QR code (white background)
    lv_obj_t *qr_cont = lv_obj_create(parent);
    uint16_t padding = 8;
    lv_obj_set_size(qr_cont, qr_px + padding * 2, qr_px + padding * 2);
    lv_obj_align(qr_cont, LV_ALIGN_TOP_MID, 0, 10);
    lv_obj_set_style_bg_color(qr_cont, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(qr_cont, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_border_width(qr_cont, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(qr_cont, 4, LV_PART_MAIN);
    lv_obj_set_style_pad_all(qr_cont, padding, LV_PART_MAIN);
    lv_obj_clear_flag(qr_cont, LV_OBJ_FLAG_SCROLLABLE);

    // Draw each black module as a small rectangle
    for (uint8_t y = 0; y < modules; y++) {
        for (uint8_t x = 0; x < modules; x++) {
            if (qrcode_getModule(&qrcode, x, y)) {
                lv_obj_t *px = lv_obj_create(qr_cont);
                lv_obj_set_size(px, px_size, px_size);
                lv_obj_set_pos(px, x * px_size, y * px_size);
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
// Show QR code screen
// ============================================================
void qr_display_show(const String &url) {
    if (qr_screen != nullptr) {
        lv_obj_delete(qr_screen);
        qr_screen = nullptr;
    }

    qr_screen = lv_obj_create(nullptr);
    lv_obj_set_style_bg_color(qr_screen, lv_color_hex(0x1A1A2E), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(qr_screen, LV_OPA_COVER, LV_PART_MAIN);

    // Draw QR code
    draw_qr_on_screen(qr_screen, url);

    // URL label below QR code
    lv_obj_t *url_label = lv_label_create(qr_screen);
    lv_label_set_text(url_label, url.c_str());
    lv_obj_set_style_text_color(url_label, lv_color_hex(0xE94560), LV_PART_MAIN);
    lv_obj_set_style_text_font(url_label, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(url_label, LV_ALIGN_BOTTOM_MID, 0, -30);

    // Instruction label
    lv_obj_t *hint = lv_label_create(qr_screen);
    lv_label_set_text(hint, "Scan to configure");
    lv_obj_set_style_text_color(hint, lv_color_hex(0x888888), LV_PART_MAIN);
    lv_obj_set_style_text_font(hint, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(hint, LV_ALIGN_BOTTOM_MID, 0, -10);

    lv_screen_load(qr_screen);
    qr_visible = true;

    Serial.printf("[QR] Showing QR code for: %s\n", url.c_str());
}

// ============================================================
// Hide QR screen
// ============================================================
void qr_display_hide() {
    if (qr_screen != nullptr) {
        lv_obj_delete(qr_screen);
        qr_screen = nullptr;
    }
    qr_visible = false;
}

// ============================================================
// Is QR screen visible?
// ============================================================
bool qr_display_is_visible() {
    return qr_visible;
}
