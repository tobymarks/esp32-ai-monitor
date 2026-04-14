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
 *   Dashboard (default) -> tap -> Detail screen
 *   Dashboard -> long press (>1s) -> Settings screen
 *   Detail / Settings -> tap back arrow -> Dashboard
 */

#include <Arduino.h>
#include <SPI.h>
#include <TFT_eSPI.h>
#include <lvgl.h>
#include <Preferences.h>
#include "config.h"
#include "config_store.h"
#include "localization.h"
#include "serial_receiver.h"
#include "ui_common.h"
#include "ui_dashboard.h"
#include "ui_detail.h"
#include "ui_settings.h"

// ============================================================
// Globals
// ============================================================

TFT_eSPI tft = TFT_eSPI();

// Runtime screen dimensions (defined here, declared extern in config.h)
uint16_t SCREEN_WIDTH  = DISPLAY_SHORT_SIDE;   // Default: Portrait 240
uint16_t SCREEN_HEIGHT = DISPLAY_LONG_SIDE;     // Default: Portrait 320

// LVGL display buffer (one 10-line strip, double-buffered)
static const uint32_t LV_BUF_SIZE = DISPLAY_SHORT_SIDE * 10;
static lv_color_t lv_buf1[LV_BUF_SIZE];
static lv_color_t lv_buf2[LV_BUF_SIZE];

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
// LVGL flush callback - sends pixels to TFT_eSPI
// ============================================================
static void disp_flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    uint32_t w = (area->x2 - area->x1 + 1);
    uint32_t h = (area->y2 - area->y1 + 1);

    tft.startWrite();
    tft.setAddrWindow(area->x1, area->y1, w, h);
    tft.pushColors((uint16_t *)px_map, w * h, true);
    tft.endWrite();

    lv_display_flush_ready(disp);
}

// ============================================================
// LVGL touch read callback - reads XPT2046
// ============================================================
static void touch_read_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    uint16_t x = 0, y = 0;
    bool touched = tft.getTouch(&x, &y);

    if (touched) {
        data->point.x = x;
        data->point.y = y;
        data->state = LV_INDEV_STATE_PRESSED;
    } else {
        data->state = LV_INDEV_STATE_RELEASED;
    }
}

// ============================================================
// Boot screen — direct TFT drawing (no LVGL!)
// ============================================================
static void draw_boot_screen(void)
{
    tft.fillScreen(TFT_BLACK);
    tft.setTextDatum(MC_DATUM);

    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.setFreeFont(nullptr);
    tft.setTextSize(2);
    tft.drawString("AI Usage Monitor", SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2 - 30);

    tft.setTextSize(1);
    tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
    tft.drawString("Initializing...", SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2 + 10);

    tft.setTextDatum(BR_DATUM);
    tft.drawString("v" APP_VERSION, SCREEN_WIDTH - 10, SCREEN_HEIGHT - 10);
}

// ============================================================
// Update boot status text on display (direct TFT)
// ============================================================
static void update_boot_status(const char *msg) {
    tft.fillRect(0, SCREEN_HEIGHT / 2, SCREEN_WIDTH, 30, TFT_BLACK);
    tft.setTextDatum(MC_DATUM);
    tft.setTextSize(1);
    tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
    tft.drawString(msg, SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2 + 10);
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
    Serial.setRxBufferSize(2048);
    Serial.begin(115200);
    delay(500);
    Serial.println("========================================");
    Serial.printf("%s v%s (USB-Serial)\n", APP_NAME, APP_VERSION);
    Serial.println("========================================");

    // --- Backlight on ---
    pinMode(PIN_TFT_BL, OUTPUT);
    digitalWrite(PIN_TFT_BL, HIGH);

    // --- TFT init ---
    tft.init();

    // Load orientation + theme from NVS
    config_load(g_config);

    // Apply persisted theme before creating UI
    ui_apply_theme(g_config.theme);

    const char *orient_name;
    switch (g_config.orientation) {
        case ORIENTATION_LANDSCAPE_LEFT:
            tft.setRotation(3);
            SCREEN_WIDTH  = DISPLAY_LONG_SIDE;
            SCREEN_HEIGHT = DISPLAY_SHORT_SIDE;
            orient_name = "landscape_left";
            break;
        case ORIENTATION_LANDSCAPE_RIGHT:
            tft.setRotation(1);
            SCREEN_WIDTH  = DISPLAY_LONG_SIDE;
            SCREEN_HEIGHT = DISPLAY_SHORT_SIDE;
            orient_name = "landscape_right";
            break;
        case ORIENTATION_PORTRAIT:
        default:
            tft.setRotation(0);
            SCREEN_WIDTH  = DISPLAY_SHORT_SIDE;
            SCREEN_HEIGHT = DISPLAY_LONG_SIDE;
            orient_name = "portrait";
            break;
    }
    tft.fillScreen(TFT_BLACK);
    Serial.printf("[TFT] Display initialized (%ux%u %s)\n",
                  SCREEN_WIDTH, SCREEN_HEIGHT, orient_name);

    // --- Touch init ---
    if (g_config.orientation == ORIENTATION_LANDSCAPE_LEFT ||
        g_config.orientation == ORIENTATION_LANDSCAPE_RIGHT) {
        uint16_t calData[5] = { TOUCH_MIN_X, TOUCH_MAX_X, TOUCH_MIN_Y, TOUCH_MAX_Y, 5 };
        tft.setTouch(calData);
    } else {
        uint16_t calData[5] = { TOUCH_MIN_X, TOUCH_MAX_X, TOUCH_MIN_Y, TOUCH_MAX_Y, 2 };
        tft.setTouch(calData);
    }
    Serial.println("[Touch] XPT2046 initialized via TFT_eSPI");

    // --- LVGL init ---
    lv_init();
    lv_tick_set_cb([]() -> uint32_t { return (uint32_t)millis(); });
    Serial.println("[LVGL] Core initialized + tick callback registered");

    lv_disp = lv_display_create(SCREEN_WIDTH, SCREEN_HEIGHT);
    lv_display_set_flush_cb(lv_disp, disp_flush_cb);
    lv_display_set_buffers(lv_disp, lv_buf1, lv_buf2,
                           sizeof(lv_buf1), LV_DISPLAY_RENDER_MODE_PARTIAL);
    Serial.printf("[LVGL] Display driver registered (%ux%u)\n", SCREEN_WIDTH, SCREEN_HEIGHT);

    lv_touch = lv_indev_create();
    lv_indev_set_type(lv_touch, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(lv_touch, touch_read_cb);
    Serial.println("[LVGL] Touch input registered");

    // --- Boot screen ---
    draw_boot_screen();

    // --- Serial receiver init ---
    serial_receiver_init();
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
