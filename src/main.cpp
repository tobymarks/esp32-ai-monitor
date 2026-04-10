/**
 * AI Usage Monitor - ESP32-2432S028R (CYD 2.8")
 * Phase 6: Vibe-TV-Style Dashboard
 *
 * Boot sequence:
 * 1. Init display + touch + LVGL
 * 2. Show "Connecting..." screen
 * 3. WiFi setup (stored creds or AP portal)
 * 4. NTP time sync
 * 5. Start AsyncWebServer
 * 6. Show QR code for config URL (8 seconds)
 * 7. Check token: if none -> Setup screen, else -> Dashboard + fetch
 * 8. Main loop: periodic fetch + UI update (1s interval for live countdown)
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
#include "wifi_setup.h"
#include "ntp_time.h"
#include "web_server.h"
#include "qr_display.h"
#include "api_manager.h"
#include "ui_common.h"
#include "ui_dashboard.h"
#include "ui_detail.h"
#include "ui_settings.h"
#include "ui_setup.h"

// ============================================================
// Globals
// ============================================================

TFT_eSPI tft = TFT_eSPI();

// Runtime screen dimensions (defined here, declared extern in config.h)
uint16_t SCREEN_WIDTH  = DISPLAY_SHORT_SIDE;   // Default: Portrait 240
uint16_t SCREEN_HEIGHT = DISPLAY_LONG_SIDE;     // Default: Portrait 320

// Touch calibration data (populated by tft.calibrateTouch() or defaults)

// LVGL display buffer (one 10-line strip, double-buffered)
// Use short side (240) * 10 — fits both orientations
static const uint32_t LV_BUF_SIZE = DISPLAY_SHORT_SIDE * 10;
static lv_color_t lv_buf1[LV_BUF_SIZE];
static lv_color_t lv_buf2[LV_BUF_SIZE];

// LVGL display and input device
static lv_display_t  *lv_disp = nullptr;
static lv_indev_t    *lv_touch = nullptr;

// Status label for boot progress
static lv_obj_t *boot_status_label = nullptr;

// Timing for QR display
static unsigned long qr_show_time = 0;
static const unsigned long QR_DISPLAY_DURATION = 8000;  // 8 seconds

// Dashboard state
static bool dashboard_active = false;
static unsigned long last_ui_update = 0;
static const unsigned long UI_UPDATE_INTERVAL = 1000;  // 1s interval for live countdown + clock

// Heap monitoring
static unsigned long lastHeapLog = 0;

// External config (defined in web_server.cpp)
extern AppConfig g_config;

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
// LVGL default screen stays untouched so screen transitions work.
// ============================================================
static void draw_boot_screen(void)
{
    tft.fillScreen(TFT_BLACK);
    tft.setTextDatum(MC_DATUM);  // Middle-center alignment

    // Title
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.setFreeFont(nullptr);
    tft.setTextSize(2);
    tft.drawString("AI Usage Monitor", SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2 - 30);

    // Status
    tft.setTextSize(1);
    tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
    tft.drawString("Initializing...", SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2 + 10);

    // Version
    tft.setTextDatum(BR_DATUM);  // Bottom-right
    tft.drawString("v" APP_VERSION, SCREEN_WIDTH - 10, SCREEN_HEIGHT - 10);
}

// ============================================================
// Update boot status text on display (direct TFT)
// ============================================================
static void update_boot_status(const char *msg) {
    // Clear status area and redraw
    tft.fillRect(0, SCREEN_HEIGHT / 2, SCREEN_WIDTH, 30, TFT_BLACK);
    tft.setTextDatum(MC_DATUM);
    tft.setTextSize(1);
    tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
    tft.drawString(msg, SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2 + 10);
    Serial.printf("[Boot] %s\n", msg);
}

// ============================================================
// Check if a valid access token is configured
// ============================================================
static bool has_valid_token(void) {
    return (strlen(g_config.access_token) > 0);
}

// ============================================================
// Transition from QR to main UI (dashboard or setup)
// ============================================================
static void enter_main_ui(void) {
    // Boot screen was drawn with direct TFT calls (no LVGL).
    // LVGL's default screen is still clean/empty.
    // Creating and loading a new LVGL screen will overwrite the TFT content.

    if (has_valid_token()) {
        ui_dashboard_create();
        // Direct screen load — no fade animation from white default screen
        lv_obj_t *dash_scr = ui_dashboard_get_screen();
        if (dash_scr) {
            lv_screen_load(dash_scr);
        }
        dashboard_active = true;

        const MonitorState &state = api_manager_get_state();
        ui_dashboard_update(state);

        Serial.println("[UI] Dashboard active");
    } else {
        ui_setup_create();
        dashboard_active = false;

        Serial.println("[UI] Setup screen — kein Token konfiguriert");
    }

    // Force LVGL to render the new screen immediately
    lv_refr_now(NULL);
}

// ============================================================
// Setup
// ============================================================
void setup()
{
    Serial.begin(115200);
    delay(500);
    Serial.println("========================================");
    Serial.printf("%s v%s\n", APP_NAME, APP_VERSION);
    Serial.println("========================================");

    // --- Backlight on ---
    pinMode(PIN_TFT_BL, OUTPUT);
    digitalWrite(PIN_TFT_BL, HIGH);

    // --- TFT init ---
    tft.init();

    // Set rotation based on saved orientation config
    // (config_load is called later by wifi_setup_init, so we do a quick NVS read here)
    {
        Preferences orientPrefs;
        orientPrefs.begin(NVS_NAMESPACE, true);
        g_config.orientation = orientPrefs.getUChar("orient", ORIENTATION_PORTRAIT);
        orientPrefs.end();
    }

    if (g_config.orientation == ORIENTATION_LANDSCAPE) {
        tft.setRotation(1);   // Landscape: 320x240, USB left
        SCREEN_WIDTH  = DISPLAY_LONG_SIDE;
        SCREEN_HEIGHT = DISPLAY_SHORT_SIDE;
    } else {
        tft.setRotation(2);   // Portrait: 240x320, USB bottom
        SCREEN_WIDTH  = DISPLAY_SHORT_SIDE;
        SCREEN_HEIGHT = DISPLAY_LONG_SIDE;
    }
    tft.fillScreen(TFT_BLACK);
    Serial.printf("[TFT] Display initialized (%ux%u %s)\n",
                  SCREEN_WIDTH, SCREEN_HEIGHT,
                  g_config.orientation == ORIENTATION_LANDSCAPE ? "landscape" : "portrait");

    // --- Touch init (via TFT_eSPI built-in XPT2046 support) ---
    // calData[4] = rotation swap flag: 1 for landscape, 7 for portrait rotation(2)
    if (g_config.orientation == ORIENTATION_LANDSCAPE) {
        uint16_t calData[5] = { TOUCH_MIN_X, TOUCH_MAX_X, TOUCH_MIN_Y, TOUCH_MAX_Y, 1 };
        tft.setTouch(calData);
    } else {
        uint16_t calData[5] = { TOUCH_MIN_X, TOUCH_MAX_X, TOUCH_MIN_Y, TOUCH_MAX_Y, 7 };
        tft.setTouch(calData);
    }
    Serial.println("[Touch] XPT2046 initialized via TFT_eSPI");

    // --- LVGL init ---
    lv_init();
    Serial.println("[LVGL] Core initialized");

    // Create display with runtime dimensions
    lv_disp = lv_display_create(SCREEN_WIDTH, SCREEN_HEIGHT);
    lv_display_set_flush_cb(lv_disp, disp_flush_cb);
    lv_display_set_buffers(lv_disp, lv_buf1, lv_buf2,
                           sizeof(lv_buf1), LV_DISPLAY_RENDER_MODE_PARTIAL);
    Serial.printf("[LVGL] Display driver registered (%ux%u)\n", SCREEN_WIDTH, SCREEN_HEIGHT);

    // Create touch input device
    lv_touch = lv_indev_create();
    lv_indev_set_type(lv_touch, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(lv_touch, touch_read_cb);
    Serial.println("[LVGL] Touch input registered");

    // --- Boot screen (direct TFT, no LVGL) ---
    draw_boot_screen();

    // --- WiFi Setup ---
    update_boot_status("Connecting to WiFi...");
    bool wifiOk = wifi_setup_init();

    if (wifiOk) {
        // --- NTP Time Sync ---
        update_boot_status("Syncing time...");
        ntp_init();

        // --- Start Web Server ---
        update_boot_status("Starting web server...");
        webserver_init();

        // --- Go to main UI ---
        String url = webserver_get_url();
        update_boot_status("Ready!");
        delay(500);

        // --- Init API Manager ---
        api_manager_init();

        // Enter dashboard or setup screen directly
        enter_main_ui();

        Serial.printf("[System] Config URL: %s\n", url.c_str());
        Serial.printf("[System] mDNS: http://%s.local/\n", MDNS_HOSTNAME);
    } else {
        update_boot_status("WiFi failed! Rebooting...");
        delay(3000);
        ESP.restart();
    }

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
    lv_timer_handler();  // Let LVGL do its work

    // WiFi reconnect check (every 10 seconds internally)
    wifi_check_connection();

    // API polling (checks interval internally)
    api_manager_tick();

    // Update dashboard UI
    if (dashboard_active) {
        const MonitorState &state = api_manager_get_state();

        // Update UI when fetch just completed (state changed from fetching to idle)
        static bool was_fetching = false;
        if (was_fetching && !state.is_fetching) {
            ui_dashboard_update(state);
        }
        was_fetching = state.is_fetching;

        // Periodic UI refresh (time-ago counter, clock, status dot)
        unsigned long now = millis();
        if (now - last_ui_update >= UI_UPDATE_INTERVAL) {
            last_ui_update = now;
            ui_dashboard_update(state);
        }
    }

    // Periodic heap monitoring (every 60 seconds)
    if (millis() - lastHeapLog > 60000) {
        lastHeapLog = millis();
        Serial.printf("[Heap] Free: %u  Min: %u\n",
                      ESP.getFreeHeap(), ESP.getMinFreeHeap());
    }

    delay(5);  // Short yield
}
