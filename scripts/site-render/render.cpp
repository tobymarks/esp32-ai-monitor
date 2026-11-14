// Render the actual firmware dashboard with fixed, fictional demonstration data.
#include "ui_dashboard.h"
#include "ui_common.h"
#include "config.h"
#include "localization.h"
#include "standalone_runtime.h"
#include <vector>
#include <cstdlib>

uint16_t SCREEN_WIDTH = 320;
uint16_t SCREEN_HEIGHT = 240;
bool serial_is_plugin_view() { return false; }
bool serial_is_clock_view() { return false; }
bool serial_has_recent_data() { return true; }
bool serial_has_recent_host_frame() { return true; }
uint8_t serial_active_view() { return 0; }
void serial_previous_view() {}
void serial_next_view() {}
const char *serial_get_display_time() { return "14:32"; }
bool wifi_time_is_connected() { return false; }
// Website captures show USB usage with the optional offline profile disabled.
bool standalone_active() { return false; }
const PluginSceneSlot *standalone_scene() { return nullptr; }
const char *standalone_status() { return "disabled"; }
uint32_t standalone_success_age_seconds() { return UINT32_MAX; }
bool standalone_stale() { return false; }
void ui_settings_create() {}
// Keep all dates, countdowns and clocks reproducible without changing system time.
extern "C" time_t time(time_t *out) {
    const time_t fixed = 1790605920; // 2026-09-28 14:32 UTC
    if (out) *out = fixed;
    return fixed;
}
static std::vector<uint16_t> frame;
static void flush(lv_display_t *display, const lv_area_t *area, uint8_t *pixels) {
    const auto *src = reinterpret_cast<const uint16_t *>(pixels);
    const int stride = area->x2 - area->x1 + 1;
    for (int y = area->y1; y <= area->y2; ++y)
        for (int x = area->x1; x <= area->x2; ++x)
            frame[y * SCREEN_WIDTH + x] = src[(y - area->y1) * stride + x - area->x1];
    lv_display_flush_ready(display);
}
int main(int argc, char **argv) {
    if (argc != 6) return 2; // width height provider theme output.ppm
    SCREEN_WIDTH = atoi(argv[1]); SCREEN_HEIGHT = atoi(argv[2]);
    if (!((SCREEN_WIDTH == 320 && SCREEN_HEIGHT == 240) ||
          (SCREEN_WIDTH == 240 && SCREEN_HEIGHT == 320) ||
          (SCREEN_WIDTH == 480 && SCREEN_HEIGHT == 480))) return 2;
    setenv("TZ", "UTC", 1); tzset();
    lv_init();
    auto *display = lv_display_create(SCREEN_WIDTH, SCREEN_HEIGHT);
    lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);
    frame.resize(SCREEN_WIDTH * SCREEN_HEIGHT);
    std::vector<uint16_t> buffer(SCREEN_WIDTH * 20);
    lv_display_set_buffers(display, buffer.data(), nullptr, buffer.size() * 2, LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(display, flush);
    g_language = LANG_DE;
    ui_apply_theme(atoi(argv[4])); ui_styles_init(); ui_dashboard_create();
    MonitorState state = {};
    const bool full_claude = strcmp(argv[3], "claude-full") == 0;
    state.provider = (strcmp(argv[3], "claude") == 0 || full_claude) ? PROVIDER_CLAUDE : PROVIDER_OPENAI;
    strcpy(state.provider_label, state.provider == PROVIDER_CLAUDE ? "CLAUDE" : "CHATGPT");
    state.token_valid = true; state.usage.valid = true; state.usage.last_fetch = millis();
    auto &u = state.usage;
    u.five_hour_utilization = .32f; u.seven_day_utilization = .67f;
    u.five_hour_reset_epoch = time(nullptr) + 2 * 3600 + 14 * 60;
    u.seven_day_reset_epoch = time(nullptr) + 3 * 86400 + 8 * 3600;
    u.five_hour_window_minutes = 300; u.seven_day_window_minutes = 10080;
    u.row_count = state.provider == PROVIDER_CLAUDE ? 2 : 1;
    if (u.row_count == 1) {
        strcpy(u.row_title[0], "Weekly"); u.row_utilization[0] = .67f;
        u.row_reset_epoch[0] = u.seven_day_reset_epoch; u.row_window_minutes[0] = 10080;
    }
    if (full_claude) {
        u.row_count = 3;
        const char *titles[] = { "Session", "Weekly", "Fable only" };
        const float usage[] = { .97f, .22f, .53f };
        const uint32_t windows[] = { 300, 10080, 10080 };
        const int resets[] = { 3 * 3600 + 19 * 60, 8 * 3600 + 29 * 60, 8 * 3600 + 29 * 60 };
        for (int i = 0; i < 3; ++i) {
            strcpy(u.row_title[i], titles[i]);
            u.row_utilization[i] = usage[i];
            u.row_window_minutes[i] = windows[i];
            u.row_reset_epoch[i] = time(nullptr) + resets[i];
        }
    }
    ui_dashboard_update(state);
    lv_screen_load(ui_dashboard_get_screen());
    // Complete bar animations before capturing the framebuffer.
    for (int i = 0; i < 40; ++i) { lv_tick_inc(33); lv_timer_handler(); }
    lv_refr_now(display);
    FILE *out = fopen(argv[5], "wb"); if (!out) return 1;
    fprintf(out, "P6\n%u %u\n255\n", SCREEN_WIDTH, SCREEN_HEIGHT);
    for (uint16_t pixel : frame) {
        const unsigned char rgb[] = {static_cast<unsigned char>(((pixel >> 11) & 31) * 255 / 31), static_cast<unsigned char>(((pixel >> 5) & 63) * 255 / 63), static_cast<unsigned char>((pixel & 31) * 255 / 31)};
        fwrite(rgb, 1, 3, out);
    }
    return fclose(out) == 0 ? 0 : 1;
}
