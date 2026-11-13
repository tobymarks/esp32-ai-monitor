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
 *   Long press  -> Settings screen
 */

#include "ui_dashboard.h"
#include "ui_common.h"
#include "ui_settings.h"
#include "config.h"
#include "providers.h"
#include "plugin_scene.h"
#include "plugin_scene_renderer.h"
#include "localization.h"
#include "serial_receiver.h"
#include "wifi_time.h"

#include <lvgl.h>
#include <ArduinoJson.h>
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <time.h>

LV_FONT_DECLARE(font_standby_clock_76);
#if defined(BOARD_S3_4848)
LV_FONT_DECLARE(font_standby_clock_160);
#endif

// ============================================================
// Widget references (created once, updated in-place)
// ============================================================
static lv_obj_t *scr_dashboard      = nullptr;

// Standard two-limit layout: landscape arcs or portrait bars.
// ChatGPT's single-limit ring works in both orientations.
static bool landscape_layout = false;
// Quadratisches Panel (Guition 4848S040, 480x480): Woche als grosser Ring,
// Sitzung als Balken darunter, jeweils mit Countdown und Reset-Zeitpunkt.
static bool square_layout = false;
// Ab diesem Verbrauch werden Ringe und Balken im quadratischen Layout orange.
static const int USAGE_WARN_PERCENT = 90;

// Header
static lv_obj_t *lbl_provider       = nullptr;
static lv_obj_t *lbl_time           = nullptr;
static lv_obj_t *pill_credits       = nullptr;   // v2.18.0: "+Cr" / "+238"
static lv_obj_t *pill_reset_credits = nullptr;   // v2.18.0: Reset Credits

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

// Nur im quadratischen Layout: absoluter Reset-Zeitpunkt ("Freitag, 14:00 Uhr")
static lv_obj_t *lbl_session_reset_abs = nullptr;
static lv_obj_t *lbl_weekly_reset_abs  = nullptr;
static lv_obj_t *lbl_single_reset_abs  = nullptr;

// ChatGPT with a single available limit: centered ring in either orientation.
static lv_obj_t *lbl_single_title   = nullptr;
static lv_obj_t *arc_single         = nullptr;
static lv_obj_t *lbl_single_pct     = nullptr;
static lv_obj_t *lbl_single_reset   = nullptr;

// Antigravity: 3 model rows (portrait bars OR landscape bars)
static const uint8_t AG_ROW_COUNT = 3;
static lv_obj_t *ag_title[AG_ROW_COUNT] = {nullptr, nullptr, nullptr};
static lv_obj_t *ag_pct[AG_ROW_COUNT]   = {nullptr, nullptr, nullptr};
static lv_obj_t *ag_bar[AG_ROW_COUNT]   = {nullptr, nullptr, nullptr};
static lv_obj_t *ag_reset[AG_ROW_COUNT] = {nullptr, nullptr, nullptr};

// Dividers that need runtime visibility toggles
static lv_obj_t *divider_middle = nullptr;

// ============================================================
// Tempo-Marken (alle Panels), Hero-Layout und grosse Zeilen (quadratisch)
// ============================================================
// Tempo-Marke: zeigt, wie viel vom Zeitfenster schon vergangen ist. Auf
// einem Balken ein senkrechter Strich, auf einem Ring ein radialer.
struct PaceTick {
    lv_obj_t *obj;
    bool ring;
    int16_t x, y;        // Balken: linke obere Ecke; Ring: Mittelpunkt
    int16_t len;         // Balken: Breite; Ring: Aussenradius
    int16_t thickness;   // Balken: Hoehe; Ring: Ringbreite
    lv_point_precise_t pts[2];
};

// Claude und ChatGPT mit drei Limits: das Limit mit dem laengsten Fenster
// als Ring, rechts daneben Reset und Tempo, die beiden anderen als Kacheln.
// Ein einzelnes Limit (ChatGPT nur mit Woche) nutzt dasselbe Layout, die
// Kacheln zeigen dann Prognose und Tagesbudget statt weiterer Limits.
struct HeroWidgets {
    lv_obj_t *group;
    lv_obj_t *arc;
    lv_obj_t *title;
    lv_obj_t *pct;
    lv_obj_t *reset_caption;
    lv_obj_t *reset;
    lv_obj_t *reset_abs;
    lv_obj_t *pace_dot;
    lv_obj_t *pace_lbl;
    lv_obj_t *pace_detail;
    PaceTick  tick;
    lv_obj_t *tile_title[2];
    lv_obj_t *tile_pct[2];
    lv_obj_t *tile_bar[2];
    lv_obj_t *tile_reset[2];
    PaceTick  tile_tick[2];
    lv_obj_t *info_value[2];
    lv_obj_t *info_caption[2];
    int16_t   info_value_mid;   // senkrechte Mitte der Info-Werte
};
static HeroWidgets hero = {};

// Uebrige Provider mit mehreren Zeilen: grosse Zeilen samt Trennlinien.
static lv_obj_t *rows_group = nullptr;
static PaceTick ag_tick[AG_ROW_COUNT] = {};
static PaceTick weekly_tick  = {};
static PaceTick session_tick = {};
static PaceTick single_tick  = {};

// Kopfzeile; im quadratischen Layout groesser (siehe ui_dashboard_create).
static int16_t header_h_px          = 36;
static int16_t header_side_reserve  = 52;   // WLAN/Status links, Uhr rechts
static int16_t status_icon_y        = 11;
static int16_t status_dot_x         = 30;
static const lv_font_t *pill_font   = &font_ui_12;

// Header status icon (connection indicator)
static lv_obj_t *lbl_wifi_status   = nullptr;
static lv_obj_t *lbl_status_dot     = nullptr;

// Last known state (for detail screen)
static MonitorState last_state;
static bool state_stored = false;

// Long-press overlay
static lv_obj_t *long_press_overlay = nullptr;
static uint32_t tap_press_started_ms = 0;
static int32_t tap_press_x = 0;

// Splash overlay (shown until first data arrives)
static lv_obj_t *splash_overlay     = nullptr;
static lv_obj_t *splash_spinner     = nullptr;
static bool       first_data_received = false;

// Standby overlay (shown when host data timed out but the display still has power)
static lv_obj_t *standby_overlay    = nullptr;
static lv_obj_t *standby_clock      = nullptr;
static lv_obj_t *standby_wifi       = nullptr;
static lv_obj_t *clock_overlay      = nullptr;
static lv_obj_t *clock_time         = nullptr;
static lv_obj_t *clock_date         = nullptr;
static lv_obj_t *plugin_overlay     = nullptr;
static uint8_t plugin_rendered_view = 0xFF;
static uint32_t plugin_rendered_revision = 0;
static bool long_press_handled = false;

// Placeholder row titles while the compact rows are created (before any
// frame arrived). At render time the titles come from the active provider.
static const char* ag_default_title(uint8_t idx) {
    return L_row_title(default_row_title_for_provider(PROVIDER_ANTIGRAVITY, idx));
}

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
             && lbl_single_title != nullptr
             && arc_single       != nullptr
             && lbl_single_pct   != nullptr
             && lbl_single_reset != nullptr
             && lbl_wifi_status  != nullptr
             && lbl_status_dot   != nullptr;
    if (!base) return false;
    // Je Limit gibt es entweder einen Bogen oder einen Balken — im
    // quadratischen Layout die Woche als Bogen und die Sitzung als Balken.
    return (arc_session != nullptr || bar_session != nullptr)
        && (arc_weekly != nullptr || bar_weekly != nullptr);
}

// ============================================================
// Event handlers
// ============================================================
static void on_press_start(lv_event_t *e) {
    lv_point_t point;
    lv_indev_get_point(lv_event_get_indev(e), &point);
    tap_press_x = point.x;
    tap_press_started_ms = lv_tick_get();
    long_press_handled = false;
}

static void on_long_press(lv_event_t *e) {
    (void)e;
    long_press_handled = true;
    uint32_t elapsed = lv_tick_elaps(tap_press_started_ms);
    Serial.printf("[UI] Long press (%lu ms) -> Settings\n", (unsigned long)elapsed);
    ui_settings_create();
}

static void on_tap_release(lv_event_t *e) {
    (void)e;
    if (long_press_handled || lv_tick_elaps(tap_press_started_ms) >= 800) return;
    if (tap_press_x < SCREEN_WIDTH / 2) serial_previous_view();
    else serial_next_view();
}

// Uhr und Standby: auf dem quadratischen Panel die grosse Ziffernschrift.
static const lv_font_t *clock_font() {
#if defined(BOARD_S3_4848)
    if (square_layout) return &font_standby_clock_160;
#endif
    return &font_standby_clock_76;
}

static void update_plugin_view() {
    uint8_t index = serial_active_view();
    const PluginSceneSlot *slot = plugin_scene_get(index);
    if (plugin_overlay && index == plugin_rendered_view && slot
        && slot->revision == plugin_rendered_revision) return;

    if (plugin_overlay) lv_obj_delete(plugin_overlay);
    plugin_overlay = lv_obj_create(scr_dashboard);
    lv_obj_remove_style_all(plugin_overlay);
    lv_obj_set_size(plugin_overlay, SCREEN_WIDTH, SCREEN_HEIGHT);
    lv_obj_set_style_bg_color(plugin_overlay, UI_COLOR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(plugin_overlay, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_add_flag(plugin_overlay, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(plugin_overlay, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(plugin_overlay, on_press_start, LV_EVENT_PRESSED, nullptr);
    lv_obj_add_event_cb(plugin_overlay, on_tap_release, LV_EVENT_RELEASED, nullptr);
    lv_obj_add_event_cb(plugin_overlay, on_long_press, LV_EVENT_LONG_PRESSED, nullptr);
    plugin_rendered_view = index;
    plugin_rendered_revision = slot ? slot->revision : 0;

    if (!slot || !slot->ready) {
        lv_obj_t *waiting = lv_label_create(plugin_overlay);
        lv_label_set_text(waiting, "Loading plugin view...");
        lv_obj_set_style_text_color(waiting, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
        lv_obj_set_style_text_font(waiting, &font_ui_16, LV_PART_MAIN);
        lv_obj_center(waiting);
        return;
    }

    JsonDocument doc;
    if (deserializeJson(doc, slot->json)) return; // validated at receive time
    plugin_scene_draw(plugin_overlay, doc.as<JsonObjectConst>(), SCREEN_WIDTH, SCREEN_HEIGHT);
}

static void update_clock_view() {
    if (!clock_overlay) {
        clock_overlay = lv_obj_create(scr_dashboard);
        lv_obj_remove_style_all(clock_overlay);
        lv_obj_set_size(clock_overlay, SCREEN_WIDTH, SCREEN_HEIGHT);
        lv_obj_set_style_bg_color(clock_overlay, UI_COLOR_BG, LV_PART_MAIN);
        lv_obj_set_style_bg_opa(clock_overlay, LV_OPA_COVER, LV_PART_MAIN);
        lv_obj_add_flag(clock_overlay, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_add_event_cb(clock_overlay, on_press_start, LV_EVENT_PRESSED, nullptr);
        lv_obj_add_event_cb(clock_overlay, on_tap_release, LV_EVENT_RELEASED, nullptr);
        lv_obj_add_event_cb(clock_overlay, on_long_press, LV_EVENT_LONG_PRESSED, nullptr);
        clock_time = lv_label_create(clock_overlay);
        lv_obj_set_width(clock_time, SCREEN_WIDTH);
        lv_obj_set_style_text_align(clock_time, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
        lv_obj_set_style_text_color(clock_time, UI_COLOR_TEXT, LV_PART_MAIN);
        lv_obj_set_style_text_font(clock_time, clock_font(), LV_PART_MAIN);
        lv_obj_set_style_text_letter_space(clock_time, square_layout ? 4 : 0, LV_PART_MAIN);
        lv_obj_align(clock_time, LV_ALIGN_CENTER, 0, square_layout ? -30 : -15);
        clock_date = lv_label_create(clock_overlay);
        lv_obj_set_width(clock_date, SCREEN_WIDTH);
        lv_obj_set_style_text_align(clock_date, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
        lv_obj_set_style_text_color(clock_date, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
        lv_obj_set_style_text_font(clock_date, square_layout ? &font_ui_36 : &font_ui_20,
                                   LV_PART_MAIN);
        lv_obj_align(clock_date, LV_ALIGN_CENTER, 0, square_layout ? 80 : 55);
    }
    char time_buf[6] = "--:--";
    char date_buf[20] = "";
    time_t now = time(nullptr);
    if (now > CLOCK_VALID_EPOCH) {
        struct tm local;
        localtime_r(&now, &local);
        strftime(time_buf, sizeof(time_buf), "%H:%M", &local);
        strftime(date_buf, sizeof(date_buf), "%d.%m.%Y", &local);
    } else {
        strlcpy(time_buf, serial_get_display_time(), sizeof(time_buf));
    }
    lv_label_set_text(clock_time, time_buf);
    lv_label_set_text(clock_date, date_buf);
    lv_obj_move_foreground(clock_overlay);
}

// ============================================================
// Standby clock overlay
// ============================================================
static void format_standby_clock(char *buf, size_t len) {
    time_t now = time(nullptr);
    if (now > CLOCK_VALID_EPOCH) {  // system clock + timezone offset have been set by the Mac frame
        struct tm local;
        localtime_r(&now, &local);
        strftime(buf, len, "%H:%M", &local);
        return;
    }

    const char *fallback = serial_get_display_time();
    if (fallback && fallback[0] != '\0') {
        strlcpy(buf, fallback, len);
    } else {
        strlcpy(buf, "--:--", len);
    }
}

static void update_standby_clock() {
    if (standby_clock == nullptr) return;

    char tbuf[6];
    format_standby_clock(tbuf, sizeof(tbuf));
    lv_label_set_text(standby_clock, tbuf);

    if (standby_wifi != nullptr) {
        lv_label_set_text(standby_wifi, wifi_time_is_connected() ? LV_SYMBOL_WIFI : LV_SYMBOL_DUMMY);
    }
}

static void hide_standby_overlay() {
    if (standby_overlay == nullptr) return;

    lv_obj_delete(standby_overlay);
    standby_overlay = nullptr;
    standby_clock = nullptr;
    standby_wifi = nullptr;
    Serial.println("[UI] Standby clock hidden — fresh host data received");
}

static void show_standby_overlay() {
    if (standby_overlay != nullptr) {
        update_standby_clock();
        return;
    }
    if (scr_dashboard == nullptr) return;

    standby_overlay = lv_obj_create(scr_dashboard);
    lv_obj_remove_style_all(standby_overlay);
    lv_obj_set_size(standby_overlay, SCREEN_WIDTH, SCREEN_HEIGHT);
    lv_obj_set_pos(standby_overlay, 0, 0);
    lv_obj_set_style_bg_color(standby_overlay, lv_color_black(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(standby_overlay, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_border_width(standby_overlay, 0, LV_PART_MAIN);
    lv_obj_set_style_outline_width(standby_overlay, 0, LV_PART_MAIN);
    lv_obj_set_style_shadow_width(standby_overlay, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(standby_overlay, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(standby_overlay, 0, LV_PART_MAIN);
    lv_obj_clear_flag(standby_overlay, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(standby_overlay, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(standby_overlay, on_press_start, LV_EVENT_PRESSED, nullptr);
    lv_obj_add_event_cb(standby_overlay, on_tap_release, LV_EVENT_RELEASED, nullptr);
    lv_obj_add_event_cb(standby_overlay, on_long_press, LV_EVENT_LONG_PRESSED, nullptr);

    standby_wifi = lv_label_create(standby_overlay);
    lv_label_set_text(standby_wifi, LV_SYMBOL_DUMMY);
    lv_obj_set_style_text_color(standby_wifi, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(standby_wifi, square_layout ? &font_ui_20 : &font_ui_14,
                               LV_PART_MAIN);
    lv_obj_set_pos(standby_wifi, 8, status_icon_y);

    standby_clock = lv_label_create(standby_overlay);
    lv_obj_set_width(standby_clock, SCREEN_WIDTH);
    lv_obj_set_style_text_align(standby_clock, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_obj_set_style_text_color(standby_clock, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(standby_clock, clock_font(), LV_PART_MAIN);
    lv_obj_set_style_text_letter_space(standby_clock, square_layout ? 4 : 2, LV_PART_MAIN);
    lv_label_set_long_mode(standby_clock, LV_LABEL_LONG_CLIP);
    update_standby_clock();
    lv_obj_align(standby_clock, LV_ALIGN_CENTER, 0, 0);

    lv_obj_move_foreground(standby_overlay);
    Serial.println("[UI] Standby clock shown — host data timed out");
}

// ============================================================
// Tempo-Marke (alle Panels) und Warnfarbe (nur quadratisches Layout)
// ============================================================
// Wie weit die Marke ueber den Balken hinausragt. Die duennen CYD-Zeilen
// haben den Titel direkt darueber, dort nur knapp.
static int16_t bar_tick_overhang(int16_t bar_h) {
    if (square_layout) return 5;
    return bar_h <= 8 ? 2 : 3;
}

static void pace_tick_create_bar(PaceTick &t, lv_obj_t *parent,
                                 int16_t x, int16_t y, int16_t w, int16_t h) {
    t = {};
    t.x = x;
    t.y = y;
    t.len = w;
    t.thickness = h;
    t.obj = lv_obj_create(parent);
    lv_obj_remove_style_all(t.obj);
    // Auf den kleinen CYD-Panels schmaler und kuerzer
    lv_obj_set_size(t.obj, square_layout ? 3 : 2, h + 2 * bar_tick_overhang(h));
    lv_obj_set_style_bg_color(t.obj, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(t.obj, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(t.obj, 1, LV_PART_MAIN);
    lv_obj_add_flag(t.obj, LV_OBJ_FLAG_HIDDEN);
}

static void pace_tick_create_ring(PaceTick &t, lv_obj_t *parent,
                                  int16_t cx, int16_t cy, int16_t r_outer, int16_t ring_w) {
    t = {};
    t.ring = true;
    t.x = cx;
    t.y = cy;
    t.len = r_outer;
    t.thickness = ring_w;
    t.obj = lv_line_create(parent);
    lv_obj_set_style_line_color(t.obj, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_line_width(t.obj, square_layout ? 4 : 3, LV_PART_MAIN);
    lv_obj_set_pos(t.obj, 0, 0);
    lv_obj_add_flag(t.obj, LV_OBJ_FLAG_HIDDEN);
}

// pos: Stelle 0..1 auf der angezeigten Skala; negativ blendet die Marke aus.
static void pace_tick_set(PaceTick &t, float pos) {
    if (t.obj == nullptr) return;
    if (pos < 0.0f) {
        lv_obj_add_flag(t.obj, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    if (pos > 1.0f) pos = 1.0f;
    if (t.ring) {
        // Der Ring beginnt bei 12 Uhr (Rotation 270) und laeuft im Uhrzeigersinn.
        const float a = (270.0f + pos * 360.0f) * 3.14159265f / 180.0f;
        const float c = cosf(a);
        const float sn = sinf(a);
        const float over = square_layout ? 4.0f : 3.0f;
        const float r_in = (float)(t.len - t.thickness) - over;
        const float r_out = (float)t.len + over;
        t.pts[0].x = (lv_value_precise_t)(t.x + c * r_in);
        t.pts[0].y = (lv_value_precise_t)(t.y + sn * r_in);
        t.pts[1].x = (lv_value_precise_t)(t.x + c * r_out);
        t.pts[1].y = (lv_value_precise_t)(t.y + sn * r_out);
        lv_line_set_points(t.obj, t.pts, 2);
    } else {
        lv_obj_set_pos(t.obj, t.x + (int16_t)(pos * t.len + 0.5f) - 1, t.y - bar_tick_overhang(t.thickness));
    }
    lv_obj_clear_flag(t.obj, LV_OBJ_FLAG_HIDDEN);
}

static void pace_tick_hide(PaceTick &t) {
    if (t.obj != nullptr) lv_obj_add_flag(t.obj, LV_OBJ_FLAG_HIDDEN);
}

// Anteil des Zeitfensters, der schon vergangen ist (0..1); -1 = unbekannt.
static float window_elapsed(time_t reset_epoch, uint32_t window_minutes) {
    if (reset_epoch <= 0 || window_minutes == 0) return -1.0f;
    const time_t now = time(nullptr);
    if (now <= CLOCK_VALID_EPOCH) return -1.0f;
    const float window_s = (float)window_minutes * 60.0f;
    float left = (float)(reset_epoch - now);
    if (left < 0.0f) left = 0.0f;
    // Reset liegt weiter weg als das Fenster lang ist: lieber keine Marke.
    if (left > window_s) return -1.0f;
    return 1.0f - left / window_s;
}

// Zeigt der Host verbleibende Prozent, laeuft die Skala rueckwaerts: die
// Marke steht dann beim Rest der Zeit, und der Verbrauch ist 1 - Anzeige.
static float pace_position(float elapsed, bool shows_remaining) {
    if (elapsed < 0.0f) return -1.0f;
    return shows_remaining ? 1.0f - elapsed : elapsed;
}

static float used_fraction(float shown, bool shows_remaining) {
    return shows_remaining ? 1.0f - shown : shown;
}

static lv_color_t square_usage_color(uint8_t provider, float shown, bool shows_remaining) {
    const int used_pct = (int)(used_fraction(shown, shows_remaining) * 100.0f + 0.5f);
    return used_pct >= USAGE_WARN_PERCENT ? UI_COLOR_BAR_ORANGE : ui_bar_color(provider);
}

static int clamp_percent(float fraction) {
    int val = (int)(fraction * 100.0f);
    if (val < 0) val = 0;
    if (val > 100) val = 100;
    return val;
}

static lv_obj_t *create_square_bar(lv_obj_t *parent, int16_t x, int16_t y, int16_t w, int16_t h) {
    lv_obj_t *bar = lv_bar_create(parent);
    lv_obj_set_size(bar, w, h);
    lv_obj_set_pos(bar, x, y);
    lv_bar_set_range(bar, 0, 100);
    lv_bar_set_value(bar, 0, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(bar, UI_COLOR_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(bar, h / 2, LV_PART_MAIN);
    lv_obj_set_style_bg_color(bar, ui_bar_color(PROVIDER_CLAUDE), LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, LV_PART_INDICATOR);
    lv_obj_set_style_radius(bar, h / 2, LV_PART_INDICATOR);
    return bar;
}

static lv_obj_t *create_square_label(lv_obj_t *parent, const lv_font_t *font, lv_color_t color,
                                     int16_t x, int16_t y, int16_t w) {
    lv_obj_t *lbl = lv_label_create(parent);
    lv_label_set_text(lbl, "");
    lv_obj_set_style_text_font(lbl, font, LV_PART_MAIN);
    lv_obj_set_style_text_color(lbl, color, LV_PART_MAIN);
    lv_obj_set_pos(lbl, x, y);
    if (w > 0) {
        lv_obj_set_width(lbl, w);
        lv_label_set_long_mode(lbl, LV_LABEL_LONG_DOT);
    }
    return lbl;
}

// Unsichtbarer Vollbild-Container, damit eine Ansicht als Ganzes umschaltet.
static lv_obj_t *create_square_group(lv_obj_t *parent) {
    lv_obj_t *group = lv_obj_create(parent);
    lv_obj_remove_style_all(group);
    lv_obj_set_size(group, SCREEN_WIDTH, SCREEN_HEIGHT);
    lv_obj_set_pos(group, 0, 0);
    lv_obj_clear_flag(group, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(group, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(group, LV_OBJ_FLAG_HIDDEN);
    return group;
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
    lv_obj_t **out_reset_lbl,
    PaceTick *out_tick
) {
    int16_t sw = SCREEN_WIDTH;
    int16_t bar_w = sw - 24;

    *out_title_lbl = lv_label_create(parent);
    lv_label_set_text(*out_title_lbl, title);
    lv_obj_set_style_text_color(*out_title_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_title_lbl, &font_ui_14, LV_PART_MAIN);
    lv_obj_set_pos(*out_title_lbl, 0, y_start);
    lv_obj_set_width(*out_title_lbl, sw);
    lv_obj_set_style_text_align(*out_title_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    *out_pct_lbl = lv_label_create(parent);
    lv_label_set_text(*out_pct_lbl, "--%");
    lv_obj_set_style_text_color(*out_pct_lbl, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_pct_lbl, &font_ui_48, LV_PART_MAIN);
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
    lv_obj_set_style_bg_color(*out_bar, ui_bar_color(PROVIDER_CLAUDE), LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(*out_bar, LV_OPA_COVER, LV_PART_INDICATOR);
    lv_obj_set_style_radius(*out_bar, 6, LV_PART_INDICATOR);
    pace_tick_create_bar(*out_tick, parent, 12, y_start + 76, bar_w, 12);

    *out_reset_lbl = lv_label_create(parent);
    char reset_buf[32];
    snprintf(reset_buf, sizeof(reset_buf), L(STR_RESETS_IN), "--");
    lv_label_set_text(*out_reset_lbl, reset_buf);
    lv_obj_set_style_text_color(*out_reset_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_reset_lbl, &font_ui_12, LV_PART_MAIN);
    lv_obj_set_pos(*out_reset_lbl, 0, y_start + 94);
    lv_obj_set_width(*out_reset_lbl, sw);
    lv_obj_set_style_text_align(*out_reset_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    return y_start + 114;
}

// ============================================================
// Helper: create an arc block (title + arc w/ pct inside + reset)
// Center horizontally at cx and vertically within cell_top/cell_h.
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
    lv_obj_t **out_reset_lbl,
    PaceTick *out_tick
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
    lv_obj_set_style_text_font(*out_title_lbl, &font_ui_14, LV_PART_MAIN);
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
    lv_obj_set_style_arc_color(*out_arc, ui_bar_color(PROVIDER_CLAUDE), LV_PART_INDICATOR);
    lv_obj_set_style_arc_opa(*out_arc, LV_OPA_COVER, LV_PART_INDICATOR);
    pace_tick_create_ring(*out_tick, parent, cx, arc_y + arc_diameter / 2, arc_diameter / 2, 14);

    // Percent in arc centre
    *out_pct_lbl = lv_label_create(parent);
    lv_label_set_text(*out_pct_lbl, "--%");
    lv_obj_set_style_text_color(*out_pct_lbl, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_pct_lbl, &font_ui_24, LV_PART_MAIN);
    int16_t pct_w = arc_diameter - 34;
    if (pct_w < 72) pct_w = 72;
    lv_obj_set_width(*out_pct_lbl, pct_w);
    lv_obj_set_style_text_align(*out_pct_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_label_set_long_mode(*out_pct_lbl, LV_LABEL_LONG_CLIP);
    // Centre the label on the arc centre (arc origin + radius)
    lv_obj_align_to(*out_pct_lbl, *out_arc, LV_ALIGN_CENTER, 0, 0);

    // Reset time under the arc
    *out_reset_lbl = lv_label_create(parent);
    lv_label_set_text(*out_reset_lbl, "--");
    lv_obj_set_style_text_color(*out_reset_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_reset_lbl, &font_ui_12, LV_PART_MAIN);
    lv_obj_set_width(*out_reset_lbl, cell_w);
    lv_obj_set_pos(*out_reset_lbl, cx - cell_w / 2, reset_y);
    lv_obj_set_style_text_align(*out_reset_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_label_set_long_mode(*out_reset_lbl, LV_LABEL_LONG_DOT);
}

// ============================================================
// Quadratisches Layout: grosser Ring mit Titel, Prozent und Countdown im
// Inneren, darunter der absolute Reset-Zeitpunkt.
// ============================================================
static void create_big_ring(
    lv_obj_t *parent,
    const char *title,
    int16_t cx,
    int16_t top,
    int16_t diameter,
    lv_obj_t **out_title_lbl,
    lv_obj_t **out_arc,
    lv_obj_t **out_pct_lbl,
    lv_obj_t **out_reset_lbl,
    lv_obj_t **out_reset_abs_lbl,
    PaceTick *out_tick
) {
    const int16_t inner_w = diameter - 70;
    const int16_t ring_w = 24;

    *out_arc = lv_arc_create(parent);
    lv_obj_set_size(*out_arc, diameter, diameter);
    lv_obj_set_pos(*out_arc, cx - diameter / 2, top);
    lv_arc_set_rotation(*out_arc, 270);       // start at 12 o'clock
    lv_arc_set_bg_angles(*out_arc, 0, 360);
    lv_arc_set_range(*out_arc, 0, 100);
    lv_arc_set_value(*out_arc, 0);
    lv_obj_remove_style(*out_arc, NULL, LV_PART_KNOB);
    lv_obj_clear_flag(*out_arc, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_style_arc_width(*out_arc, ring_w, LV_PART_MAIN);
    lv_obj_set_style_arc_color(*out_arc, UI_COLOR_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_arc_opa(*out_arc, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_arc_width(*out_arc, ring_w, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(*out_arc, ui_bar_color(PROVIDER_CLAUDE), LV_PART_INDICATOR);
    lv_obj_set_style_arc_opa(*out_arc, LV_OPA_COVER, LV_PART_INDICATOR);
    pace_tick_create_ring(*out_tick, parent, cx, top + diameter / 2, diameter / 2, ring_w);

    *out_title_lbl = lv_label_create(parent);
    lv_label_set_text(*out_title_lbl, title);
    lv_obj_set_style_text_color(*out_title_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_title_lbl, &font_ui_20, LV_PART_MAIN);
    lv_obj_set_width(*out_title_lbl, inner_w);
    lv_obj_set_style_text_align(*out_title_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_label_set_long_mode(*out_title_lbl, LV_LABEL_LONG_DOT);
    lv_obj_align_to(*out_title_lbl, *out_arc, LV_ALIGN_CENTER, 0, -52);

    *out_pct_lbl = lv_label_create(parent);
    lv_label_set_text(*out_pct_lbl, "--%");
    lv_obj_set_style_text_color(*out_pct_lbl, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_pct_lbl, &font_ui_48, LV_PART_MAIN);
    lv_obj_set_width(*out_pct_lbl, inner_w);
    lv_obj_set_style_text_align(*out_pct_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_label_set_long_mode(*out_pct_lbl, LV_LABEL_LONG_CLIP);
    lv_obj_align_to(*out_pct_lbl, *out_arc, LV_ALIGN_CENTER, 0, 0);

    *out_reset_lbl = lv_label_create(parent);
    lv_label_set_text(*out_reset_lbl, "--");
    lv_obj_set_style_text_color(*out_reset_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_reset_lbl, &font_ui_20, LV_PART_MAIN);
    lv_obj_set_width(*out_reset_lbl, inner_w);
    lv_obj_set_style_text_align(*out_reset_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_label_set_long_mode(*out_reset_lbl, LV_LABEL_LONG_DOT);
    lv_obj_align_to(*out_reset_lbl, *out_arc, LV_ALIGN_CENTER, 0, 52);

    *out_reset_abs_lbl = lv_label_create(parent);
    lv_label_set_text(*out_reset_abs_lbl, "");
    lv_obj_set_style_text_color(*out_reset_abs_lbl, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(*out_reset_abs_lbl, &font_ui_16, LV_PART_MAIN);
    lv_obj_set_width(*out_reset_abs_lbl, diameter + 80);
    lv_obj_set_style_text_align(*out_reset_abs_lbl, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_label_set_long_mode(*out_reset_abs_lbl, LV_LABEL_LONG_DOT);
    lv_obj_set_pos(*out_reset_abs_lbl, cx - (diameter + 80) / 2, top + diameter + 8);
}

// Quadratisches Layout: Sitzung als breiter Balken. Oben Titel links und
// Prozent rechts, unten Countdown links und Reset-Zeitpunkt rechts.
static void create_session_strip(lv_obj_t *parent, int16_t x, int16_t y, int16_t w) {
    lbl_session_title = lv_label_create(parent);
    lv_label_set_text(lbl_session_title, L(STR_SESSION));
    lv_obj_set_style_text_color(lbl_session_title, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_session_title, &font_ui_20, LV_PART_MAIN);
    lv_obj_set_pos(lbl_session_title, x, y + 10);

    lbl_session_pct = lv_label_create(parent);
    lv_label_set_text(lbl_session_pct, "--%");
    lv_obj_set_style_text_color(lbl_session_pct, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_session_pct, &font_ui_36, LV_PART_MAIN);
    lv_obj_set_width(lbl_session_pct, w / 2);
    lv_obj_set_style_text_align(lbl_session_pct, LV_TEXT_ALIGN_RIGHT, LV_PART_MAIN);
    lv_obj_set_pos(lbl_session_pct, x + w / 2, y);

    bar_session = lv_bar_create(parent);
    lv_obj_set_size(bar_session, w, 18);
    lv_obj_set_pos(bar_session, x, y + 48);
    lv_bar_set_range(bar_session, 0, 100);
    lv_bar_set_value(bar_session, 0, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(bar_session, UI_COLOR_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(bar_session, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(bar_session, 9, LV_PART_MAIN);
    lv_obj_set_style_bg_color(bar_session, ui_bar_color(PROVIDER_CLAUDE), LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(bar_session, LV_OPA_COVER, LV_PART_INDICATOR);
    lv_obj_set_style_radius(bar_session, 9, LV_PART_INDICATOR);
    pace_tick_create_bar(session_tick, parent, x, y + 48, w, 18);

    lbl_session_reset = lv_label_create(parent);
    lv_label_set_text(lbl_session_reset, "--");
    lv_obj_set_style_text_color(lbl_session_reset, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_session_reset, &font_ui_16, LV_PART_MAIN);
    lv_obj_set_width(lbl_session_reset, w / 2);
    lv_label_set_long_mode(lbl_session_reset, LV_LABEL_LONG_DOT);
    lv_obj_set_pos(lbl_session_reset, x, y + 76);

    lbl_session_reset_abs = lv_label_create(parent);
    lv_label_set_text(lbl_session_reset_abs, "");
    lv_obj_set_style_text_color(lbl_session_reset_abs, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_session_reset_abs, &font_ui_16, LV_PART_MAIN);
    lv_obj_set_width(lbl_session_reset_abs, w / 2);
    lv_obj_set_style_text_align(lbl_session_reset_abs, LV_TEXT_ALIGN_RIGHT, LV_PART_MAIN);
    lv_label_set_long_mode(lbl_session_reset_abs, LV_LABEL_LONG_DOT);
    lv_obj_set_pos(lbl_session_reset_abs, x + w / 2, y + 76);
}

static void create_antigravity_row(
    lv_obj_t *parent,
    uint8_t idx,
    int16_t x,
    int16_t y,
    int16_t row_w,
    bool compact
) {
    if (idx >= AG_ROW_COUNT) return;

    const int16_t pad = 8;
    const int16_t title_y = 4;
    const int16_t bar_y = compact ? 20 : 24;
    const int16_t meta_y = compact ? 33 : 40;
    const int16_t bar_h = 8;
    const int16_t bar_w = row_w - (pad * 2);
    const lv_font_t *title_font = &font_ui_14;
    const lv_font_t *meta_font  = &font_ui_12;

    ag_title[idx] = lv_label_create(parent);
    lv_label_set_text(ag_title[idx], ag_default_title(idx));
    lv_obj_set_style_text_color(ag_title[idx], UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(ag_title[idx], title_font, LV_PART_MAIN);
    lv_obj_set_pos(ag_title[idx], x + pad, y + title_y);

    ag_bar[idx] = lv_bar_create(parent);
    lv_obj_set_size(ag_bar[idx], bar_w, bar_h);
    lv_obj_set_pos(ag_bar[idx], x + pad, y + bar_y);
    lv_bar_set_range(ag_bar[idx], 0, 100);
    lv_bar_set_value(ag_bar[idx], 0, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(ag_bar[idx], UI_COLOR_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(ag_bar[idx], LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(ag_bar[idx], bar_h / 2, LV_PART_MAIN);
    lv_obj_set_style_bg_color(ag_bar[idx], UI_COLOR_ANTIGRAVITY, LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(ag_bar[idx], LV_OPA_COVER, LV_PART_INDICATOR);
    lv_obj_set_style_radius(ag_bar[idx], bar_h / 2, LV_PART_INDICATOR);
    pace_tick_create_bar(ag_tick[idx], parent, x + pad, y + bar_y, bar_w, bar_h);

    ag_pct[idx] = lv_label_create(parent);
    lv_label_set_text(ag_pct[idx], "--%");
    lv_obj_set_style_text_color(ag_pct[idx], UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(ag_pct[idx], meta_font, LV_PART_MAIN);
    lv_obj_set_width(ag_pct[idx], bar_w / 2);
    lv_obj_set_pos(ag_pct[idx], x + pad, y + meta_y);
    lv_obj_set_style_text_align(ag_pct[idx], LV_TEXT_ALIGN_LEFT, LV_PART_MAIN);

    ag_reset[idx] = lv_label_create(parent);
    lv_label_set_text(ag_reset[idx], "--");
    lv_obj_set_style_text_color(ag_reset[idx], UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(ag_reset[idx], meta_font, LV_PART_MAIN);
    lv_obj_set_width(ag_reset[idx], bar_w / 2);
    lv_obj_set_pos(ag_reset[idx], x + pad + (bar_w / 2), y + meta_y);
    lv_obj_set_style_text_align(ag_reset[idx], LV_TEXT_ALIGN_RIGHT, LV_PART_MAIN);
    lv_label_set_long_mode(ag_reset[idx], LV_LABEL_LONG_DOT);
}

// ============================================================
// Quadratisch, drei Limits bei Claude/ChatGPT: Ring plus zwei Kacheln
// ============================================================
static void create_square_hero(lv_obj_t *parent, int16_t header_h) {
    hero.group = create_square_group(parent);
    lv_obj_t *g = hero.group;
    const int16_t sw = SCREEN_WIDTH;
    const int16_t sh = SCREEN_HEIGHT;

    const int16_t d = 216;
    const int16_t ring_w = 22;
    const int16_t ring_x = 24;
    const int16_t ring_y = header_h + 14;

    hero.arc = lv_arc_create(g);
    lv_obj_set_size(hero.arc, d, d);
    lv_obj_set_pos(hero.arc, ring_x, ring_y);
    lv_arc_set_rotation(hero.arc, 270);       // start at 12 o'clock
    lv_arc_set_bg_angles(hero.arc, 0, 360);
    lv_arc_set_range(hero.arc, 0, 100);
    lv_arc_set_value(hero.arc, 0);
    lv_obj_remove_style(hero.arc, NULL, LV_PART_KNOB);
    lv_obj_clear_flag(hero.arc, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_style_arc_width(hero.arc, ring_w, LV_PART_MAIN);
    lv_obj_set_style_arc_color(hero.arc, UI_COLOR_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_arc_opa(hero.arc, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_arc_width(hero.arc, ring_w, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(hero.arc, ui_bar_color(PROVIDER_CLAUDE), LV_PART_INDICATOR);
    lv_obj_set_style_arc_opa(hero.arc, LV_OPA_COVER, LV_PART_INDICATOR);
    pace_tick_create_ring(hero.tick, g, ring_x + d / 2, ring_y + d / 2, d / 2, ring_w);

    hero.title = create_square_label(g, &font_ui_20, UI_COLOR_TEXT_SEC, 0, 0, d - 64);
    lv_obj_set_style_text_align(hero.title, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_obj_align_to(hero.title, hero.arc, LV_ALIGN_CENTER, 0, -44);

    hero.pct = create_square_label(g, &font_ui_48, UI_COLOR_TEXT, 0, 0, d - 50);
    lv_label_set_long_mode(hero.pct, LV_LABEL_LONG_CLIP);
    lv_obj_set_style_text_align(hero.pct, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_obj_align_to(hero.pct, hero.arc, LV_ALIGN_CENTER, 0, 10);

    // Rechte Spalte: Reset und Tempo
    const int16_t col_x = ring_x + d + 24;
    const int16_t col_w = sw - col_x - 12;
    hero.reset_caption = create_square_label(g, &font_ui_16, UI_COLOR_TEXT_SEC,
                                             col_x, ring_y + 22, col_w);
    hero.reset = create_square_label(g, &font_ui_24, UI_COLOR_TEXT,
                                     col_x, ring_y + 44, col_w);
    hero.reset_abs = create_square_label(g, &font_ui_16, UI_COLOR_TEXT_SEC,
                                         col_x, ring_y + 78, col_w);

    hero.pace_dot = lv_obj_create(g);
    lv_obj_remove_style_all(hero.pace_dot);
    lv_obj_set_size(hero.pace_dot, 12, 12);
    lv_obj_set_pos(hero.pace_dot, col_x, ring_y + 128);
    lv_obj_set_style_radius(hero.pace_dot, LV_RADIUS_CIRCLE, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(hero.pace_dot, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_bg_color(hero.pace_dot, UI_COLOR_SUCCESS, LV_PART_MAIN);
    hero.pace_lbl = create_square_label(g, &font_ui_20, UI_COLOR_TEXT,
                                        col_x + 20, ring_y + 122, col_w - 20);
    hero.pace_detail = create_square_label(g, &font_ui_14, UI_COLOR_TEXT_SEC,
                                           col_x, ring_y + 152, col_w);

    // Zwei Kacheln fuer die uebrigen Limits
    const int16_t tile_y = ring_y + d + 14;
    const int16_t tile_h = sh - tile_y - 16;
    const int16_t tile_w = (sw - 48) / 2;
    const int16_t inner_w = tile_w - 32;
    for (uint8_t t = 0; t < 2; t++) {
        const int16_t x = 16 + t * (tile_w + 16);
        lv_obj_t *tile = lv_obj_create(g);
        lv_obj_remove_style_all(tile);
        lv_obj_set_size(tile, tile_w, tile_h);
        lv_obj_set_pos(tile, x, tile_y);
        lv_obj_set_style_bg_color(tile, UI_COLOR_PANEL, LV_PART_MAIN);
        lv_obj_set_style_bg_opa(tile, LV_OPA_COVER, LV_PART_MAIN);
        lv_obj_set_style_radius(tile, 16, LV_PART_MAIN);
        lv_obj_clear_flag(tile, LV_OBJ_FLAG_CLICKABLE);

        hero.tile_title[t] = create_square_label(g, &font_ui_20, UI_COLOR_TEXT_SEC,
                                                 x + 16, tile_y + 14, inner_w);
        hero.tile_pct[t] = create_square_label(g, &font_ui_48, UI_COLOR_TEXT,
                                               x + 16, tile_y + 40, 0);
        hero.tile_bar[t] = create_square_bar(g, x + 16, tile_y + 104, inner_w, 14);
        pace_tick_create_bar(hero.tile_tick[t], g, x + 16, tile_y + 104, inner_w, 14);
        hero.tile_reset[t] = create_square_label(g, &font_ui_16, UI_COLOR_TEXT_SEC,
                                                 x + 16, tile_y + 130, inner_w);

        // Info-Kachel bei nur einem Limit: Wert und Erlaeuterung, kein Balken
        hero.info_value[t] = create_square_label(g, &font_ui_36, UI_COLOR_TEXT,
                                                 x + 16, tile_y + 50, inner_w);
        hero.info_value_mid = tile_y + 50 + lv_font_get_line_height(&font_ui_36) / 2;
        lv_label_set_long_mode(hero.info_value[t], LV_LABEL_LONG_CLIP);
        hero.info_caption[t] = create_square_label(g, &font_ui_16, UI_COLOR_TEXT_SEC,
                                                   x + 16, tile_y + 110, inner_w);
    }
}

// ============================================================
// Quadratisch, mehrere gleichrangige Kontingente: drei grosse Zeilen
// (Antigravity, Gemini, Cursor u. a.). Nutzt die ag_*-Widgets.
// ============================================================
static void create_square_rows(lv_obj_t *parent, int16_t header_h) {
    rows_group = create_square_group(parent);
    lv_obj_t *g = rows_group;
    const int16_t x = 24;
    const int16_t w = SCREEN_WIDTH - 2 * x;
    const int16_t pct_w = 150;
    const int16_t cell_h = ((int16_t)SCREEN_HEIGHT - header_h) / AG_ROW_COUNT;
    const int16_t content_h = 90;

    for (uint8_t i = 0; i < AG_ROW_COUNT; i++) {
        const int16_t cell_top = header_h + i * cell_h;
        const int16_t y = cell_top + (cell_h - content_h) / 2;
        if (i > 0) {
            lv_obj_t *line = lv_obj_create(g);
            lv_obj_remove_style_all(line);
            lv_obj_set_size(line, w, 1);
            lv_obj_set_pos(line, x, cell_top);
            lv_obj_set_style_bg_color(line, UI_COLOR_DIVIDER, LV_PART_MAIN);
            lv_obj_set_style_bg_opa(line, LV_OPA_COVER, LV_PART_MAIN);
        }

        ag_title[i] = create_square_label(g, &font_ui_24, UI_COLOR_TEXT, x, y, w - pct_w);
        lv_label_set_text(ag_title[i], ag_default_title(i));
        ag_reset[i] = create_square_label(g, &font_ui_16, UI_COLOR_TEXT_SEC,
                                          x, y + 34, w - pct_w);
        ag_pct[i] = create_square_label(g, &font_ui_48, UI_COLOR_TEXT,
                                        x + w - pct_w, y - 2, pct_w);
        lv_label_set_long_mode(ag_pct[i], LV_LABEL_LONG_CLIP);
        lv_obj_set_style_text_align(ag_pct[i], LV_TEXT_ALIGN_RIGHT, LV_PART_MAIN);
        ag_bar[i] = create_square_bar(g, x, y + 66, w, 18);
        pace_tick_create_bar(ag_tick[i], g, x, y + 66, w, 18);
    }
}

static void set_obj_hidden(lv_obj_t *obj, bool hidden) {
    if (obj == nullptr) return;
    if (hidden) {
        lv_obj_add_flag(obj, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_clear_flag(obj, LV_OBJ_FLAG_HIDDEN);
    }
}

static void set_standard_widgets_visible(bool visible) {
    const bool hidden = !visible;
    set_obj_hidden(lbl_session_title, hidden);
    set_obj_hidden(lbl_session_pct, hidden);
    set_obj_hidden(lbl_session_reset, hidden);
    set_obj_hidden(lbl_session_reset_abs, hidden);
    set_obj_hidden(lbl_weekly_reset_abs, hidden);
    set_obj_hidden(lbl_weekly_title, hidden);
    set_obj_hidden(lbl_weekly_pct, hidden);
    set_obj_hidden(lbl_weekly_reset, hidden);
    set_obj_hidden(bar_session, hidden);
    set_obj_hidden(bar_weekly, hidden);
    set_obj_hidden(arc_session, hidden);
    set_obj_hidden(arc_weekly, hidden);
    set_obj_hidden(divider_middle, hidden);
    if (hidden) {
        pace_tick_hide(weekly_tick);
        pace_tick_hide(session_tick);
    }
}

static void set_antigravity_widgets_visible(bool visible) {
    const bool hidden = !visible;
    for (uint8_t i = 0; i < AG_ROW_COUNT; i++) {
        set_obj_hidden(ag_title[i], hidden);
        set_obj_hidden(ag_pct[i], hidden);
        set_obj_hidden(ag_bar[i], hidden);
        set_obj_hidden(ag_reset[i], hidden);
        if (hidden) pace_tick_hide(ag_tick[i]);
    }
    set_obj_hidden(rows_group, hidden);
}

static void set_single_widgets_visible(bool visible) {
    set_obj_hidden(lbl_single_title, !visible);
    set_obj_hidden(arc_single, !visible);
    set_obj_hidden(lbl_single_pct, !visible);
    set_obj_hidden(lbl_single_reset, !visible);
    set_obj_hidden(lbl_single_reset_abs, !visible);
    if (!visible) pace_tick_hide(single_tick);
}

// ============================================================
// Header pills (v2.18.0): Zusatz-Credits und Reset Credits als kleine
// Kennzeichen rechts neben dem Providernamen. Kein Balken, weil der Stand fuer
// Workspace-Mitglieder unbekannt ist.
// ============================================================
static const int16_t HEADER_PILL_GAP     = 6;
static const int16_t HEADER_PILL_PAD_H   = 5;
static const int16_t HEADER_PILL_PAD_V   = 2;

static lv_obj_t *create_header_pill(lv_obj_t *parent, lv_color_t color) {
    lv_obj_t *pill = lv_label_create(parent);
    lv_label_set_text(pill, "");
    lv_obj_set_style_text_font(pill, pill_font, LV_PART_MAIN);
    lv_obj_set_style_text_color(pill, color, LV_PART_MAIN);
    lv_obj_set_style_border_color(pill, color, LV_PART_MAIN);
    lv_obj_set_style_border_width(pill, 1, LV_PART_MAIN);
    lv_obj_set_style_radius(pill, LV_RADIUS_CIRCLE, LV_PART_MAIN);
    lv_obj_set_style_pad_hor(pill, HEADER_PILL_PAD_H, LV_PART_MAIN);
    lv_obj_set_style_pad_ver(pill, HEADER_PILL_PAD_V, LV_PART_MAIN);
    lv_obj_add_flag(pill, LV_OBJ_FLAG_HIDDEN);
    return pill;
}

static int16_t text_width(const char *text, const lv_font_t *font) {
    lv_point_t size;
    lv_text_get_size(&size, text, font, 0, 0, LV_COORD_MAX, LV_TEXT_FLAG_NONE);
    return (int16_t)size.x;
}

static int16_t pill_width(const char *text) {
    if (text[0] == '\0') return 0;
    return text_width(text, pill_font) + 2 * HEADER_PILL_PAD_H + 2;
}

// "+238", "+2.5k", "+12k"; unbekannter Stand: "+Cr".
static void format_credits_pill(const UsageData &usage, char *buf, size_t len) {
    if (!usage.credits_has_balance) {
        snprintf(buf, len, "+Cr");
        return;
    }
    const float b = usage.credits_balance < 0.0f ? 0.0f : usage.credits_balance;
    if (b < 1000.0f) {
        snprintf(buf, len, "+%d", (int)(b + 0.5f));
    } else if (b < 10000.0f) {
        snprintf(buf, len, "+%.1fk", b / 1000.0f);
    } else {
        snprintf(buf, len, "+%dk", (int)(b / 1000.0f + 0.5f));
    }
}

// Providername und Kennzeichen als Gruppe zentrieren. Reicht der Platz nicht
// (Hochformat, 240 px), faellt zuerst das Reset-Kennzeichen weg, dann wird
// die Schrift des Namens kleiner.
static void layout_header_center(const MonitorState &state) {
    if (lbl_provider == nullptr) return;

    const char *label = state.provider_label[0] != '\0' ? state.provider_label : "CLAUDE";
    lv_label_set_text(lbl_provider, label);
    // Quadratisch eine Stufe groesser als auf den CYDs.
    const lv_font_t *font_big   = square_layout ? &font_ui_24 : &font_ui_20;
    const lv_font_t *font_small = square_layout ? &font_ui_20 : &font_ui_16;
    const lv_font_t *font = (strlen(label) > 8) ? font_small : font_big;

    char credits_txt[12] = "";
    char reset_txt[12] = "";
    if (state.usage.valid && state.usage.credits_state == CREDITS_AVAILABLE) {
        format_credits_pill(state.usage, credits_txt, sizeof(credits_txt));
    }
    if (state.usage.valid && state.usage.reset_credits_count > 0) {
        snprintf(reset_txt, sizeof(reset_txt), LV_SYMBOL_LOOP " %u",
                 (unsigned)state.usage.reset_credits_count);
    }

    const int16_t sw = lv_obj_get_width(scr_dashboard);
    const int16_t avail = sw - 2 * header_side_reserve;
    int16_t w_credits = pill_width(credits_txt);
    int16_t w_reset = pill_width(reset_txt);
    auto total = [&](const lv_font_t *f) {
        int16_t t = text_width(label, f);
        if (w_credits) t += HEADER_PILL_GAP + w_credits;
        if (w_reset) t += HEADER_PILL_GAP + w_reset;
        return t;
    };
    if (total(font) > avail && w_reset) { reset_txt[0] = '\0'; w_reset = 0; }
    if (total(font) > avail && font == font_big) font = font_small;
    if (total(font) > avail && w_credits) { credits_txt[0] = '\0'; w_credits = 0; }

    lv_obj_set_style_text_font(lbl_provider, font, LV_PART_MAIN);
    const int16_t w_label = text_width(label, font);
    int16_t x = (sw - total(font)) / 2;
    const int16_t label_h = lv_font_get_line_height(font);
    // TOP_LEFT ausdruecklich setzen: die Ausrichtung aus ui_dashboard_create()
    // (TOP_MID) bliebe sonst bestehen und x waere ein Versatz von der Mitte.
    lv_obj_align(lbl_provider, LV_ALIGN_TOP_LEFT, x, (header_h_px - label_h) / 2);
    x += w_label;

    const int16_t pill_h = lv_font_get_line_height(pill_font) + 2 * HEADER_PILL_PAD_V + 2;
    const int16_t pill_y = (header_h_px - pill_h) / 2;
    lv_obj_t *pills[2]      = { pill_credits, pill_reset_credits };
    const char *texts[2]    = { credits_txt, reset_txt };
    const int16_t widths[2] = { w_credits, w_reset };
    for (uint8_t i = 0; i < 2; i++) {
        if (pills[i] == nullptr) continue;
        if (widths[i] == 0) {
            set_obj_hidden(pills[i], true);
            continue;
        }
        x += HEADER_PILL_GAP;
        lv_label_set_text(pills[i], texts[i]);
        lv_obj_align(pills[i], LV_ALIGN_TOP_LEFT, x, pill_y);
        set_obj_hidden(pills[i], false);
        x += widths[i];
    }
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

    // Landscape = wider than tall (320x240); square = 480x480 (S3-Board)
    landscape_layout = (sw > sh);
    square_layout = (sw == sh);

    scr_dashboard = lv_obj_create(nullptr);
    lv_obj_set_style_bg_color(scr_dashboard, UI_COLOR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr_dashboard, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_clear_flag(scr_dashboard, LV_OBJ_FLAG_SCROLLABLE);

    // ---- Header: 36 px auf den CYDs, 52 px auf dem quadratischen Panel ----
    const int16_t header_h = square_layout ? 52 : 36;
    const lv_font_t *icon_font = square_layout ? &font_ui_20 : &font_ui_14;
    header_h_px         = header_h;
    header_side_reserve = square_layout ? 80 : 52;
    status_icon_y       = square_layout ? (header_h - lv_font_get_line_height(icon_font)) / 2 : 11;
    status_dot_x        = square_layout ? 42 : 30;
    pill_font           = square_layout ? &font_ui_14 : &font_ui_12;

    lv_obj_t *header = lv_obj_create(scr_dashboard);
    lv_obj_set_size(header, sw, header_h);
    lv_obj_set_pos(header, 0, 0);
    lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(header, 0, LV_PART_MAIN);
    lv_obj_set_style_pad_all(header, 0, LV_PART_MAIN);
    lv_obj_clear_flag(header, LV_OBJ_FLAG_SCROLLABLE);

    // WiFi + connection status icons (top-left, same style as clock)
    lbl_wifi_status = lv_label_create(header);
    lv_label_set_text(lbl_wifi_status, LV_SYMBOL_DUMMY);
    lv_obj_set_style_text_color(lbl_wifi_status, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_wifi_status, icon_font, LV_PART_MAIN);
    lv_obj_set_pos(lbl_wifi_status, 8, status_icon_y);

    lbl_status_dot = lv_label_create(header);
    lv_label_set_text(lbl_status_dot, LV_SYMBOL_DUMMY);
    lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_TEXT_DIM, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_status_dot, icon_font, LV_PART_MAIN);
    lv_obj_set_pos(lbl_status_dot, 8, status_icon_y);

    lbl_provider = lv_label_create(header);
    lv_label_set_text(lbl_provider, "CLAUDE");
    lv_obj_set_style_text_color(lbl_provider, UI_COLOR_TEXT, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_provider, &font_ui_20, LV_PART_MAIN);
    lv_obj_align(lbl_provider, LV_ALIGN_TOP_MID, 0, 8);   // Position setzt layout_header_center()

    pill_credits       = create_header_pill(header, UI_COLOR_SUCCESS);
    pill_reset_credits = create_header_pill(header, UI_COLOR_TEXT_SEC);

    lbl_time = lv_label_create(header);
    lv_label_set_text(lbl_time, "--:--");
    lv_obj_set_style_text_color(lbl_time, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
    lv_obj_set_style_text_font(lbl_time, icon_font, LV_PART_MAIN);
    lv_obj_align(lbl_time, LV_ALIGN_TOP_RIGHT, square_layout ? -12 : -8, status_icon_y);

    // ---- Divider under header ----
    ui_create_divider(scr_dashboard, header_h);
    divider_middle = nullptr;

    // Reset orientation-specific widget pointers (a prior create could have
    // left stale globals from the opposite layout after orientation switch)
    bar_session = nullptr; bar_weekly = nullptr;
    arc_session = nullptr; arc_weekly = nullptr;
    lbl_session_reset_abs = nullptr;
    lbl_weekly_reset_abs = nullptr;
    lbl_single_reset_abs = nullptr;
    hero = {};
    rows_group = nullptr;
    for (uint8_t i = 0; i < AG_ROW_COUNT; i++) ag_tick[i] = {};
    weekly_tick = {};
    session_tick = {};
    single_tick = {};

    if (square_layout) {
        // ---- Quadratisch: Woche als grosser Ring, Sitzung als Balken ----
        // Die Woche sperrt bei Erreichen die ganze Woche, deshalb bekommt sie
        // den meisten Platz.
        const int16_t ring_d   = 262;
        const int16_t ring_top = header_h + 14;
        create_big_ring(
            scr_dashboard, L(STR_WEEKLY),
            sw / 2, ring_top, ring_d,
            &lbl_weekly_title, &arc_weekly, &lbl_weekly_pct,
            &lbl_weekly_reset, &lbl_weekly_reset_abs, &weekly_tick
        );

        const int16_t strip_y = ring_top + ring_d + 38;
        divider_middle = ui_create_divider(scr_dashboard, strip_y - 6);
        create_session_strip(scr_dashboard, 24, strip_y, sw - 48);

        // ---- Drei Limits: Claude/ChatGPT als Ring plus Kacheln, alle
        //      anderen Provider als drei grosse Zeilen ----
        create_square_hero(scr_dashboard, header_h);
        create_square_rows(scr_dashboard, header_h);
    } else if (landscape_layout) {
        // ---- Landscape: two filled-arc cells side by side ----
        int16_t cell_top = header_h + 2;
        int16_t cell_h   = (int16_t)sh - header_h - 2;
        int16_t cell_w   = sw / 2;
        int16_t arc_d    = cell_h - 40; // leaves room for title + reset
        if (arc_d < 90) arc_d = 90;
        if (arc_d > cell_w - 20) arc_d = cell_w - 20;

        int16_t left_cx  = cell_w / 2;
        int16_t right_cx = cell_w + cell_w / 2;

        // Woche links, Sitzung rechts: die Woche ist das wichtigere Limit.
        create_arc_block(
            scr_dashboard, L(STR_WEEKLY),
            left_cx, cell_top, cell_w, cell_h, arc_d,
            &lbl_weekly_title, &arc_weekly, &lbl_weekly_pct, &lbl_weekly_reset, &weekly_tick
        );

        create_arc_block(
            scr_dashboard, L(STR_SESSION),
            right_cx, cell_top, cell_w, cell_h, arc_d,
            &lbl_session_title, &arc_session, &lbl_session_pct, &lbl_session_reset, &session_tick
        );

        // ---- Landscape Antigravity: three compact rows ----
        const int16_t row_x   = 10;
        const int16_t row_w   = sw - 20;
        const int16_t row_h   = 58;
        const int16_t row_gap = 6;
        const int16_t row_y0  = header_h + 6;
        for (uint8_t i = 0; i < AG_ROW_COUNT; i++) {
            create_antigravity_row(
                scr_dashboard,
                i,
                row_x,
                row_y0 + (int16_t)i * (row_h + row_gap),
                row_w,
                true
            );
        }
    } else {
        // ---- Portrait: unchanged bar layout ----
        const int16_t block_h       = 114;
        int16_t available_h         = (int16_t)sh - header_h;
        int16_t zone_h              = available_h / 2;
        // Woche oben, Sitzung darunter: die Woche ist das wichtigere Limit.
        int16_t weekly_y            = header_h + (zone_h - block_h) / 2;
        int16_t middle_divider_y    = header_h + zone_h;
        int16_t session_y           = middle_divider_y + (zone_h - block_h) / 2;

        create_usage_block(
            scr_dashboard, L(STR_WEEKLY),
            weekly_y,
            &lbl_weekly_title, &lbl_weekly_pct, &bar_weekly, &lbl_weekly_reset, &weekly_tick
        );

        divider_middle = ui_create_divider(scr_dashboard, middle_divider_y);

        create_usage_block(
            scr_dashboard, L(STR_SESSION),
            session_y,
            &lbl_session_title, &lbl_session_pct, &bar_session, &lbl_session_reset, &session_tick
        );

        // ---- Portrait Antigravity: three rows ----
        const int16_t row_x   = 12;
        const int16_t row_w   = sw - 24;
        const int16_t row_h   = 76;
        const int16_t row_gap = 6;
        const int16_t row_y0  = header_h + 6;
        for (uint8_t i = 0; i < AG_ROW_COUNT; i++) {
            create_antigravity_row(
                scr_dashboard,
                i,
                row_x,
                row_y0 + (int16_t)i * (row_h + row_gap),
                row_w,
                false
            );
        }
    }

    // Reuse the existing ring style, centered in the area below the header.
    if (square_layout) {
        create_big_ring(
            scr_dashboard, L(STR_WEEKLY),
            sw / 2, header_h + 40, 300,
            &lbl_single_title, &arc_single, &lbl_single_pct,
            &lbl_single_reset, &lbl_single_reset_abs, &single_tick
        );
    } else {
        create_arc_block(
            scr_dashboard, L(STR_WEEKLY),
            sw / 2, header_h + 2, sw - 24, sh - header_h - 2, 140,
            &lbl_single_title, &arc_single, &lbl_single_pct, &lbl_single_reset, &single_tick
        );
    }
    set_single_widgets_visible(false);

    // Default screen mode is Session + Weekly.
    set_antigravity_widgets_visible(false);

    // ---- Full-screen overlay for touch events ----
    long_press_overlay = lv_obj_create(scr_dashboard);
    lv_obj_set_size(long_press_overlay, sw, sh);
    lv_obj_set_pos(long_press_overlay, 0, 0);
    lv_obj_set_style_bg_opa(long_press_overlay, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_border_width(long_press_overlay, 0, LV_PART_MAIN);
    lv_obj_clear_flag(long_press_overlay, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(long_press_overlay, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(long_press_overlay, LV_OBJ_FLAG_CLICK_FOCUSABLE);
    lv_obj_add_event_cb(long_press_overlay, on_press_start, LV_EVENT_PRESSED, nullptr);
    lv_obj_add_event_cb(long_press_overlay, on_tap_release, LV_EVENT_RELEASED, nullptr);
    lv_obj_add_event_cb(long_press_overlay, on_long_press, LV_EVENT_LONG_PRESSED, nullptr);
    lv_obj_move_foreground(long_press_overlay);

    memset(&last_state, 0, sizeof(last_state));
    state_stored = false;
    first_data_received = false;
    tap_press_started_ms = 0;

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
    lv_obj_set_style_text_font(splash_title, &font_ui_24, LV_PART_MAIN);
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
    lv_obj_set_style_text_font(splash_status, &font_ui_14, LV_PART_MAIN);
    lv_obj_align(splash_status, LV_ALIGN_CENTER, 0, 50);

    Serial.println("[UI] Dashboard screen created (Vibe-TV-Style)");
}

// ============================================================
// Quadratisch: Hero-Layout befuellen
// ============================================================
static bool provider_uses_hero(uint8_t provider) {
    return provider == PROVIDER_CLAUDE || provider == PROVIDER_OPENAI;
}

// Der Ring zeigt das Limit mit dem laengsten Fenster, bei Gleichstand das
// erste (Claude: Woche vor "Fable only"). Ohne Fensterlaengen (aeltere Apps)
// ist die zweite Zeile die Woche.
static uint8_t hero_row_index(const UsageData &u) {
    uint8_t best = 0;
    uint32_t best_minutes = 0;
    for (uint8_t i = 0; i < u.row_count && i < AG_ROW_COUNT; i++) {
        if (u.row_window_minutes[i] > best_minutes) {
            best = i;
            best_minutes = u.row_window_minutes[i];
        }
    }
    return best_minutes > 0 ? best : 1;
}

// Wert einer Info-Kachel: 36 px, wenn er passt, sonst 24 px
// ("3 Tg. 16 Std." ist fuer die grosse Schrift zu breit). Beide Kacheln
// bleiben auf derselben Mittellinie.
static void set_info_value(lv_obj_t *lbl, const char *text, lv_color_t color) {
    const int16_t w = lv_obj_get_width(lbl);
    const lv_font_t *font = text_width(text, &font_ui_36) <= w
        ? &font_ui_36 : &font_ui_24;
    lv_obj_set_style_text_font(lbl, font, LV_PART_MAIN);
    lv_obj_set_style_text_color(lbl, color, LV_PART_MAIN);
    lv_obj_set_y(lbl, hero.info_value_mid - lv_font_get_line_height(font) / 2);
    lv_label_set_text(lbl, text);
}

// Kachel "Prognose": haelt das Kontingent beim bisherigen Tempo bis zum
// Reset, und wenn nicht, wann ist es leer? Hochgerechnet aus Verbrauch und
// vergangener Zeit, wie die Tempo-Marke am Ring.
static void update_forecast_tile(uint8_t t, float used, float elapsed,
                                 uint32_t window_minutes) {
    char val[24];
    char cap[40];
    lv_color_t color = UI_COLOR_TEXT;
    if (used >= 1.0f) {
        snprintf(val, sizeof(val), "%s", L(STR_EMPTY));
        snprintf(cap, sizeof(cap), "%s", L(STR_LIMIT_REACHED));
        color = UI_COLOR_BAR_ORANGE;
    } else if (elapsed < 0.0f) {
        snprintf(val, sizeof(val), "--");
        cap[0] = '\0';
    } else if (used <= elapsed) {
        snprintf(val, sizeof(val), "%s", L(STR_LASTS));
        snprintf(cap, sizeof(cap), "%s", L(STR_UNTIL_RESET));
        color = UI_COLOR_SUCCESS;
    } else if (elapsed < 0.02f) {
        // Erste Minuten des Fensters: die Hochrechnung schwankt zu stark
        snprintf(val, sizeof(val), "--");
        snprintf(cap, sizeof(cap), "%s", L(STR_TOO_EARLY));
    } else {
        const float window_s = (float)window_minutes * 60.0f;
        const float to_empty_s = (1.0f - used) * elapsed / used * window_s;
        const time_t empty_at = time(nullptr) + (time_t)to_empty_s;
        format_reset_compact(empty_at, val, sizeof(val));
        char when[20];
        format_reset_short(empty_at, when, sizeof(when));
        snprintf(cap, sizeof(cap), L(STR_EMPTY_AT), when);
        color = UI_COLOR_BAR_ORANGE;
    }
    set_info_value(hero.info_value[t], val, color);
    lv_label_set_text(hero.info_caption[t], cap);
}

// Kachel "Tagesbudget": wie viel vom Rest pro Tag verbraucht werden darf,
// damit er bis zum Reset reicht. Unter einem Tag der ganze Rest.
static void update_budget_tile(uint8_t t, float used, time_t reset_epoch) {
    char val[16];
    char cap[40];
    const time_t now = time(nullptr);
    if (reset_epoch <= 0 || now <= CLOCK_VALID_EPOCH) {
        snprintf(val, sizeof(val), "--");
        cap[0] = '\0';
    } else {
        float left = 1.0f - used;
        if (left < 0.0f) left = 0.0f;
        const float days = (float)(reset_epoch - now) / 86400.0f;
        if (days >= 1.0f) {
            snprintf(val, sizeof(val), "%d%%", (int)(left / days * 100.0f + 0.5f));
            snprintf(cap, sizeof(cap), "%s", L(STR_PER_DAY));
        } else {
            snprintf(val, sizeof(val), "%d%%", (int)(left * 100.0f + 0.5f));
            snprintf(cap, sizeof(cap), "%s", L(STR_LEFT_UNTIL_RESET));
        }
    }
    set_info_value(hero.info_value[t], val, UI_COLOR_TEXT);
    lv_label_set_text(hero.info_caption[t], cap);
}

static const char *row_title(const MonitorState &state, uint8_t i) {
    return L_row_title(state.usage.row_title[i][0] != '\0'
        ? state.usage.row_title[i]
        : default_row_title_for_provider(state.provider, i));
}

static void update_square_hero(const MonitorState &state) {
    const UsageData &u = state.usage;
    const bool rem = u.shows_remaining;
    const uint8_t h = u.row_count == 1 ? 0 : hero_row_index(u);
    char buf[40];

    lv_label_set_text(hero.title, row_title(state, h));
    format_percentage(u.row_utilization[h], buf, sizeof(buf));
    lv_label_set_text(hero.pct, buf);
    lv_arc_set_value(hero.arc, clamp_percent(u.row_utilization[h]));
    lv_obj_set_style_arc_color(hero.arc, square_usage_color(state.provider, u.row_utilization[h], rem),
                               LV_PART_INDICATOR);

    snprintf(buf, sizeof(buf), L(STR_RESETS_IN), "");
    lv_label_set_text(hero.reset_caption, buf);
    format_reset_compact(u.row_reset_epoch[h], buf, sizeof(buf));
    lv_label_set_text(hero.reset, buf);
    format_reset_date(u.row_reset_epoch[h], buf, sizeof(buf));
    lv_label_set_text(hero.reset_abs, buf);

    const float elapsed = window_elapsed(u.row_reset_epoch[h], u.row_window_minutes[h]);
    pace_tick_set(hero.tick, pace_position(elapsed, rem));
    const bool pace_known = elapsed >= 0.0f;
    set_obj_hidden(hero.pace_dot, !pace_known);
    set_obj_hidden(hero.pace_lbl, !pace_known);
    set_obj_hidden(hero.pace_detail, !pace_known);
    if (pace_known) {
        const bool on_pace = used_fraction(u.row_utilization[h], rem) <= elapsed;
        const lv_color_t c = on_pace ? UI_COLOR_SUCCESS : UI_COLOR_BAR_ORANGE;
        lv_obj_set_style_bg_color(hero.pace_dot, c, LV_PART_MAIN);
        lv_label_set_text(hero.pace_lbl, L(on_pace ? STR_ON_PACE : STR_TOO_FAST));
        snprintf(buf, sizeof(buf), L(STR_TIME_ELAPSED), (int)(elapsed * 100.0f + 0.5f));
        lv_label_set_text(hero.pace_detail, buf);
    }

    // Nur ein Limit: die Kacheln zeigen Prognose und Tagesbudget.
    const bool info_tiles = u.row_count == 1;
    for (uint8_t i = 0; i < 2; i++) {
        set_obj_hidden(hero.tile_pct[i], info_tiles);
        set_obj_hidden(hero.tile_bar[i], info_tiles);
        set_obj_hidden(hero.tile_reset[i], info_tiles);
        set_obj_hidden(hero.info_value[i], !info_tiles);
        set_obj_hidden(hero.info_caption[i], !info_tiles);
        if (info_tiles) pace_tick_hide(hero.tile_tick[i]);
    }
    if (info_tiles) {
        const float used = used_fraction(u.row_utilization[h], rem);
        lv_label_set_text(hero.tile_title[0], L(STR_FORECAST));
        update_forecast_tile(0, used, elapsed, u.row_window_minutes[h]);
        lv_label_set_text(hero.tile_title[1], L(STR_DAILY_BUDGET));
        update_budget_tile(1, used, u.row_reset_epoch[h]);
        return;
    }

    uint8_t t = 0;
    for (uint8_t i = 0; i < AG_ROW_COUNT && t < 2; i++) {
        if (i == h) continue;
        lv_label_set_text(hero.tile_title[t], row_title(state, i));
        format_percentage(u.row_utilization[i], buf, sizeof(buf));
        lv_label_set_text(hero.tile_pct[t], buf);
        lv_bar_set_value(hero.tile_bar[t], clamp_percent(u.row_utilization[i]), LV_ANIM_ON);
        lv_obj_set_style_bg_color(hero.tile_bar[t],
                                  square_usage_color(state.provider, u.row_utilization[i], rem),
                                  LV_PART_INDICATOR);
        pace_tick_set(hero.tile_tick[t],
                      pace_position(window_elapsed(u.row_reset_epoch[i], u.row_window_minutes[i]), rem));
        format_reset_compact(u.row_reset_epoch[i], buf, sizeof(buf));
        lv_label_set_text(hero.tile_reset[t], buf);
        t++;
    }
}

// ============================================================
// Update dashboard with fresh MonitorState
// ============================================================
void ui_dashboard_update(const MonitorState &state) {
    if (!widgets_ready()) return;

    memcpy(&last_state, &state, sizeof(MonitorState));
    state_stored = true;

    if (serial_is_plugin_view()) {
        if (splash_overlay) {
            lv_obj_delete(splash_overlay);
            splash_overlay = splash_spinner = nullptr;
        }
        hide_standby_overlay();
        update_plugin_view();
        return;
    }
    if (plugin_overlay) {
        lv_obj_delete(plugin_overlay);
        plugin_overlay = nullptr;
        plugin_rendered_view = 0xFF;
    }

    if (serial_is_clock_view()) {
        if (splash_overlay != nullptr) {
            lv_obj_delete(splash_overlay);
            splash_overlay = nullptr;
            splash_spinner = nullptr;
        }
        hide_standby_overlay();
        update_clock_view();
        return;
    }
    if (clock_overlay != nullptr) {
        lv_obj_delete(clock_overlay);
        clock_overlay = clock_time = clock_date = nullptr;
    }

    const bool has_recent_data = serial_has_recent_data();
    const bool clock_is_set = time(nullptr) > CLOCK_VALID_EPOCH;
    // Ein echtes Notice-Frame bleibt sichtbar, solange der Host weiter sendet.
    // Der synthetische Ladehinweis aus der gespeicherten Fensterkonfiguration
    // darf die Standby-Uhr nach einem Start ohne Companion nicht blockieren.
    // Ohne Uhrzeit und ohne je empfangene Daten bleibt der Warte-Splash stehen.
    const bool should_show_standby = !has_recent_data
                                  && !serial_has_recent_host_frame()
                                  && (clock_is_set || state.usage.valid);

    // Hide splash overlay once we receive the first valid data — oder einen
    // Hinweis. Sonst bliebe der Splash haengen, wenn der beim Start gewaehlte
    // Provider gar keine Daten liefert.
    if (!first_data_received && (state.usage.valid || state.usage.notice_only)
        && splash_overlay != nullptr) {
        first_data_received = true;
        lv_obj_delete(splash_overlay);
        splash_overlay = nullptr;
        splash_spinner = nullptr;
        Serial.println("[UI] Splash dismissed — first data received");
    }

    if (should_show_standby) {
        show_standby_overlay();
    } else {
        hide_standby_overlay();
    }

    // ---- Provider name ----
    // v2.9.0+: Label kommt direkt aus dem Mac-Envelope (state.provider_label,
    // uppercase, z. B. "CLAUDE" oder "CHATGPT"). Fallback auf "CLAUDE" bei leerem
    // String (alter App-Version).
    // v2.18.0: zusammen mit den Credit-Kennzeichen als Gruppe zentriert.
    layout_header_center(state);

    // ---- Clock (system time set via settimeofday + timezone offset from Mac) ----
    if (lbl_time != nullptr) {
        time_t now = time(nullptr);
        if (now > CLOCK_VALID_EPOCH) {  // system clock has been set (post-2023)
            struct tm local;
            localtime_r(&now, &local);
            char tbuf[6];
            strftime(tbuf, sizeof(tbuf), "%H:%M", &local);
            lv_label_set_text(lbl_time, tbuf);
        } else {
            lv_label_set_text(lbl_time, serial_get_display_time());
        }
    }

    // A lone limit uses the centered ring — originally ChatGPT's weekly
    // window, since FW 2.17.0 any provider with exactly one row (e.g. Copilot
    // premium requests, Cursor legacy request plans). ChatGPT keeps the ring
    // for notices without valid usage, so its layout never flips.
    const bool uses_single_arc = state.usage.row_count == 1
                              || (state.provider == PROVIDER_OPENAI && !state.usage.valid);
    const bool uses_compact_rows = !uses_single_arc && state.usage.row_count > 0
                                && (state.provider == PROVIDER_ANTIGRAVITY
                                    || state.usage.row_count != 2);
    // Quadratisch: Claude/ChatGPT mit drei Limits als Ring plus Kacheln,
    // ein einzelnes Limit (jeder Provider) als Ring plus Prognose-Kacheln.
    // Hinweise ohne gueltige Daten bleiben beim zentrierten Ring.
    const bool uses_hero = square_layout && state.usage.valid
                        && ((uses_compact_rows && state.usage.row_count == AG_ROW_COUNT
                             && provider_uses_hero(state.provider))
                            || state.usage.row_count == 1);
    const bool rem = state.usage.shows_remaining;
    set_standard_widgets_visible(!uses_compact_rows && !uses_single_arc);
    set_antigravity_widgets_visible(uses_compact_rows && !uses_hero);
    set_single_widgets_visible(uses_single_arc && !uses_hero);
    set_obj_hidden(hero.group, !uses_hero);

    // ---- Usage blocks ----
    if (state.usage.valid) {
        char buf[32];

        if (uses_hero) {
            update_square_hero(state);
        } else if (uses_single_arc) {
            const char *title = state.usage.row_title[0][0] != '\0'
                ? L_row_title(state.usage.row_title[0]) : L(STR_WEEKLY);
            lv_label_set_text(lbl_single_title, title);
            format_percentage(state.usage.row_utilization[0], buf, sizeof(buf));
            lv_label_set_text(lbl_single_pct, buf);
            int val = (int)(state.usage.row_utilization[0] * 100.0f);
            if (val < 0) val = 0;
            if (val > 100) val = 100;
            lv_arc_set_value(arc_single, val);
            lv_obj_set_style_arc_color(arc_single, square_layout
                ? square_usage_color(state.provider, state.usage.row_utilization[0], rem)
                : ui_bar_color(state.provider), LV_PART_INDICATOR);
            format_reset_compact(state.usage.row_reset_epoch[0], buf, sizeof(buf));
            lv_label_set_text(lbl_single_reset, buf);
            if (lbl_single_reset_abs) {
                format_reset_date(state.usage.row_reset_epoch[0], buf, sizeof(buf));
                lv_label_set_text(lbl_single_reset_abs, buf);
            }
            pace_tick_set(single_tick, pace_position(window_elapsed(
                state.usage.row_reset_epoch[0], state.usage.row_window_minutes[0]), rem));
        } else if (uses_compact_rows) {
            lv_color_t ag_color = ui_bar_color(state.provider);
            for (uint8_t i = 0; i < AG_ROW_COUNT; i++) {
                const bool row_active = (i < state.usage.row_count);
                set_obj_hidden(ag_title[i], !row_active);
                set_obj_hidden(ag_pct[i], !row_active);
                set_obj_hidden(ag_bar[i], !row_active);
                set_obj_hidden(ag_reset[i], !row_active);
                if (!row_active) {
                    pace_tick_hide(ag_tick[i]);
                    continue;
                }

                lv_label_set_text(ag_title[i], row_title(state, i));

                format_percentage(state.usage.row_utilization[i], buf, sizeof(buf));
                lv_label_set_text(ag_pct[i], buf);
                lv_obj_set_style_text_color(ag_pct[i], square_layout ? UI_COLOR_TEXT : UI_COLOR_TEXT_SEC,
                                            LV_PART_MAIN);

                int val = clamp_percent(state.usage.row_utilization[i]);
                if (ag_bar[i]) {
                    lv_bar_set_value(ag_bar[i], val, LV_ANIM_ON);
                    lv_obj_set_style_bg_color(ag_bar[i], square_layout
                        ? square_usage_color(state.provider, state.usage.row_utilization[i], rem)
                        : ag_color, LV_PART_INDICATOR);
                }

                format_reset_compact(state.usage.row_reset_epoch[i], buf, sizeof(buf));
                if (square_layout) {
                    // Quadratisch: Countdown und Zeitpunkt in einer Zeile
                    char when[20];
                    format_reset_short(state.usage.row_reset_epoch[i], when, sizeof(when));
                    const size_t used = strlen(buf);
                    if (state.usage.row_reset_epoch[i] > 0 && used < sizeof(buf)) {
                        snprintf(buf + used, sizeof(buf) - used, "  " LV_SYMBOL_BULLET "  %s", when);
                    }
                }
                pace_tick_set(ag_tick[i], pace_position(window_elapsed(
                    state.usage.row_reset_epoch[i], state.usage.row_window_minutes[i]), rem));
                lv_label_set_text(ag_reset[i], buf);
            }
        } else {
            // --- Session percent ---
            format_percentage(state.usage.five_hour_utilization, buf, sizeof(buf));
            lv_label_set_text(lbl_session_pct, buf);

            int s_val = (int)(state.usage.five_hour_utilization * 100.0f);
            if (s_val < 0) s_val = 0;
            if (s_val > 100) s_val = 100;
            // Quadratisches Layout: kurz vor der Grenze warnen.
            lv_color_t session_color = square_layout
                ? square_usage_color(state.provider, state.usage.five_hour_utilization, rem)
                : ui_bar_color(state.provider);
            pace_tick_set(session_tick, pace_position(window_elapsed(
                state.usage.five_hour_reset_epoch, state.usage.five_hour_window_minutes), rem));

            if (arc_session) {
                lv_arc_set_value(arc_session, s_val);
                lv_obj_set_style_arc_color(arc_session, session_color, LV_PART_INDICATOR);
                lv_obj_set_style_text_color(lbl_session_pct, UI_COLOR_TEXT, LV_PART_MAIN);
            } else if (bar_session) {
                lv_bar_set_value(bar_session, s_val, LV_ANIM_ON);
                lv_obj_set_style_bg_color(bar_session, session_color, LV_PART_INDICATOR);
            }

            // --- Session reset (compact, no "Reset in" prefix) ---
            format_reset_compact(state.usage.five_hour_reset_epoch, buf, sizeof(buf));
            lv_label_set_text(lbl_session_reset, buf);
            if (lbl_session_reset_abs) {
                format_reset_date(state.usage.five_hour_reset_epoch, buf, sizeof(buf));
                lv_label_set_text(lbl_session_reset_abs, buf);
            }

            // --- Weekly percent ---
            format_percentage(state.usage.seven_day_utilization, buf, sizeof(buf));
            lv_label_set_text(lbl_weekly_pct, buf);

            int w_val = (int)(state.usage.seven_day_utilization * 100.0f);
            if (w_val < 0) w_val = 0;
            if (w_val > 100) w_val = 100;
            lv_color_t weekly_color = square_layout
                ? square_usage_color(state.provider, state.usage.seven_day_utilization, rem)
                : ui_bar_color(state.provider);
            pace_tick_set(weekly_tick, pace_position(window_elapsed(
                state.usage.seven_day_reset_epoch, state.usage.seven_day_window_minutes), rem));

            if (arc_weekly) {
                lv_arc_set_value(arc_weekly, w_val);
                lv_obj_set_style_arc_color(arc_weekly, weekly_color, LV_PART_INDICATOR);
                lv_obj_set_style_text_color(lbl_weekly_pct, UI_COLOR_TEXT, LV_PART_MAIN);
            } else if (bar_weekly) {
                lv_bar_set_value(bar_weekly, w_val, LV_ANIM_ON);
                lv_obj_set_style_bg_color(bar_weekly, weekly_color, LV_PART_INDICATOR);
            }

            // --- Weekly reset (unified compact form in both orientations,
            //     no "Reset in" prefix) ---
            {
                char wbuf[32];
                format_reset_compact(state.usage.seven_day_reset_epoch, wbuf, sizeof(wbuf));
                lv_label_set_text(lbl_weekly_reset, wbuf);
                if (lbl_weekly_reset_abs) {
                    format_reset_date(state.usage.seven_day_reset_epoch, wbuf, sizeof(wbuf));
                    lv_label_set_text(lbl_weekly_reset_abs, wbuf);
                }
            }
        }

    } else if (strlen(state.usage.error) > 0) {
        // v2.15.0: Hinweis (z. B. „Bitte App oeffnen") vs. echter Fehler.
        // Beim Hinweis waere "ERR" irrefuehrend — es ist nichts kaputt, es
        // fehlen nur Daten fuer den gerade gewaehlten Provider.
        const char *pct_placeholder = state.usage.notice_only ? "--" : "ERR";
        if (uses_single_arc) {
            lv_label_set_text(lbl_single_title, L(STR_WEEKLY));
            lv_label_set_text(lbl_single_pct, pct_placeholder);
            lv_label_set_text(lbl_single_reset, state.usage.error);
            if (lbl_single_reset_abs) lv_label_set_text(lbl_single_reset_abs, "");
            lv_arc_set_value(arc_single, 0);
            pace_tick_hide(single_tick);
        } else if (uses_compact_rows) {
            for (uint8_t i = 0; i < AG_ROW_COUNT; i++) {
                const bool first_row = (i == 0);
                set_obj_hidden(ag_title[i], !first_row);
                set_obj_hidden(ag_pct[i], !first_row);
                set_obj_hidden(ag_bar[i], !first_row);
                set_obj_hidden(ag_reset[i], !first_row);
                pace_tick_hide(ag_tick[i]);
                if (!first_row) continue;

                lv_label_set_text(ag_title[i], L_row_title(default_row_title_for_provider(state.provider, i)));
                lv_label_set_text(ag_pct[i], pct_placeholder);
                lv_label_set_text(ag_reset[i], state.usage.error);
                if (ag_bar[i]) lv_bar_set_value(ag_bar[i], 0, LV_ANIM_OFF);
            }
        } else {
            lv_label_set_text(lbl_session_pct,   pct_placeholder);
            lv_label_set_text(lbl_session_reset, state.usage.error);
            lv_label_set_text(lbl_weekly_pct,    pct_placeholder);
            lv_label_set_text(lbl_weekly_reset,  "");
            if (lbl_session_reset_abs) lv_label_set_text(lbl_session_reset_abs, "");
            if (lbl_weekly_reset_abs)  lv_label_set_text(lbl_weekly_reset_abs, "");
            if (bar_session) lv_bar_set_value(bar_session, 0, LV_ANIM_OFF);
            if (bar_weekly)  lv_bar_set_value(bar_weekly,  0, LV_ANIM_OFF);
            if (arc_session) lv_arc_set_value(arc_session, 0);
            if (arc_weekly)  lv_arc_set_value(arc_weekly,  0);
            pace_tick_hide(session_tick);
            pace_tick_hide(weekly_tick);
        }
    }

    // ---- Header: WiFi + connection status icons ----
    if (wifi_time_is_connected()) {
        lv_obj_set_style_text_color(lbl_wifi_status, UI_COLOR_TEXT_SEC, LV_PART_MAIN);
        lv_label_set_text(lbl_wifi_status, LV_SYMBOL_WIFI);
        lv_obj_set_pos(lbl_status_dot, status_dot_x, status_icon_y);
    } else {
        lv_label_set_text(lbl_wifi_status, LV_SYMBOL_DUMMY);
        lv_obj_set_pos(lbl_status_dot, 8, status_icon_y);
    }

    if (state.is_fetching) {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_FETCHING, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_REFRESH);
    } else if (has_recent_data && state.usage.valid) {
        lv_obj_set_style_text_color(lbl_status_dot, UI_COLOR_SUCCESS, LV_PART_MAIN);
        lv_label_set_text(lbl_status_dot, LV_SYMBOL_OK);
    } else if (!has_recent_data && state.usage.valid) {
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
        pill_credits       = nullptr;
        pill_reset_credits = nullptr;
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
        lbl_single_title   = nullptr;
        arc_single         = nullptr;
        lbl_single_pct     = nullptr;
        lbl_single_reset   = nullptr;
        lbl_session_reset_abs = nullptr;
        lbl_weekly_reset_abs  = nullptr;
        lbl_single_reset_abs  = nullptr;
        lbl_wifi_status    = nullptr;
        lbl_status_dot     = nullptr;
        divider_middle     = nullptr;
        hero               = {};
        rows_group         = nullptr;
        weekly_tick        = {};
        session_tick       = {};
        single_tick        = {};
        for (uint8_t i = 0; i < AG_ROW_COUNT; i++) {
            ag_tick[i] = {};
            ag_title[i] = nullptr;
            ag_pct[i] = nullptr;
            ag_bar[i] = nullptr;
            ag_reset[i] = nullptr;
        }
        long_press_overlay = nullptr;
        splash_overlay     = nullptr;
        splash_spinner     = nullptr;
        standby_overlay    = nullptr;
        standby_clock      = nullptr;
        standby_wifi       = nullptr;
        clock_overlay      = nullptr;
        clock_time         = nullptr;
        clock_date         = nullptr;
        plugin_overlay     = nullptr;
        plugin_rendered_view = 0xFF;
        plugin_rendered_revision = 0;
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
