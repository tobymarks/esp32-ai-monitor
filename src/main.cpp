/**
 * AI Usage Monitor - ESP32-2432S028R (CYD 2.8")
 * v2.0.0 — USB-Serial Only (no WiFi, no WebServer)
 *
 * Boot sequence:
 * 1. Init Serial (USB)
 * 2. Init display + touch + LVGL
 * 3. Show boot screen
 * 4. Init serial receiver
 * 5. Enter dashboard directly
 *
 * Data flow:
 *   Mac (CodexBar) --USB-Serial--> ESP32 --> Dashboard
 *
 * Navigation:
 *   Dashboard (default) -> long press (>1s) -> Settings screen
 *   Settings -> tap back arrow -> Dashboard
 */

#include <Arduino.h>
#include <lvgl.h>
#include <Preferences.h>
#include "board.h"
#include "config.h"
#include "config_store.h"
#include "localization.h"
#include "serial_receiver.h"
#include "ui_common.h"
#include "ui_dashboard.h"
#include "ui_settings.h"
#include "wifi_time.h"

// ============================================================
// Globals
// ============================================================

// Runtime screen dimensions (defined here, declared extern in config.h)
uint16_t SCREEN_WIDTH  = DISPLAY_SHORT_SIDE;   // Default: Portrait 240
uint16_t SCREEN_HEIGHT = DISPLAY_LONG_SIDE;     // Default: Portrait 320

// LVGL display and input device
static lv_display_t  *lv_disp = nullptr;
static lv_indev_t    *lv_touch = nullptr;

// Dashboard state
static bool dashboard_active = false;
static unsigned long last_ui_update = 0;
static const unsigned long UI_UPDATE_INTERVAL = 1000;  // 1s interval for live countdown + clock

// Heap monitoring
static unsigned long lastHeapLog = 0;

// Loop debug counter
static unsigned long loopCount = 0;
static unsigned long lastLoopLog = 0;

// ============================================================
// Backlight control (LEDC PWM on PIN_TFT_BL)
// ============================================================
void backlight_apply_percent(uint8_t pct)
{
    board_backlight_set_percent(pct);
}

// ============================================================
// Orientation change WITHOUT reboot
//   - switches TFT rotation
//   - touch coordinate mapping follows the current orientation
//   - resizes LVGL display
//   - recreates dashboard so layout uses new SCREEN_WIDTH/HEIGHT
// ============================================================
// Lesbarer Name der Orientierung — nur fuer Logging.
static const char *orientation_name(uint8_t orientation)
{
    switch (orientation) {
        case ORIENTATION_LANDSCAPE_LEFT:  return "landscape_left";
        case ORIENTATION_LANDSCAPE_RIGHT: return "landscape_right";
        default:                          return "portrait";
    }
}

void apply_orientation(uint8_t orientation)
{
    board_set_rotation(orientation);

    // Blank the panel so no garbled pixels leak through during recreate
    board_fill_black();

    // Tell LVGL the new resolution — it reallocates the rendering state and
    // clips subsequent draws to the new extent.
    if (lv_disp) {
        lv_display_set_resolution(lv_disp, SCREEN_WIDTH, SCREEN_HEIGHT);
    }

    // C4: The dashboard recreate is deferred to loop() (see serial_receiver).
    // All state above (rotation, SCREEN_WIDTH/HEIGHT, LVGL
    // resolution) is applied synchronously here; only the expensive full-screen
    // rebuild is taken out of the Serial RX path. apply_orientation() is only
    // ever called from the command parser, so deferring is safe.
    serial_request_ui_rebuild();

    Serial.printf("[TFT] Rotation switched live to %s (%ux%u)\n",
                  orientation_name(orientation), SCREEN_WIDTH, SCREEN_HEIGHT);
}

// ============================================================
// LVGL flush callback — geht ueber die Board-Schnittstelle
// ============================================================
static void disp_flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    board_flush(area, px_map);
    lv_display_flush_ready(disp);
}

// ============================================================
// LVGL touch read callback
// ============================================================
static void touch_read_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    (void)indev;
    static bool was_touched = false;
    uint16_t x = 0, y = 0;
    bool touched = board_touch_read(&x, &y);

    if (touched) {
        if (!was_touched) Serial.printf("[Touch] Press at %u,%u\n", x, y);
        data->point.x = x;
        data->point.y = y;
        data->state = LV_INDEV_STATE_PRESSED;
    } else {
        if (was_touched) Serial.println("[Touch] Release");
        data->state = LV_INDEV_STATE_RELEASED;
    }
    was_touched = touched;
}

// ============================================================
// Boot screen — LVGL, damit er auf beiden Boards gleich aussieht
// ============================================================
static lv_obj_t *boot_screen = nullptr;
static lv_obj_t *boot_status = nullptr;

static void draw_boot_screen(void)
{
    boot_screen = lv_obj_create(nullptr);
    lv_obj_set_style_bg_color(boot_screen, lv_color_black(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(boot_screen, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_clear_flag(boot_screen, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *title = lv_label_create(boot_screen);
    lv_label_set_text(title, APP_NAME);
    lv_obj_set_style_text_color(title, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_align(title, LV_ALIGN_CENTER, 0, -30);

    boot_status = lv_label_create(boot_screen);
    lv_label_set_text(boot_status, L(STR_INITIALIZING));
    lv_obj_set_style_text_color(boot_status, lv_palette_main(LV_PALETTE_GREY), LV_PART_MAIN);
    lv_obj_set_style_text_font(boot_status, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(boot_status, LV_ALIGN_CENTER, 0, 10);

    lv_obj_t *version = lv_label_create(boot_screen);
    lv_label_set_text(version, "v" APP_VERSION);
    lv_obj_set_style_text_color(version, lv_palette_main(LV_PALETTE_GREY), LV_PART_MAIN);
    lv_obj_set_style_text_font(version, &lv_font_montserrat_12, LV_PART_MAIN);
    lv_obj_align(version, LV_ALIGN_BOTTOM_RIGHT, -10, -10);

    lv_screen_load(boot_screen);
    lv_refr_now(NULL);
}

// ============================================================
// Update boot status text on display
// ============================================================
static void update_boot_status(const char *msg) {
    if (boot_status != nullptr) {
        lv_label_set_text(boot_status, msg);
        lv_refr_now(NULL);
    }
    Serial.printf("[Boot] %s\n", msg);
}

// ============================================================
// Transition to main dashboard UI
// ============================================================
static void enter_main_ui(void) {
    ui_dashboard_create();
    lv_obj_t *dash_scr = ui_dashboard_get_screen();
    if (dash_scr) {
        lv_screen_load(dash_scr);
    }
    dashboard_active = true;

    MonitorState initState = serial_get_state();
    ui_dashboard_update(initState);

    Serial.println("[UI] Dashboard active (waiting for USB data)");
    lv_refr_now(NULL);
}

// ============================================================
// Setup
// ============================================================
void setup()
{
    // --- Serial init (BEFORE begin for RX buffer) ---
    Serial.setRxBufferSize(4096);
    Serial.begin(115200);
    delay(500);
    Serial.println("========================================");
    Serial.printf("%s v%s (USB-Serial)\n", APP_NAME, APP_VERSION);
    Serial.println("========================================");

    // --- Display + Touch ueber die Board-Schnittstelle ---
    // Muss vor dem Backlight laufen: die SPI-Boards bringen dabei ihre
    // Panel-Reset-Sequenz hoch, das RGB-Board legt den Framebuffer an.
    board_display_init();
    board_backlight_init();

    // Einstellungen laden. Auf Boards ohne dauerhafte Ablage sind das die
    // Voreinstellungen, bis der Host sein Geraeteprofil schickt.
    config_load(g_config);
    backlight_apply_percent(g_config.brightness_pct);

    // Apply persisted theme before creating UI
    ui_apply_theme(g_config.theme);

    // Drehung und SCREEN_WIDTH/HEIGHT setzen, bevor LVGL das Display anlegt.
    board_set_rotation(g_config.orientation);
    board_fill_black();
    Serial.printf("[Display] %s initialisiert (%ux%u)\n",
                  board_display_id(), SCREEN_WIDTH, SCREEN_HEIGHT);

    // --- LVGL init ---
    lv_init();
    lv_tick_set_cb([]() -> uint32_t { return (uint32_t)millis(); });
    Serial.println("[LVGL] Core initialized + tick callback registered");

    void *lv_buf1 = nullptr, *lv_buf2 = nullptr;
    uint32_t lv_buf_bytes = 0;
    board_lvgl_buffers(&lv_buf1, &lv_buf2, &lv_buf_bytes);

    lv_disp = lv_display_create(SCREEN_WIDTH, SCREEN_HEIGHT);
    lv_display_set_flush_cb(lv_disp, disp_flush_cb);
    lv_display_set_buffers(lv_disp, lv_buf1, lv_buf2,
                           lv_buf_bytes, LV_DISPLAY_RENDER_MODE_PARTIAL);
    Serial.printf("[LVGL] Display driver registered (%ux%u)\n", SCREEN_WIDTH, SCREEN_HEIGHT);

    lv_touch = lv_indev_create();
    lv_indev_set_type(lv_touch, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(lv_touch, touch_read_cb);
    Serial.println("[LVGL] Touch input registered");

    // --- Boot screen ---
    draw_boot_screen();

    // --- Serial receiver init ---
    serial_receiver_init();
    wifi_time_init();
    update_boot_status(L(STR_USB_CONNECTED));
    delay(1000);

    // --- Enter dashboard ---
    enter_main_ui();

    // --- Heap info ---
    Serial.printf("[System] Free heap: %u bytes\n", ESP.getFreeHeap());
    Serial.printf("[System] Min free heap: %u bytes\n", ESP.getMinFreeHeap());
    Serial.println("========================================");
    Serial.println("Setup complete. Entering main loop.");
}

// ============================================================
// Main loop
// ============================================================
void loop()
{
    lv_timer_handler();

    // Read serial data
    serial_receiver_tick();
    wifi_time_tick();

    // C4: Perform any UI rebuild requested by the command parser here, OUTSIDE
    // the Serial RX loop, so the expensive full-screen recreate is not reentrant
    // with frame reception. State (theme/language/orientation/dimensions) was
    // already applied synchronously in the parser.
    if (serial_ui_rebuild_requested()) {
        ui_dashboard_recreate();
        serial_ui_rebuild_clear();
    }

    // Update dashboard UI on new data OR every 1s (clock/countdown)
    if (dashboard_active) {
        if (serial_has_new_data() || (millis() - last_ui_update >= UI_UPDATE_INTERVAL)) {
            MonitorState curState = serial_get_state();
            ui_dashboard_update(curState);
            last_ui_update = millis();
        }
    }

    // Loop debug + heap monitoring (every 10 seconds)
    loopCount++;
    if (millis() - lastLoopLog >= 10000) {
        unsigned long elapsed = millis() - lastLoopLog;
        Serial.printf("[Loop] %lu iterations in %lu ms | tick=%u | heap=%u\n",
                      loopCount, elapsed, (unsigned)lv_tick_get(), ESP.getFreeHeap());
        loopCount = 0;
        lastLoopLog = millis();
    }

    // Periodic heap monitoring (every 60 seconds)
    if (millis() - lastHeapLog > 60000) {
        lastHeapLog = millis();
        Serial.printf("[Heap] Free: %u  Min: %u\n",
                      ESP.getFreeHeap(), ESP.getMinFreeHeap());
    }

    delay(5);
}
