/**
 * QR Code Display - LVGL Screen with QR Code
 *
 * Uses the ricmoo/QRCode library to generate a QR code bitmap,
 * then draws it on an LVGL canvas (single object) instead of
 * creating hundreds of individual LVGL objects.
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

// Canvas buffer (allocated on heap, freed on hide)
static lv_color_t *canvas_buf = nullptr;

// ============================================================
// Draw QR code on an LVGL canvas (single object, no heap explosion)
// ============================================================
static void draw_qr_on_screen(lv_obj_t *parent, const String &url) {
    QRCode qrcode;
    const uint8_t qr_version = 4;
    uint8_t qrcodeData[qrcode_getBufferSize(qr_version)];
    qrcode_initText(&qrcode, qrcodeData, qr_version, ECC_LOW, url.c_str());

    uint8_t modules = qrcode.size;  // 33 for version 4
    uint8_t px_size = 160 / modules;
    if (px_size < 2) px_size = 2;
    uint16_t qr_px = modules * px_size;
    uint16_t canvas_size = qr_px + 16;  // 8px padding each side

    // Allocate canvas buffer on PSRAM or heap
    uint32_t buf_size = canvas_size * canvas_size;
    canvas_buf = (lv_color_t *)heap_caps_malloc(buf_size * sizeof(lv_color_t), MALLOC_CAP_DEFAULT);
    if (canvas_buf == nullptr) {
        Serial.println("[QR] Failed to allocate canvas buffer");
        // Fallback: just show text, no QR
        return;
    }

    // Create canvas
    lv_obj_t *canvas = lv_canvas_create(parent);
    lv_canvas_set_buffer(canvas, canvas_buf, canvas_size, canvas_size, LV_COLOR_FORMAT_NATIVE);
    lv_obj_align(canvas, LV_ALIGN_TOP_MID, 0, 10);

    // Fill white background
    lv_canvas_fill_bg(canvas, lv_color_hex(0xFFFFFF), LV_OPA_COVER);

    // Draw QR modules as filled rectangles on canvas
    lv_layer_t layer;
    lv_canvas_init_layer(canvas, &layer);

    lv_draw_rect_dsc_t rect_dsc;
    lv_draw_rect_dsc_init(&rect_dsc);
    rect_dsc.bg_color = lv_color_hex(0x000000);
    rect_dsc.bg_opa = LV_OPA_COVER;
    rect_dsc.radius = 0;
    rect_dsc.border_width = 0;

    for (uint8_t y = 0; y < modules; y++) {
        for (uint8_t x = 0; x < modules; x++) {
            if (qrcode_getModule(&qrcode, x, y)) {
                lv_area_t area;
                area.x1 = 8 + x * px_size;
                area.y1 = 8 + y * px_size;
                area.x2 = area.x1 + px_size - 1;
                area.y2 = area.y1 + px_size - 1;
                lv_draw_rect(&layer, &rect_dsc, &area);
            }
        }
    }

    lv_canvas_finish_layer(canvas, &layer);
}

// ============================================================
// Show QR code screen
// ============================================================
void qr_display_show(const String &url) {
    if (qr_screen != nullptr) {
        lv_obj_delete(qr_screen);
        qr_screen = nullptr;
    }
    if (canvas_buf != nullptr) {
        heap_caps_free(canvas_buf);
        canvas_buf = nullptr;
    }

    qr_screen = lv_obj_create(nullptr);
    lv_obj_set_style_bg_color(qr_screen, lv_color_hex(0x1A1A2E), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(qr_screen, LV_OPA_COVER, LV_PART_MAIN);

    // Draw QR code (single canvas object)
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
    if (canvas_buf != nullptr) {
        heap_caps_free(canvas_buf);
        canvas_buf = nullptr;
    }
    qr_visible = false;
}

// ============================================================
// Is QR screen visible?
// ============================================================
bool qr_display_is_visible() {
    return qr_visible;
}
