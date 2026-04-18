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
#include "localization.h"
#include "serial_receiver.h"

#include <lvgl.h>
#include <stdio.h>

// ============================================================
// Widget references (created once, updated in-place)
// ============================================================
static lv_obj_t *scr_dashboard      = nullptr;

// true = landscape layout with arcs, false = portrait with progress bars
static bool landscape_layout = false;

// Header
static lv_obj_t *lbl_provider       = nullptr;
static lv_obj_t *lbl_time           = nullptr;

// Session block — in portrait: bar; in landscape: arc
static lv_obj_t *lbl_session_pct    = nullptr;
static lv_obj_t *bar_session        = nullptr;   // null in landscape
static lv_obj_t *arc_session        = nullptr;   // null in portrait
static lv_obj_t *lbl_session_title  = nullptr;
static lv_obj_t *lbl_session_reset  = nullptr;

// Weekly block
static lv_obj_t *lbl_weekly_pct     = nullptr;
static lv_obj_t *bar_weekly         = nullptr;   // null in landscape
static lv_obj_t *arc_weekly         = nullptr;   // null in portrait
static lv_obj_t *lbl_weekly_title   = nullptr;
static lv_obj_t *lbl_weekly_reset   = nullptr;

// Header status icon (connection indicator)
static lv_obj_t *lbl_status_dot     = nullptr;

// Last known state (for detail screen)
static MonitorState last_state;
static bool state_stored = false;

// Long-press overlay
static lv_obj_t *long_press_overlay = nullptr;

// Splash overlay (shown until first data arrives)
static lv_obj_t *splash_overlay     = nullptr;
static lv_obj_t *splash_spinner     = nullptr;
static bool       first_data_received = false;

// ============================================================
// Helper: returns true only when all dashboard widgets are live
// ============================================================
static inline bool widgets_ready() {
    bool base = scr_dashboard    != nullptr
             && lbl_provider     != nullptr
             && lbl_time         != nullptr
             && lbl_session_pct  != nullptr
             && lbl_session_reset!= nullptr
             && lbl_weekly_pct   != nullptr
             && lbl_weekly_reset != nullptr
             && lbl_status_dot   != nullptr;
    if (!base) return false;
    if (landscape_layout) {
        return arc_session != nullptr && arc_weekly != nullptr;
    } else {
        return bar_session != nullptr && bar_weekly != nullptr;
    }
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
// Helper: create a usage block (label + big pct + bar + countdown) — PORTRAIT
// ============================================================
static int16_t create_usage_block(
    lv_obj_t *parent,
    const char *title,
    int16_t y_start,
    lv_obj_t **out_title_lbl,
    lv_obj_t **out_pct_lbl,
    lv_obj_t **out_bar,
    lv_obj_t **out_reset_lbl
) {
    int16_t sw = SCREEN_WIDTH;
    int16_t bar_w = sw - 24;

    *out_title_lbl = lv_label_create(parent);
    lv_label_set_text(*out_title_lbl, title);
    lv_obj_set_style_text_color(*out_title_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_title_lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(*out_title_lbl, 0, y_start);
    lv_obj_set_width(*out_title_lbl, sw);
    lv_obj_set_style_text_align(*out_title_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    *out_pct_lbl = lv_label_create(parent);
    lv_label_set_text(*out_pct_lbl, "--%");
    lv_obj_set_style_text_color(*out_pct_lbl, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_pct_lbl, &lv_font_montserrat_48, LV_PART_MAIN);
    lv_obj_set_pos(*out_pct_lbl, 0, y_start + 18);
    lv_obj_set_width(*out_pct_lbl, sw);
    lv_obj_set_style_text_align(*out_pct_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

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

    *out_reset_lbl = lv_label_create(parent);
    lv_label_set_text(*out_reset_lbl, "Resets in --");
    lv_obj_set_style_text_color(*out_reset_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_reset_lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(*out_reset_lbl, 0, y_start + 94);
    lv_obj_set_width(*out_reset_lbl, sw);
    lv_obj_set_style_text_align(*out_reset_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    return y_start + 114;
}

// ============================================================
// Helper: create a LANDSCAPE arc block (title + arc w/ pct inside + reset)
// Centre of the cell is (cx, cy); arc diameter = arc_diameter.
// ============================================================
static void create_arc_block(
    lv_obj_t *parent,
    const char *title,
    int16_t cx,
    int16_t cell_top,
    int16_t cell_w,
    int16_t cell_h,
    int16_t arc_diameter,
    lv_obj_t **out_title_lbl,
    lv_obj_t **out_arc,
    lv_obj_t **out_pct_lbl,
    lv_obj_t **out_reset_lbl
) {
    const int16_t title_h = 16;
    const int16_t reset_h = 16;
    const int16_t gap     = 6;
    int16_t content_h = title_h + gap + arc_diameter + gap + reset_h;
    int16_t pad_top   = (cell_h - content_h) / 2;
    if (pad_top < 0) pad_top = 0;

    int16_t title_y = cell_top + pad_top;
    int16_t arc_y   = title_y + title_h + gap;
    int16_t reset_y = arc_y + arc_diameter + gap;

    // Title
    *out_title_lbl = lv_label_create(parent);
    lv_label_set_text(*out_title_lbl, title);
    lv_obj_set_style_text_color(*out_title_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_title_lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_width(*out_title_lbl, cell_w);
    lv_obj_set_pos(*out_title_lbl, cx - cell_w / 2, title_y);
    lv_obj_set_style_text_align(*out_title_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    // Arc (filled ring)
    *out_arc = lv_arc_create(parent);
    lv_obj_set_size(*out_arc, arc_diameter, arc_diameter);
    lv_obj_set_pos(*out_arc, cx - arc_diameter / 2, arc_y);
    lv_arc_set_rotation(*out_arc, 270);       // start at 12 o'clock
    lv_arc_set_bg_angles(*out_arc, 0, 360);   // full circle background
    lv_arc_set_range(*out_arc, 0, 100);
    lv_arc_set_value(*out_arc, 0);
    lv_obj_remove_style(*out_arc, NULL, LV_PART_KNOB);
    lv_obj_clear_flag(*out_arc, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_style_arc_width(*out_arc, 14, LV_PART_MAIN);
    lv_obj_set_style_arc_color(*out_arc, UI_COLOR_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_arc_opa(*out_arc, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_arc_width(*out_arc, 14, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(*out_arc, UI_COLOR_BAR_GREEN, LV_PART_INDICATOR);
    lv_obj_set_style_arc_opa(*out_arc, LV_OPA_COVER, LV_PART_INDICATOR);

    // Percent in arc centre
    *out_pct_lbl = lv_label_create(parent);
    lv_label_set_text(*out_pct_lbl, "--%");
    lv_obj_set_style_text_color(*out_pct_lbl, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_pct_lbl, &lv_font_montserrat_36, LV_PART_MAIN);
    lv_obj_set_style_text_align(*out_pct_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    // Centre the label on the arc centre (arc origin + radius)
    lv_obj_align_to(*out_pct_lbl, *out_arc, LV_ALIGN_CENTER, 0, 0);

    // Reset time under the arc
    *out_reset_lbl = lv_label_create(parent);
    lv_label_set_text(*out_reset_lbl, "--");
    lv_obj_set_style_text_color(*out_reset_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_reset_lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_width(*out_reset_lbl, cell_w);
    lv_obj_set_pos(*out_reset_lbl, cx - cell_w / 2, reset_y);
    lv_obj_set_style_text_align(*out_reset_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_label_set_long_mode(*out_reset_lbl, LV_LABEL_LONG_DOT);
}

// ============================================================
// Create dashboard screen (call once)
// ============================================================
void ui_dashboard_create() {
    ui_styles_init();

    if (scr_dashboard != nullptr) {
        return;
    }

    int16_t sw = SCREEN_WIDTH;
    int16_t sh = SCREEN_HEIGHT;

    // Landscape = wider than tall (320x240)
    landscape_layout = (sw > sh);

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

    // Connection status icon (top-left, same style as clock)
    lbl_status_dot = lv_label_create(header);
    lv_label_set_text(lbl_status_dot, LV_SYMBOL_DUMMY);
    lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_status_dot, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(lbl_status_dot, 8, 11);

    lbl_provider = lv_label_create(header);
    lv_label_set_text(lbl_provider, "CLAUDE");
    lv_obj_set_style_text_color(lbl_provider, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_provider, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_set_pos(lbl_provider, 0, 8);
    lv_obj_set_width(lbl_provider, sw);
    lv_obj_set_style_text_align(lbl_provider, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    lbl_time = lv_label_create(header);
    lv_label_set_text(lbl_time, "--:--");
    lv_obj_set_style_text_color(lbl_time, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_time, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(lbl_time, LV_ALIGN_TOP_RIGHT, -8, 11);

    // ---- Divider under header ----
    const int16_t header_h = 36;
    ui_create_divider(scr_dashboard, header_h);

    // Reset orientation-specific widget pointers (a prior create could have
    // left stale globals from the opposite layout after orientation switch)
    bar_session = nullptr; bar_weekly = nullptr;
    arc_session = nullptr; arc_weekly = nullptr;

    if (landscape_layout) {
        // ---- Landscape: two filled-arc cells side by side ----
        int16_t cell_top = header_h + 2;
        int16_t cell_h   = (int16_t)sh - header_h - 2;
        int16_t cell_w   = sw / 2;
        int16_t arc_d    = cell_h - 40; // leaves room for title + reset
        if (arc_d < 90) arc_d = 90;
        if (arc_d > cell_w - 20) arc_d = cell_w - 20;

        int16_t left_cx  = cell_w / 2;
        int16_t right_cx = cell_w + cell_w / 2;

        create_arc_block(
            scr_dashboard, L(STR_SESSION),
            left_cx, cell_top, cell_w, cell_h, arc_d,
            &lbl_session_title, &arc_session, &lbl_session_pct, &lbl_session_reset
        );

        create_arc_block(
            scr_dashboard, L(STR_WEEKLY),
            right_cx, cell_top, cell_w, cell_h, arc_d,
            &lbl_weekly_title, &arc_weekly, &lbl_weekly_pct, &lbl_weekly_reset
        );
    } else {
        // ---- Portrait: unchanged bar layout ----
        const int16_t block_h       = 114;
        int16_t available_h         = (int16_t)sh - header_h;
        int16_t zone_h              = available_h / 2;
        int16_t session_y           = header_h + (zone_h - block_h) / 2;
        int16_t middle_divider_y    = header_h + zone_h;
        int16_t weekly_y            = middle_divider_y + (zone_h - block_h) / 2;

        create_usage_block(
            scr_dashboard, L(STR_SESSION),
            session_y,
            &lbl_session_title, &lbl_session_pct, &bar_session, &lbl_session_reset
        );

        ui_create_divider(scr_dashboard, middle_divider_y);

        create_usage_block(
            scr_dashboard, L(STR_WEEKLY),
            weekly_y,
            &lbl_weekly_title, &lbl_weekly_pct, &bar_weekly, &lbl_weekly_reset
        );
    }

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
    first_data_received = false;

    // ---- Splash overlay (covers full screen until first data) ----
    splash_overlay = lv_obj_create(scr_dashboard);
    lv_obj_set_size(splash_overlay, sw, sh);
    lv_obj_set_pos(splash_overlay, 0, 0);
    lv_obj_set_style_bg_color(splash_overlay, UI_COLOR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(splash_overlay, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_border_width(splash_overlay, 0, LV_PART_MAIN);
    lv_obj_clear_flag(splash_overlay, LV_OBJ_FLAG_SCROLLABLE);

    // Title: "AI Monitor"
    lv_obj_t *splash_title = lv_label_create(splash_overlay);
    lv_label_set_text(splash_title, L(STR_AI_MONITOR));
    lv_obj_set_style_text_color(splash_title, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(splash_title, &lv_font_montserrat_24, LV_PART_MAIN);
    lv_obj_align(splash_title, LV_ALIGN_CENTER, 0, -40);

    // Spinner
    splash_spinner = lv_spinner_create(splash_overlay);
    lv_obj_set_size(splash_spinner, 40, 40);
    lv_obj_align(splash_spinner, LV_ALIGN_CENTER, 0, 10);
    lv_spinner_set_anim_params(splash_spinner, 1000, 270);
    lv_obj_set_style_arc_color(splash_spinner, UI_COLOR_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_arc_color(splash_spinner, UI_COLOR_ACCENT, LV_PART_INDICATOR);
    lv_obj_set_style_arc_width(splash_spinner, 4, LV_PART_MAIN);
    lv_obj_set_style_arc_width(splash_spinner, 4, LV_PART_INDICATOR);

    // "Verbinde..." text
    lv_obj_t *splash_status = lv_label_create(splash_overlay);
    lv_label_set_text(splash_status, L(STR_CONNECTING));
    lv_obj_set_style_text_color(splash_status, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(splash_status, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(splash_status, LV_ALIGN_CENTER, 0, 50);

    Serial.println("[UI] Dashboard screen created (Vibe-TV-Style)");
}

// ============================================================
// Update dashboard with fresh MonitorState
// ============================================================
void ui_dashboard_update(const MonitorState &state) {
    if (!widgets_ready()) return;

    memcpy(&last_state, &state, sizeof(MonitorState));
    state_stored = true;

    // Hide splash overlay once we receive the first valid data
    if (!first_data_received && state.usage.valid && splash_overlay != nullptr) {
        first_data_received = true;
        lv_obj_delete(splash_overlay);
        splash_overlay = nullptr;
        splash_spinner = nullptr;
        Serial.println("[UI] Splash dismissed — first data received");
    }

    // ---- Provider name ----
    if (lbl_provider != nullptr) {
        lv_label_set_text(lbl_provider, state.provider == 1 ? "OPENAI" : "CLAUDE");
    }

    // ---- Clock (system time set via settimeofday from Mac's UTC) ----
    if (lbl_time != nullptr) {
        time_t now = time(nullptr);
        if (now > 1700000000) {  // system clock has been set (post-2023)
            struct tm local;
            localtime_r(&now, &local);
            char tbuf[6];
            strftime(tbuf, sizeof(tbuf), "%H:%M", &local);
            lv_label_set_text(lbl_time, tbuf);
        } else {
            lv_label_set_text(lbl_time, serial_get_display_time());
        }
    }

    // ---- Session + Weekly blocks ----
    if (state.usage.valid) {
        char buf[32];
        char reset_buf[48];

        // --- Session percent ---
        format_percentage(state.usage.five_hour_utilization, buf, sizeof(buf));
        lv_label_set_text(lbl_session_pct, buf);

        int s_val = (int)(state.usage.five_hour_utilization * 100.0f);
        if (s_val < 0) s_val = 0;
        if (s_val > 100) s_val = 100;
        lv_color_t session_color = ui_bar_color(state.usage.five_hour_utilization);

        if (landscape_layout && arc_session) {
            lv_arc_set_value(arc_session, s_val);
            lv_obj_set_style_arc_color(arc_session, session_color, LV_PART_INDICATOR);
            lv_obj_set_style_text_color(lbl_session_pct, UI_COLOR_TEXT, LV_PART_MAIN);
        } else if (bar_session) {
            lv_bar_set_value(bar_session, s_val, LV_ANIM_ON);
            lv_obj_set_style_bg_color(bar_session, session_color, LV_PART_INDICATOR);
        }

        // --- Session reset ---
        format_countdown_long(state.usage.five_hour_reset_epoch, buf, sizeof(buf));
        snprintf(reset_buf, sizeof(reset_buf), L(STR_RESETS_IN), buf);
        lv_label_set_text(lbl_session_reset, reset_buf);

        // --- Weekly percent ---
        format_percentage(state.usage.seven_day_utilization, buf, sizeof(buf));
        lv_label_set_text(lbl_weekly_pct, buf);

        int w_val = (int)(state.usage.seven_day_utilization * 100.0f);
        if (w_val < 0) w_val = 0;
        if (w_val > 100) w_val = 100;
        lv_color_t weekly_color = ui_bar_color(state.usage.seven_day_utilization);

        if (landscape_layout && arc_weekly) {
            lv_arc_set_value(arc_weekly, w_val);
            lv_obj_set_style_arc_color(arc_weekly, weekly_color, LV_PART_INDICATOR);
            lv_obj_set_style_text_color(lbl_weekly_pct, UI_COLOR_TEXT, LV_PART_MAIN);
        } else if (bar_weekly) {
            lv_bar_set_value(bar_weekly, w_val, LV_ANIM_ON);
            lv_obj_set_style_bg_color(bar_weekly, weekly_color, LV_PART_INDICATOR);
        }

        // --- Weekly reset (formatted target date for portrait; shorter
        //     countdown for landscape so it fits under the arc) ---
        char wbuf[48];
        if (landscape_layout) {
            format_countdown(state.usage.seven_day_reset_epoch, wbuf, sizeof(wbuf));
        } else {
            format_reset_date(state.usage.seven_day_reset_epoch, wbuf, sizeof(wbuf));
        }
        lv_label_set_text(lbl_weekly_reset, wbuf);

    } else if (strlen(state.usage.error) > 0) {
        lv_label_set_text(lbl_session_pct,   "ERR");
        lv_label_set_text(lbl_session_reset, state.usage.error);
        lv_label_set_text(lbl_weekly_pct,    "ERR");
        lv_label_set_text(lbl_weekly_reset,  "");
        if (bar_session) lv_bar_set_value(bar_session, 0, LV_ANIM_OFF);
        if (bar_weekly)  lv_bar_set_value(bar_weekly,  0, LV_ANIM_OFF);
        if (arc_session) lv_arc_set_value(arc_session, 0);
        if (arc_weekly)  lv_arc_set_value(arc_weekly,  0);
    }

    // ---- Header: connection status icon ----
    bool has_data = serial_has_recent_data();
    if (state.is_fetching) {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_FETCHING, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_REFRESH);
    } else if (has_data && state.usage.valid) {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_SUCCESS, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_OK);
    } else if (!has_data && state.usage.valid) {
        // Data exists but is stale (> 5 min) — orange
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_BAR_ORANGE, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_OK);
    } else {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_DUMMY);
    }
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

// ============================================================
// Recreate dashboard (theme change — destroy + create fresh)
// ============================================================
void ui_dashboard_recreate() {
    // Save current state
    MonitorState saved_state;
    bool had_state = state_stored;
    bool had_data  = first_data_received;
    if (had_state) {
        memcpy(&saved_state, &last_state, sizeof(MonitorState));
    }

    // Delete old screen
    if (scr_dashboard != nullptr) {
        lv_obj_delete(scr_dashboard);
        scr_dashboard      = nullptr;
        lbl_provider       = nullptr;
        lbl_time           = nullptr;
        lbl_session_title  = nullptr;
        lbl_session_pct    = nullptr;
        bar_session        = nullptr;
        arc_session        = nullptr;
        lbl_session_reset  = nullptr;
        lbl_weekly_title   = nullptr;
        lbl_weekly_pct     = nullptr;
        bar_weekly         = nullptr;
        arc_weekly         = nullptr;
        lbl_weekly_reset   = nullptr;
        lbl_status_dot     = nullptr;
        long_press_overlay = nullptr;
        splash_overlay     = nullptr;
        splash_spinner     = nullptr;
    }

    // Reset styles so they pick up new colors
    ui_styles_reset();

    // Recreate
    ui_dashboard_create();

    // Restore data state after create (create resets first_data_received)
    first_data_received = had_data;

    // If we already had data, skip splash and restore state
    if (had_data && splash_overlay != nullptr) {
        lv_obj_delete(splash_overlay);
        splash_overlay = nullptr;
        splash_spinner = nullptr;
    }

    // Load and update
    lv_obj_t *dash_scr = ui_dashboard_get_screen();
    if (dash_scr) {
        lv_screen_load(dash_scr);
    }
    if (had_state) {
        ui_dashboard_update(saved_state);
    }

    Serial.println("[UI] Dashboard recreated with new theme");
}
