/**
 * UI Dashboard - Vibe-TV-Style main screen
 *
 * Portrait (240x320):
 * +---------------------------+
 * |     CLAUDE        12:34   |  Header: Provider + Uhrzeit
 * +---------------------------+
 * |         Session           |  Label (montserrat_14, muted)
 * |          73%              |  Grosse Zahl (montserrat_48, weiss)
 * |  [████████████░░░░░░░░]   |  Fortschrittsbalken
 * |     Resets in 2h 14m      |  Countdown (montserrat_14, muted)
 * |                           |
 * |         Weekly            |  Label
 * |          41%              |  Grosse Zahl
 * |  [█████░░░░░░░░░░░░░░░]   |  Fortschrittsbalken
 * |     Resets in 4d 12h      |  Countdown
 * +---------------------------+
 * |  ● OK   Updated 2m ago   |  Footer: Status + Zeit
 * +---------------------------+
 *
 * Touch:
 *   Tap         -> Detail screen
 *   Long press  -> Settings screen
 */

#include "ui_dashboard.h"
#include "ui_common.h"
#include "ui_detail.h"
#include "ui_settings.h"
#include "config.h"
#include "ntp_time.h"
#include "wifi_setup.h"

#include <lvgl.h>
#include <stdio.h>
#include <time.h>

// ============================================================
// Widget references (created once, updated in-place)
// All initialised to nullptr — guards in ui_dashboard_update()
// rely on these being NULL before ui_dashboard_create() runs.
// ============================================================
static lv_obj_t *scr_dashboard      = nullptr;

// Header
static lv_obj_t *lbl_provider       = nullptr;
static lv_obj_t *lbl_time           = nullptr;

// Session block
static lv_obj_t *lbl_session_pct    = nullptr;
static lv_obj_t *bar_session        = nullptr;
static lv_obj_t *lbl_session_reset  = nullptr;

// Weekly block
static lv_obj_t *lbl_weekly_pct     = nullptr;
static lv_obj_t *bar_weekly         = nullptr;
static lv_obj_t *lbl_weekly_reset   = nullptr;

// Footer
static lv_obj_t *lbl_status_dot     = nullptr;
static lv_obj_t *lbl_refresh        = nullptr;

// Last known state (for detail screen)
static MonitorState last_state;
static bool state_stored = false;

// Long-press overlay
static lv_obj_t *long_press_overlay = nullptr;

// ============================================================
// Helper: returns true only when all dashboard widgets are live
// ============================================================
static inline bool widgets_ready() {
    return scr_dashboard    != nullptr
        && lbl_provider     != nullptr
        && lbl_time         != nullptr
        && lbl_session_pct  != nullptr
        && bar_session      != nullptr
        && lbl_session_reset!= nullptr
        && lbl_weekly_pct   != nullptr
        && bar_weekly       != nullptr
        && lbl_weekly_reset != nullptr
        && lbl_status_dot   != nullptr
        && lbl_refresh      != nullptr;
}

// ============================================================
// Event handlers
// ============================================================
static void on_tap(lv_event_t *e) {
    (void)e;
    if (state_stored && last_state.usage.valid) {
        ui_detail_create(last_state);
    }
}

static void on_long_press(lv_event_t *e) {
    (void)e;
    ui_settings_create();
    Serial.println("[UI] Long press -> Settings screen");
}

// ============================================================
// Helper: create a usage block (label + big pct + bar + countdown)
// Returns the bottom y-position after the block.
// ============================================================
static int16_t create_usage_block(
    lv_obj_t *parent,
    const char *title,
    int16_t y_start,
    lv_obj_t **out_pct_lbl,
    lv_obj_t **out_bar,
    lv_obj_t **out_reset_lbl
) {
    int16_t sw = SCREEN_WIDTH;
    int16_t bar_w = sw - 24;  // 12px padding each side
    int16_t cx = sw / 2;

    // Section title label (muted)
    lv_obj_t *lbl_title = lv_label_create(parent);
    lv_label_set_text(lbl_title, title);
    lv_obj_set_style_text_color(lbl_title, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_title, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl_title, 0, y_start);
    lv_obj_set_width(lbl_title, sw);
    lv_obj_set_style_text_align(lbl_title, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    // Big percentage label (white)
    *out_pct_lbl = lv_label_create(parent);
    lv_label_set_text(*out_pct_lbl, "--%");
    lv_obj_set_style_text_color(*out_pct_lbl, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_pct_lbl, &lv_font_montserrat_48, LV_PART_MAIN);
    lv_obj_set_pos(*out_pct_lbl, 0, y_start + 18);
    lv_obj_set_width(*out_pct_lbl, sw);
    lv_obj_set_style_text_align(*out_pct_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    // Progress bar
    *out_bar = lv_bar_create(parent);
    lv_obj_set_size(*out_bar, bar_w, 12);
    lv_obj_set_pos(*out_bar, 12, y_start + 76);
    lv_bar_set_range(*out_bar, 0, 100);
    lv_bar_set_value(*out_bar, 0, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(*out_bar, UI_COLOR_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(*out_bar, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(*out_bar, 6, LV_PART_MAIN);
    lv_obj_set_style_bg_color(*out_bar, UI_COLOR_BAR_GREEN, LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(*out_bar, LV_OPA_COVER, LV_PART_INDICATOR);
    lv_obj_set_style_radius(*out_bar, 6, LV_PART_INDICATOR);

    // Reset countdown label (muted, centered)
    *out_reset_lbl = lv_label_create(parent);
    lv_label_set_text(*out_reset_lbl, "Resets in --");
    lv_obj_set_style_text_color(*out_reset_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_reset_lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(*out_reset_lbl, 0, y_start + 94);
    lv_obj_set_width(*out_reset_lbl, sw);
    lv_obj_set_style_text_align(*out_reset_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    return y_start + 114;  // Block height ~114px
}

// ============================================================
// Create dashboard screen (call once)
// ============================================================
void ui_dashboard_create() {
    ui_styles_init();

    if (scr_dashboard != nullptr) {
        return;  // Already created
    }

    int16_t sw = SCREEN_WIDTH;
    int16_t sh = SCREEN_HEIGHT;

    scr_dashboard = lv_obj_create(nullptr);
    lv_obj_set_style_bg_color(scr_dashboard, UI_COLOR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr_dashboard, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_clear_flag(scr_dashboard, LV_OBJ_FLAG_SCROLLABLE);

    // ---- Header (36px) ----
    lv_obj_t *header = lv_obj_create(scr_dashboard);
    lv_obj_set_size(header, sw, 36);
    lv_obj_set_pos(header, 0, 0);
    lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(header, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(header, 0, LV_PART_MAIN);
    lv_obj_clear_flag(header, LV_OBJ_FLAG_SCROLLABLE);

    // Provider name — Montserrat 20, bold, white, centered
    lbl_provider = lv_label_create(header);
    lv_label_set_text(lbl_provider, "CLAUDE");
    lv_obj_set_style_text_color(lbl_provider, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_provider, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_set_pos(lbl_provider, 0, 8);
    lv_obj_set_width(lbl_provider, sw);
    lv_obj_set_style_text_align(lbl_provider, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    // Clock — Montserrat 14, muted, top right
    lbl_time = lv_label_create(header);
    lv_label_set_text(lbl_time, "--:--");
    lv_obj_set_style_text_color(lbl_time, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_time, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(lbl_time, LV_ALIGN_TOP_RIGHT, -8, 11);

    // ---- Divider under header ----
    ui_create_divider(scr_dashboard, 36);

    // ---- Session block ----
    int16_t session_y = 44;
    int16_t after_session = create_usage_block(
        scr_dashboard, "Session",
        session_y,
        &lbl_session_pct, &bar_session, &lbl_session_reset
    );

    // ---- Thin separator between blocks ----
    ui_create_divider(scr_dashboard, after_session + 4);

    // ---- Weekly block ----
    int16_t weekly_y = after_session + 12;
    create_usage_block(
        scr_dashboard, "Weekly",
        weekly_y,
        &lbl_weekly_pct, &bar_weekly, &lbl_weekly_reset
    );

    // ---- Divider above footer ----
    int16_t footer_h  = 38;
    int16_t footer_y  = sh - footer_h;
    ui_create_divider(scr_dashboard, footer_y - 2);

    // ---- Footer ----
    lv_obj_t *footer = lv_obj_create(scr_dashboard);
    lv_obj_set_size(footer, sw, footer_h);
    lv_obj_set_pos(footer, 0, footer_y);
    lv_obj_set_style_bg_opa(footer, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(footer, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(footer, 0, LV_PART_MAIN);
    lv_obj_clear_flag(footer, LV_OBJ_FLAG_SCROLLABLE);

    // Status dot (left)
    lbl_status_dot = lv_label_create(footer);
    lv_label_set_text(lbl_status_dot, LV_SYMBOL_OK);
    lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_status_dot, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl_status_dot, 10, 12);

    // Refresh time (right)
    lbl_refresh = lv_label_create(footer);
    lv_label_set_text(lbl_refresh, "never");
    lv_obj_set_style_text_color(lbl_refresh, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_refresh, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(lbl_refresh, LV_ALIGN_TOP_RIGHT, -10, 12);

    // ---- Full-screen overlay for touch events ----
    long_press_overlay = lv_obj_create(scr_dashboard);
    lv_obj_set_size(long_press_overlay, sw, sh);
    lv_obj_set_pos(long_press_overlay, 0, 0);
    lv_obj_set_style_bg_opa(long_press_overlay, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(long_press_overlay, 0, LV_PART_MAIN);
    lv_obj_clear_flag(long_press_overlay, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(long_press_overlay, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(long_press_overlay, LV_OBJ_FLAG_CLICK_FOCUSABLE);
    lv_obj_add_event_cb(long_press_overlay, on_tap, LV_EVENT_CLICKED, nullptr);
    lv_obj_add_event_cb(long_press_overlay, on_long_press, LV_EVENT_LONG_PRESSED, nullptr);
    lv_obj_move_to_index(long_press_overlay, 0);

    memset(&last_state, 0, sizeof(last_state));
    state_stored = false;

    Serial.println("[UI] Dashboard screen created (Vibe-TV-Style)");
}

// ============================================================
// Update dashboard with fresh MonitorState
// ============================================================
void ui_dashboard_update(const MonitorState &state) {
    // Guard: bail out if any widget pointer is still NULL.
    // This prevents StoreProhibited crashes when update is called
    // before create_usage_block() has finished populating all pointers.
    if (!widgets_ready()) return;

    memcpy(&last_state, &state, sizeof(MonitorState));
    state_stored = true;

    // ---- Provider name ----
    if (lbl_provider != nullptr) {
        lv_label_set_text(lbl_provider, state.provider == 1 ? "OPENAI" : "CLAUDE");
    }

    // ---- Clock ----
    if (lbl_time != nullptr) {
        String t = ntp_get_time();
        if (t.length() >= 5) {
            lv_label_set_text(lbl_time, t.substring(0, 5).c_str());
        }
    }

    // ---- Session block ----
    if (state.usage.valid) {
        char buf[32];

        // Session percentage
        format_percentage(state.usage.five_hour_utilization, buf, sizeof(buf));
        lv_label_set_text(lbl_session_pct, buf);

        // Session bar (color based on utilization)
        int bar_val = (int)(state.usage.five_hour_utilization * 100.0f);
        if (bar_val < 0) bar_val = 0;
        if (bar_val > 100) bar_val = 100;
        lv_bar_set_value(bar_session, bar_val, LV_ANIM_ON);
        lv_color_t session_color = ui_bar_color(state.usage.five_hour_utilization);
        lv_obj_set_style_bg_color(bar_session, session_color, LV_PART_INDICATOR);

        // Session countdown
        format_countdown(state.usage.five_hour_reset_epoch, buf, sizeof(buf));
        char reset_buf[48];
        snprintf(reset_buf, sizeof(reset_buf), "Resets in %s", buf);
        lv_label_set_text(lbl_session_reset, reset_buf);

        // Weekly percentage
        format_percentage(state.usage.seven_day_utilization, buf, sizeof(buf));
        lv_label_set_text(lbl_weekly_pct, buf);

        // Weekly bar
        bar_val = (int)(state.usage.seven_day_utilization * 100.0f);
        if (bar_val < 0) bar_val = 0;
        if (bar_val > 100) bar_val = 100;
        lv_bar_set_value(bar_weekly, bar_val, LV_ANIM_ON);
        lv_color_t weekly_color = ui_bar_color(state.usage.seven_day_utilization);
        lv_obj_set_style_bg_color(bar_weekly, weekly_color, LV_PART_INDICATOR);

        // Weekly countdown
        format_countdown(state.usage.seven_day_reset_epoch, buf, sizeof(buf));
        snprintf(reset_buf, sizeof(reset_buf), "Resets in %s", buf);
        lv_label_set_text(lbl_weekly_reset, reset_buf);

    } else if (strlen(state.usage.error) > 0) {
        // All widget pointers are guaranteed non-NULL here (widgets_ready() above).
        lv_label_set_text(lbl_session_pct,   "ERR");
        lv_label_set_text(lbl_session_reset, state.usage.error);
        lv_bar_set_value(bar_session, 0, LV_ANIM_OFF);
        lv_label_set_text(lbl_weekly_pct,    "ERR");
        lv_label_set_text(lbl_weekly_reset,  "");
        lv_bar_set_value(bar_weekly, 0, LV_ANIM_OFF);
    }

    // ---- Footer: status dot ----
    bool online = wifi_is_connected();
    if (state.is_fetching) {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_FETCHING, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_REFRESH);
    } else if (online && state.usage.valid) {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_SUCCESS, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_OK);
    } else if (!online) {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_ERROR, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_CLOSE);
    } else {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_DUMMY);
    }

    // ---- Footer: time ago ----
    char ago_buf[24];
    format_time_ago(state.usage.last_fetch, ago_buf, sizeof(ago_buf));
    char refresh_line[40];
    snprintf(refresh_line, sizeof(refresh_line), "Updated %s", ago_buf);
    lv_label_set_text(lbl_refresh, refresh_line);
}

// ============================================================
// Load the dashboard screen (fade)
// ============================================================
void ui_dashboard_load() {
    if (scr_dashboard != nullptr) {
        ui_screen_load_fade(scr_dashboard);
    }
}

// ============================================================
// Load the dashboard screen (slide back from right)
// ============================================================
void ui_dashboard_load_back() {
    if (scr_dashboard != nullptr) {
        ui_screen_load_back(scr_dashboard);
    }
}

// ============================================================
// Get screen object
// ============================================================
lv_obj_t* ui_dashboard_get_screen() {
    return scr_dashboard;
}

// ============================================================
// Get last known state
// ============================================================
const MonitorState& ui_dashboard_get_last_state() {
    return last_state;
}
