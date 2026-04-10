/**
 * UI Setup - Setup hint screen shown when no API keys are configured
 *
 * Shows a centered message directing the user to the web config portal.
 */

#include "ui_setup.h"
#include "ui_common.h"
#include "config.h"

#include <lvgl.h>

// ============================================================
// Create setup hint screen
// ============================================================
void ui_setup_create() {
    ui_styles_init();

    lv_obj_t *scr = lv_obj_create(nullptr);
    lv_obj_set_style_bg_color(scr, UI_COLOR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    // Title
    lv_obj_t *title = lv_label_create(scr);
    lv_label_set_text(title, "AI USAGE MONITOR");
    lv_obj_set_style_text_color(title, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 20);

    // Setup icon + message
    lv_obj_t *icon = lv_label_create(scr);
    lv_label_set_text(icon, LV_SYMBOL_SETTINGS "  Setup Required");
    lv_obj_set_style_text_color(icon, UI_COLOR_ACCENT, LV_PART_MAIN);
    lv_obj_set_style_text_font(icon, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_align(icon, LV_ALIGN_CENTER, 0, -30);

    // Instructions
    lv_obj_t *instr = lv_label_create(scr);
    lv_label_set_text(instr, "Token konfigurieren unter:");
    lv_obj_set_style_text_color(instr, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(instr, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(instr, LV_ALIGN_CENTER, 0, 10);

    // URL
    lv_obj_t *url = lv_label_create(scr);
    lv_label_set_text(url, "http://" MDNS_HOSTNAME ".local/");
    lv_obj_set_style_text_color(url, UI_COLOR_ACCENT, LV_PART_MAIN);
    lv_obj_set_style_text_font(url, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_align(url, LV_ALIGN_CENTER, 0, 35);

    // Subtitle
    lv_obj_t *sub = lv_label_create(scr);
    lv_label_set_text(sub, "im Browser aufrufen");
    lv_obj_set_style_text_color(sub, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(sub, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(sub, LV_ALIGN_CENTER, 0, 60);

    // Version
    lv_obj_t *ver = lv_label_create(scr);
    lv_label_set_text_fmt(ver, "v%s", APP_VERSION);
    lv_obj_set_style_text_color(ver, lv_color_hex(0x444444), LV_PART_MAIN);
    lv_obj_set_style_text_font(ver, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(ver, LV_ALIGN_BOTTOM_RIGHT, -10, -10);

    Serial.printf("[UI] Setup screen created: %p, loading...\n", (void *)scr);
    lv_screen_load(scr);
    lv_obj_invalidate(scr);  // Force full redraw
    Serial.printf("[UI] Setup screen loaded, active screen: %p\n", (void *)lv_screen_active());
}
