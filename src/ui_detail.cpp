/**
 * UI Detail - Provider detail screen with per-model breakdown
 *
 * Layout (320x240):
 *   Header: 32px   (back arrow + provider name + time)
 *   Summary: ~40px (Today + This Month rows)
 *   Models: ~130px (scrollable list with bars)
 *   Footer: 32px   (Input / Output / Cached token counts)
 */

#include "ui_detail.h"
#include "ui_common.h"
#include "ui_dashboard.h"
#include "config.h"
#include "ntp_time.h"

#include <lvgl.h>
#include <stdio.h>
#include <string.h>

// ============================================================
// Back button handler — slide back to dashboard
// ============================================================
static void on_back_tap(lv_event_t *e) {
    (void)e;
    ui_dashboard_load_back();
    // Delete the detail screen after animation
    lv_obj_t *old_scr = (lv_obj_t *)lv_event_get_user_data(e);
    if (old_scr != nullptr) {
        lv_obj_delete_async(old_scr);
    }
}

// ============================================================
// Create detail screen
// ============================================================
void ui_detail_create(const char *provider, const UsageData &data, lv_color_t brand_color) {
    ui_styles_init();

    lv_obj_t *scr = lv_obj_create(nullptr);
    lv_obj_set_style_bg_color(scr, UI_COLOR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    // ---- Header (32px) ----
    lv_obj_t *header = lv_obj_create(scr);
    lv_obj_set_size(header, 320, 32);
    lv_obj_set_pos(header, 0, 0);
    lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(header, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(header, 0, LV_PART_MAIN);
    lv_obj_clear_flag(header, LV_OBJ_FLAG_SCROLLABLE);

    // Back button (arrow left)
    lv_obj_t *btn_back = lv_label_create(header);
    lv_label_set_text(btn_back, LV_SYMBOL_LEFT);
    lv_obj_set_style_text_color(btn_back, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(btn_back, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_set_pos(btn_back, 8, 6);
    lv_obj_add_flag(btn_back, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_ext_click_area(btn_back, 15);
    lv_obj_add_event_cb(btn_back, on_back_tap, LV_EVENT_CLICKED, scr);

    // Provider name
    lv_obj_t *lbl_provider = lv_label_create(header);
    lv_label_set_text(lbl_provider, provider);
    lv_obj_set_style_text_color(lbl_provider, brand_color, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_provider, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_set_pos(lbl_provider, 34, 8);

    // Time (top right)
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

    // ---- Summary section (Today + This Month) ----
    char cost_buf[16];
    char tok_buf[16];
    char line_buf[48];

    // Today row
    lv_obj_t *lbl_today_label = lv_label_create(scr);
    lv_label_set_text(lbl_today_label, "Today");
    lv_obj_set_style_text_color(lbl_today_label, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_today_label, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl_today_label, 12, 38);

    format_cost(data.today_cost, cost_buf, sizeof(cost_buf));
    lv_obj_t *lbl_today_cost = lv_label_create(scr);
    lv_label_set_text(lbl_today_cost, cost_buf);
    lv_obj_set_style_text_color(lbl_today_cost, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_today_cost, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl_today_cost, 120, 38);

    uint32_t today_total = data.today_input_tokens + data.today_output_tokens;
    format_tokens(today_total, tok_buf, sizeof(tok_buf));
    snprintf(line_buf, sizeof(line_buf), "%s tok", tok_buf);
    lv_obj_t *lbl_today_tok = lv_label_create(scr);
    lv_label_set_text(lbl_today_tok, line_buf);
    lv_obj_set_style_text_color(lbl_today_tok, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_today_tok, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(lbl_today_tok, LV_ALIGN_TOP_RIGHT, -12, 38);

    // This Month row
    lv_obj_t *lbl_month_label = lv_label_create(scr);
    lv_label_set_text(lbl_month_label, "This Month");
    lv_obj_set_style_text_color(lbl_month_label, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_month_label, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl_month_label, 12, 56);

    format_cost(data.month_cost, cost_buf, sizeof(cost_buf));
    lv_obj_t *lbl_month_cost = lv_label_create(scr);
    lv_label_set_text(lbl_month_cost, cost_buf);
    lv_obj_set_style_text_color(lbl_month_cost, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_month_cost, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl_month_cost, 120, 56);

    uint32_t month_total = data.month_input_tokens + data.month_output_tokens;
    format_tokens(month_total, tok_buf, sizeof(tok_buf));
    snprintf(line_buf, sizeof(line_buf), "%s tok", tok_buf);
    lv_obj_t *lbl_month_tok = lv_label_create(scr);
    lv_label_set_text(lbl_month_tok, line_buf);
    lv_obj_set_style_text_color(lbl_month_tok, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_month_tok, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(lbl_month_tok, LV_ALIGN_TOP_RIGHT, -12, 56);

    // ---- Models section header ----
    lv_obj_t *lbl_models_hdr = lv_label_create(scr);
    lv_label_set_text(lbl_models_hdr, "Models");
    lv_obj_set_style_text_color(lbl_models_hdr, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_models_hdr, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl_models_hdr, 12, 78);

    // Thin divider under models header
    ui_create_divider(scr, 93);

    // ---- Model list container (scrollable) ----
    lv_obj_t *list = lv_obj_create(scr);
    lv_obj_set_size(list, 320, 100);
    lv_obj_set_pos(list, 0, 95);
    lv_obj_set_style_bg_opa(list, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(list, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(list, 4, LV_PART_MAIN);
    lv_obj_set_style_pad_gap(list, 2, LV_PART_MAIN);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_AUTO);
    lv_obj_set_scroll_dir(list, LV_DIR_VER);

    // Find max tokens for relative bars
    uint32_t max_model_tokens = 0;
    for (uint8_t i = 0; i < data.model_count; i++) {
        uint32_t t = data.models[i].input_tokens + data.models[i].output_tokens;
        if (t > max_model_tokens) max_model_tokens = t;
    }
    if (max_model_tokens == 0) max_model_tokens = 1;

    // ---- Model entries ----
    for (uint8_t i = 0; i < data.model_count; i++) {
        const ModelUsage &m = data.models[i];
        uint32_t model_total = m.input_tokens + m.output_tokens;

        // Single row per model: name + bar + token count
        lv_obj_t *row = lv_obj_create(list);
        lv_obj_set_size(row, 308, 28);
        lv_obj_set_style_bg_opa(row, LV_OPA_TRANSP, LV_PART_MAIN);
        lv_obj_set_style_border_width(row, 0, LV_PART_MAIN);
        lv_obj_set_style_pad_all(row, 2, LV_PART_MAIN);
        lv_obj_clear_flag(row, LV_OBJ_FLAG_SCROLLABLE);

        // Model name (clipped if too long)
        lv_obj_t *lbl_model = lv_label_create(row);
        lv_label_set_text(lbl_model, m.model);
        lv_obj_set_style_text_color(lbl_model, UI_COLOR_TEXT, LV_PART_MAIN);
        lv_obj_set_style_text_font(lbl_model, &lv_font_montserrat_14, LV_PART_MAIN);
        lv_obj_set_pos(lbl_model, 0, 4);
        lv_obj_set_width(lbl_model, 170);
        lv_label_set_long_mode(lbl_model, LV_LABEL_LONG_CLIP);

        // Token count (right-aligned)
        format_tokens(model_total, tok_buf, sizeof(tok_buf));
        lv_obj_t *lbl_mtok = lv_label_create(row);
        lv_label_set_text(lbl_mtok, tok_buf);
        lv_obj_set_style_text_color(lbl_mtok, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
        lv_obj_set_style_text_font(lbl_mtok, &lv_font_montserrat_14, LV_PART_MAIN);
        lv_obj_align(lbl_mtok, LV_ALIGN_TOP_RIGHT, 0, 4);
    }

    // Show placeholder if no models
    if (data.model_count == 0) {
        lv_obj_t *lbl_empty = lv_label_create(list);
        lv_label_set_text(lbl_empty, "No model data available");
        lv_obj_set_style_text_color(lbl_empty, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
        lv_obj_set_style_text_font(lbl_empty, &lv_font_montserrat_14, LV_PART_MAIN);
        lv_obj_center(lbl_empty);
    }

    // ---- Divider above footer ----
    ui_create_divider(scr, 198);

    // ---- Footer: Token breakdown (Input / Output / Cached) ----
    lv_obj_t *footer = lv_obj_create(scr);
    lv_obj_set_size(footer, 320, 40);
    lv_obj_set_pos(footer, 0, 200);
    lv_obj_set_style_bg_opa(footer, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(footer, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(footer, 0, LV_PART_MAIN);
    lv_obj_clear_flag(footer, LV_OBJ_FLAG_SCROLLABLE);

    char in_buf[16], out_buf[16], cache_buf[16];
    format_tokens(data.month_input_tokens, in_buf, sizeof(in_buf));
    format_tokens(data.month_output_tokens, out_buf, sizeof(out_buf));
    format_tokens(data.month_cached_tokens, cache_buf, sizeof(cache_buf));

    char footer_text[80];
    snprintf(footer_text, sizeof(footer_text), "In: %s  Out: %s  Cache: %s",
             in_buf, out_buf, cache_buf);

    lv_obj_t *lbl_footer = lv_label_create(footer);
    lv_label_set_text(lbl_footer, footer_text);
    lv_obj_set_style_text_color(lbl_footer, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_footer, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_center(lbl_footer);

    // ---- Load screen with slide-left animation ----
    ui_screen_load_forward(scr);

    Serial.printf("[UI] Detail screen: %s (%d models)\n", provider, data.model_count);
}
