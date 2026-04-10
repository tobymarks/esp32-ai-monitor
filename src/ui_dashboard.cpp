/**
 * UI Dashboard - Main screen showing provider usage cards
 *
 * Supports both orientations dynamically:
 *
 * Portrait (240x320):
 *   Header: 28px  (app name + time)
 *   Cards:  ~250px (two provider cards, ~110px each + gap)
 *   Footer: 42px  (total cost + status dot + refresh time)
 *
 * Landscape (320x240):
 *   Header: 28px  (app name + time)
 *   Cards:  ~166px (two provider cards, ~78px each + gap)
 *   Footer: 44px  (total cost + status dot + refresh time)
 *
 * Touch events:
 *   - Tap on provider card -> Detail screen
 *   - Long press (>1s) anywhere -> Settings screen
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

// ============================================================
// Screen and widget references (created once, updated in-place)
// ============================================================
static lv_obj_t *scr_dashboard = nullptr;

// Header
static lv_obj_t *lbl_time = nullptr;

// Anthropic card widgets
static lv_obj_t *card_anthropic     = nullptr;
static lv_obj_t *lbl_anth_name      = nullptr;
static lv_obj_t *lbl_anth_cost      = nullptr;
static lv_obj_t *bar_anth           = nullptr;
static lv_obj_t *lbl_anth_tokens    = nullptr;
static lv_obj_t *lbl_anth_today     = nullptr;
static lv_obj_t *lbl_anth_trend     = nullptr;

// OpenAI card widgets
static lv_obj_t *card_openai        = nullptr;
static lv_obj_t *lbl_oai_name       = nullptr;
static lv_obj_t *lbl_oai_cost       = nullptr;
static lv_obj_t *bar_oai            = nullptr;
static lv_obj_t *lbl_oai_tokens     = nullptr;
static lv_obj_t *lbl_oai_today      = nullptr;
static lv_obj_t *lbl_oai_trend      = nullptr;

// Footer
static lv_obj_t *lbl_total          = nullptr;
static lv_obj_t *lbl_status_dot     = nullptr;
static lv_obj_t *lbl_refresh        = nullptr;

// Last known state (for detail screen access)
static MonitorState last_state;
static bool state_stored = false;

// Long-press detection
static lv_obj_t *long_press_overlay = nullptr;

// ============================================================
// Event handlers
// ============================================================
static void on_anthropic_tap(lv_event_t *e) {
    (void)e;
    if (state_stored && last_state.anthropic.valid) {
        ui_detail_create("ANTHROPIC", last_state.anthropic, UI_COLOR_ANTHROPIC);
    }
}

static void on_openai_tap(lv_event_t *e) {
    (void)e;
    if (state_stored && last_state.openai.valid) {
        ui_detail_create("OPENAI", last_state.openai, UI_COLOR_OPENAI);
    }
}

static void on_long_press(lv_event_t *e) {
    (void)e;
    ui_settings_create();
    Serial.println("[UI] Long press -> Settings screen");
}

// ============================================================
// Helper: create one provider card
// Returns the card container; populates widget pointers
// ============================================================
static lv_obj_t* create_provider_card(
    lv_obj_t *parent,
    const char *name,
    lv_color_t brand_color,
    lv_obj_t **out_name_lbl,
    lv_obj_t **out_cost_lbl,
    lv_obj_t **out_bar,
    lv_obj_t **out_token_lbl,
    lv_obj_t **out_today_lbl,
    lv_obj_t **out_trend_lbl
) {
    // Dynamic sizing based on screen dimensions
    int16_t card_w = SCREEN_WIDTH - 16;  // 8px margin each side
    bool is_portrait = (SCREEN_WIDTH < SCREEN_HEIGHT);
    int16_t card_h = is_portrait ? 105 : 76;
    int16_t bar_w  = is_portrait ? (card_w - 80) : 196;
    int16_t tok_x  = bar_w + 8;

    // Card container
    lv_obj_t *card = ui_create_panel(parent);
    lv_obj_set_size(card, card_w, card_h);
    lv_obj_set_style_pad_all(card, 8, LV_PART_MAIN);
    lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);

    // Row 1: Provider name with down-arrow (left) + monthly cost (right)
    *out_name_lbl = lv_label_create(card);
    char name_buf[32];
    snprintf(name_buf, sizeof(name_buf), LV_SYMBOL_DOWN " %s", name);
    lv_label_set_text(*out_name_lbl, name_buf);
    lv_obj_set_style_text_color(*out_name_lbl, brand_color, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_name_lbl, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_set_pos(*out_name_lbl, 0, 0);

    *out_cost_lbl = lv_label_create(card);
    lv_label_set_text(*out_cost_lbl, "$0.00/mo");
    lv_obj_set_style_text_color(*out_cost_lbl, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_cost_lbl, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_align(*out_cost_lbl, LV_ALIGN_TOP_RIGHT, 0, 0);

    // Row 2: Progress bar + token count
    int16_t bar_y = is_portrait ? 28 : 24;
    *out_bar = ui_create_bar(card, brand_color);
    lv_obj_set_width(*out_bar, bar_w);
    lv_obj_set_pos(*out_bar, 0, bar_y);

    *out_token_lbl = lv_label_create(card);
    lv_label_set_text(*out_token_lbl, "0 tok");
    lv_obj_set_style_text_color(*out_token_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_token_lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(*out_token_lbl, tok_x, bar_y - 2);

    // Row 3: Today cost (left) + Trend placeholder (right)
    int16_t today_y = is_portrait ? 52 : 42;
    *out_today_lbl = lv_label_create(card);
    lv_label_set_text(*out_today_lbl, "Today: $0.00");
    lv_obj_set_style_text_color(*out_today_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_today_lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_pos(*out_today_lbl, 0, today_y);

    *out_trend_lbl = lv_label_create(card);
    lv_label_set_text(*out_trend_lbl, "");
    lv_obj_set_style_text_color(*out_trend_lbl, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_trend_lbl, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(*out_trend_lbl, LV_ALIGN_BOTTOM_RIGHT, 0, 0);

    return card;
}

// ============================================================
// Create dashboard screen (call once)
// ============================================================
void ui_dashboard_create() {
    ui_styles_init();

    // Clean up if called again
    if (scr_dashboard != nullptr) {
        return;  // Already created — just load it
    }

    bool is_portrait = (SCREEN_WIDTH < SCREEN_HEIGHT);
    int16_t sw = SCREEN_WIDTH;
    int16_t sh = SCREEN_HEIGHT;

    scr_dashboard = lv_obj_create(nullptr);
    lv_obj_set_style_bg_color(scr_dashboard, UI_COLOR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr_dashboard, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_clear_flag(scr_dashboard, LV_OBJ_FLAG_SCROLLABLE);

    // ---- Header bar (28px) ----
    lv_obj_t *header = lv_obj_create(scr_dashboard);
    lv_obj_set_size(header, sw, 28);
    lv_obj_set_pos(header, 0, 0);
    lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(header, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(header, 0, LV_PART_MAIN);
    lv_obj_clear_flag(header, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *lbl_title = lv_label_create(header);
    lv_label_set_text(lbl_title, is_portrait ? "AI MONITOR" : "AI USAGE MONITOR");
    lv_obj_set_style_text_color(lbl_title, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_title, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_set_pos(lbl_title, 8, 6);

    lbl_time = lv_label_create(header);
    lv_label_set_text(lbl_time, "--:--");
    lv_obj_set_style_text_color(lbl_time, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_time, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(lbl_time, LV_ALIGN_TOP_RIGHT, -8, 7);

    // ---- Divider under header ----
    ui_create_divider(scr_dashboard, 28);

    // ---- Layout calculations ----
    // Portrait: cards are taller (105px), with more vertical space
    // Landscape: cards are compact (76px), original layout
    int16_t card_h = is_portrait ? 105 : 76;
    int16_t card1_y = 32;
    int16_t card2_y = card1_y + card_h + 6;  // 6px gap between cards
    int16_t footer_h = 42;
    int16_t divider_y = sh - footer_h - 2;
    int16_t footer_y = sh - footer_h;

    // ---- Anthropic Card ----
    card_anthropic = create_provider_card(
        scr_dashboard, "ANTHROPIC", UI_COLOR_ANTHROPIC,
        &lbl_anth_name, &lbl_anth_cost, &bar_anth,
        &lbl_anth_tokens, &lbl_anth_today, &lbl_anth_trend
    );
    lv_obj_set_pos(card_anthropic, 8, card1_y);
    lv_obj_add_flag(card_anthropic, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(card_anthropic, on_anthropic_tap, LV_EVENT_CLICKED, nullptr);

    // ---- OpenAI Card ----
    card_openai = create_provider_card(
        scr_dashboard, "OPENAI", UI_COLOR_OPENAI,
        &lbl_oai_name, &lbl_oai_cost, &bar_oai,
        &lbl_oai_tokens, &lbl_oai_today, &lbl_oai_trend
    );
    lv_obj_set_pos(card_openai, 8, card2_y);
    lv_obj_add_flag(card_openai, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(card_openai, on_openai_tap, LV_EVENT_CLICKED, nullptr);

    // ---- Divider above footer ----
    ui_create_divider(scr_dashboard, divider_y);

    // ---- Footer ----
    lv_obj_t *footer = lv_obj_create(scr_dashboard);
    lv_obj_set_size(footer, sw, footer_h);
    lv_obj_set_pos(footer, 0, footer_y);
    lv_obj_set_style_bg_opa(footer, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(footer, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(footer, 0, LV_PART_MAIN);
    lv_obj_clear_flag(footer, LV_OBJ_FLAG_SCROLLABLE);

    // Footer left: TOTAL $xx.xx/mo
    lbl_total = lv_label_create(footer);
    lv_label_set_text(lbl_total, "TOTAL $0.00/mo");
    lv_obj_set_style_text_color(lbl_total, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_total, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_set_pos(lbl_total, 8, 10);

    // Footer center: status dot
    lbl_status_dot = lv_label_create(footer);
    lv_label_set_text(lbl_status_dot, LV_SYMBOL_DUMMY);
    lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_status_dot, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(lbl_status_dot, LV_ALIGN_TOP_MID, 10, 12);

    // Footer right: refresh time
    lbl_refresh = lv_label_create(footer);
    lv_label_set_text(lbl_refresh, "never");
    lv_obj_set_style_text_color(lbl_refresh, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_refresh, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(lbl_refresh, LV_ALIGN_TOP_RIGHT, -8, 12);

    // ---- Full-screen overlay for long-press detection ----
    long_press_overlay = lv_obj_create(scr_dashboard);
    lv_obj_set_size(long_press_overlay, sw, sh);
    lv_obj_set_pos(long_press_overlay, 0, 0);
    lv_obj_set_style_bg_opa(long_press_overlay, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(long_press_overlay, 0, LV_PART_MAIN);
    lv_obj_clear_flag(long_press_overlay, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(long_press_overlay, LV_OBJ_FLAG_CLICKABLE);
    // Only handle long-press; short clicks pass through to cards beneath
    lv_obj_add_flag(long_press_overlay, LV_OBJ_FLAG_CLICK_FOCUSABLE);
    lv_obj_add_event_cb(long_press_overlay, on_long_press, LV_EVENT_LONG_PRESSED, nullptr);
    // Move overlay to back so cards receive normal clicks
    lv_obj_move_to_index(long_press_overlay, 0);

    // Initialize last_state
    memset(&last_state, 0, sizeof(last_state));
    state_stored = false;

    Serial.printf("[UI] Dashboard screen created (v0.5.0, %s)\n",
                  is_portrait ? "portrait" : "landscape");
}

// ============================================================
// Helper: update one provider card
// ============================================================
static void update_card(
    const UsageData &data,
    lv_obj_t *cost_lbl,
    lv_obj_t *bar,
    lv_obj_t *token_lbl,
    lv_obj_t *today_lbl,
    lv_obj_t *trend_lbl,
    uint32_t max_month_tokens
) {
    char buf[32];
    char line[48];

    // Monthly cost
    format_cost(data.month_cost, buf, sizeof(buf));
    snprintf(line, sizeof(line), "%s/mo", buf);
    lv_label_set_text(cost_lbl, line);

    // Progress bar: proportional to max provider's monthly tokens
    uint32_t total_tokens = data.month_input_tokens + data.month_output_tokens;
    int32_t bar_val = 0;
    if (max_month_tokens > 0 && total_tokens > 0) {
        bar_val = (int32_t)((uint64_t)total_tokens * 100 / max_month_tokens);
        if (bar_val > 100) bar_val = 100;
    }
    lv_bar_set_value(bar, bar_val, LV_ANIM_ON);

    // Token count
    format_tokens(total_tokens, buf, sizeof(buf));
    snprintf(line, sizeof(line), "%s tok", buf);
    lv_label_set_text(token_lbl, line);

    // Today cost
    format_cost(data.today_cost, buf, sizeof(buf));
    snprintf(line, sizeof(line), "Today: %s", buf);
    lv_label_set_text(today_lbl, line);

    // Trend: leave empty for now (needs historical data to calculate)
    // Could show "↑ 15%" or "↓ 3%" vs 30-day average
    lv_label_set_text(trend_lbl, "");
}

// ============================================================
// Update dashboard with fresh data
// ============================================================
void ui_dashboard_update(const MonitorState &state) {
    if (scr_dashboard == nullptr) return;

    // Store state for detail screen access
    memcpy(&last_state, &state, sizeof(MonitorState));
    state_stored = true;

    // Update time
    if (lbl_time != nullptr) {
        String t = ntp_get_time();
        if (t.length() >= 5) {
            lv_label_set_text(lbl_time, t.substring(0, 5).c_str());
        }
    }

    // Calculate max tokens across both providers (for proportional bars)
    uint32_t anth_total = state.anthropic.month_input_tokens + state.anthropic.month_output_tokens;
    uint32_t oai_total  = state.openai.month_input_tokens + state.openai.month_output_tokens;
    uint32_t max_tokens = (anth_total > oai_total) ? anth_total : oai_total;
    if (max_tokens == 0) max_tokens = 1;

    // Update Anthropic card
    if (state.anthropic.valid) {
        update_card(state.anthropic, lbl_anth_cost, bar_anth,
                    lbl_anth_tokens, lbl_anth_today, lbl_anth_trend, max_tokens);
    } else if (strlen(state.anthropic.error) > 0) {
        lv_label_set_text(lbl_anth_cost, state.anthropic.error);
    }

    // Update OpenAI card
    if (state.openai.valid) {
        update_card(state.openai, lbl_oai_cost, bar_oai,
                    lbl_oai_tokens, lbl_oai_today, lbl_oai_trend, max_tokens);
    } else if (strlen(state.openai.error) > 0) {
        lv_label_set_text(lbl_oai_cost, state.openai.error);
    }

    // Update footer total
    char cost_buf[32];
    format_cost(state.total_month_cost, cost_buf, sizeof(cost_buf));
    char total_line[48];
    snprintf(total_line, sizeof(total_line), "TOTAL %s/mo", cost_buf);
    lv_label_set_text(lbl_total, total_line);

    // Update status dot
    bool online = wifi_is_connected();
    if (state.is_fetching) {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_FETCHING, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_REFRESH);
    } else if (online && (state.anthropic.valid || state.openai.valid)) {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_SUCCESS, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_OK);
    } else if (!online) {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_ERROR, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_CLOSE);
    } else {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_DUMMY);
    }

    // Update refresh time-ago
    // Use the most recent fetch time from either provider
    unsigned long latest_fetch = 0;
    if (state.anthropic.last_fetch > latest_fetch) latest_fetch = state.anthropic.last_fetch;
    if (state.openai.last_fetch > latest_fetch) latest_fetch = state.openai.last_fetch;

    char ago_buf[24];
    format_time_ago(latest_fetch, ago_buf, sizeof(ago_buf));
    char refresh_line[32];
    snprintf(refresh_line, sizeof(refresh_line), LV_SYMBOL_LOOP " %s", ago_buf);
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
