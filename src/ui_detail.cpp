/**
 * UI Detail - Detail screen showing session and weekly usage breakdown
 *
 * Accessed via tap on dashboard.
 * Back button -> Dashboard
 */

#include "ui_detail.h"
#include "ui_common.h"
#include "ui_dashboard.h"
#include "config.h"
#include "localization.h"

#include <lvgl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

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
// Helper: info row (label: value)
// ============================================================
static void detail_info_row(lv_obj_t *parent, const char *label, const char *value, int16_t y) {
    lv_obj_t *lbl = lv_label_create(parent);
    lv_label_set_text(lbl, label);
    lv_obj_set_style_text_color(lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl, 12, y);

    lv_obj_t *val = lv_label_create(parent);
    lv_label_set_text(val, value);
    lv_obj_set_style_text_color(val, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(val, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(val, LV_ALIGN_TOP_RIGHT, -12, y);
}

// ============================================================
// Helper: usage bar row (label + bar)
// ============================================================
static void detail_bar_row(
    lv_obj_t *parent,
    const char *label,
    float utilization,
    time_t reset_epoch,
    int16_t y
) {
    int16_t sw  = SCREEN_WIDTH;
    int16_t bar_w = sw - 24;

    lv_obj_t *lbl = lv_label_create(parent);
    lv_label_set_text(lbl, label);
    lv_obj_set_style_text_color(lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl, 12, y);

    char pct_buf[16];
    format_percentage(utilization, pct_buf, sizeof(pct_buf));
    lv_obj_t *pct = lv_label_create(parent);
    lv_label_set_text(pct, pct_buf);
    lv_obj_set_style_text_color(pct, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(pct, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(pct, LV_ALIGN_TOP_RIGHT, -12, y);

    lv_obj_t *bar = lv_bar_create(parent);
    lv_obj_set_size(bar, bar_w, 10);
    lv_obj_set_pos(bar, 12, y + 20);
    lv_bar_set_range(bar, 0, 100);
    int bar_val = (int)(utilization * 100.0f);
    if (bar_val < 0) bar_val = 0;
    if (bar_val > 100) bar_val = 100;
    lv_bar_set_value(bar, bar_val, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(bar, UI_COLOR_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(bar, 5, LV_PART_MAIN);
    lv_obj_set_style_bg_color(bar, ui_bar_color(utilization), LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, LV_PART_INDICATOR);
    lv_obj_set_style_radius(bar, 5, LV_PART_INDICATOR);

    char cd_buf[32];
    format_countdown(reset_epoch, cd_buf, sizeof(cd_buf));
    char reset_line[48];
    snprintf(reset_line, sizeof(reset_line), L(STR_RESETS_IN), cd_buf);
    lv_obj_t *cd = lv_label_create(parent);
    lv_label_set_text(cd, reset_line);
    lv_obj_set_style_text_color(cd, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(cd, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(cd, 12, y + 36);
}

// ============================================================
// Create detail screen
// ============================================================
void ui_detail_create(const MonitorState &state) {
    ui_styles_init();

    const UsageData &data = state.usage;
    const char *provider_name = (state.provider == 1) ? "OPENAI" : "CLAUDE";
    lv_color_t brand_color = (state.provider == 1) ? UI_COLOR_OPENAI : UI_COLOR_ANTHROPIC;

    int16_t sw = SCREEN_WIDTH;
    int16_t sh = SCREEN_HEIGHT;

    lv_obj_t *scr = lv_obj_create(nullptr);
    lv_obj_set_style_bg_color(scr, UI_COLOR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    // ---- Header ----
    lv_obj_t *header = lv_obj_create(scr);
    lv_obj_set_size(header, sw, 36);
    lv_obj_set_pos(header, 0, 0);
    lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(header, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(header, 0, LV_PART_MAIN);
    lv_obj_clear_flag(header, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *btn_back = lv_label_create(header);
    lv_label_set_text(btn_back, LV_SYMBOL_LEFT);
    lv_obj_set_style_text_color(btn_back, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(btn_back, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_set_pos(btn_back, 8, 8);
    lv_obj_add_flag(btn_back, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_ext_click_area(btn_back, 15);
    lv_obj_add_event_cb(btn_back, on_back_tap, LV_EVENT_CLICKED, scr);

    lv_obj_t *lbl_prov = lv_label_create(header);
    lv_label_set_text(lbl_prov, provider_name);
    lv_obj_set_style_text_color(lbl_prov, brand_color, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_prov, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_set_pos(lbl_prov, 34, 10);

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
    lv_obj_align(lbl_time, LV_ALIGN_TOP_RIGHT, -8, 11);

    // ---- Divider ----
    ui_create_divider(scr, 36);

    // ---- Usage bars ----
    int16_t content_y = 44;

    detail_bar_row(scr, L(STR_SESSION_5H),
                   data.five_hour_utilization,
                   data.five_hour_reset_epoch,
                   content_y);
    content_y += 60;

    ui_create_divider(scr, content_y);
    content_y += 8;

    detail_bar_row(scr, L(STR_WEEKLY_7D),
                   data.seven_day_utilization,
                   data.seven_day_reset_epoch,
                   content_y);
    content_y += 60;

    // ---- Extra usage (if present) ----
    if (data.has_extra_usage) {
        ui_create_divider(scr, content_y);
        content_y += 8;

        char extra_buf[48];
        snprintf(extra_buf, sizeof(extra_buf), "%.0f / %.0f credits",
                 data.extra_used_credits, data.extra_monthly_limit);
        detail_bar_row(scr, L(STR_EXTRA_MONTHLY),
                       data.extra_utilization,
                       0,
                       content_y);
        content_y += 60;
    }

    // ---- Footer ----
    int16_t footer_y = sh - 44;
    ui_create_divider(scr, footer_y - 2);

    lv_obj_t *lbl_footer = lv_label_create(scr);
    if (!data.valid && strlen(data.error) > 0) {
        lv_label_set_text(lbl_footer, data.error);
    } else {
        char source_buf[48];
        snprintf(source_buf, sizeof(source_buf), "%s %s", L(STR_SOURCE), L(STR_SOURCE_USB));
        lv_label_set_text(lbl_footer, source_buf);
    }
    lv_obj_set_style_text_color(lbl_footer, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_footer, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl_footer, 12, footer_y + 14);

    // ---- Load screen ----
    ui_screen_load_forward(scr);

    Serial.printf("[UI] Detail screen: %s\n", provider_name);
}
