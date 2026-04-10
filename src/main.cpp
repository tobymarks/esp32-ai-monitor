/**
 * AI Usage Monitor - ESP32-2432S028R (CYD 2.8")
 * Phase 4: LVGL Dashboard UI (v0.4.0)
 *
 * Boot sequence:
 * 1. Init display + touch + LVGL
 * 2. Show "Connecting..." screen
 * 3. WiFi setup (stored creds or AP portal)
 * 4. NTP time sync
 * 5. Start AsyncWebServer
 * 6. Show QR code for config URL (8 seconds)
 * 7. Check API keys: if none -> Setup screen, else -> Dashboard + fetch
 * 8. Main loop: periodic fetch + UI update
 *
 * Navigation:
 *   Dashboard (default) -> tap provider card -> Detail screen
 *   Dashboard -> long press (>1s) -> Settings screen
 *   Detail / Settings -> tap back arrow -> Dashboard
 */

#include <Arduino.h>
#include <SPI.h>
#include <TFT_eSPI.h>
#include <XPT2046_Touchscreen.h>
#include <lvgl.h>
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

// Touch on HSPI with dedicated pins
SPIClass hspi(HSPI);
XPT2046_Touchscreen ts(PIN_TOUCH_CS);

// LVGL display buffer (one 10-line strip, double-buffered)
static const uint32_t LV_BUF_SIZE = SCREEN_WIDTH * 10;
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
static const unsigned long UI_UPDATE_INTERVAL = 5000;  // Update display every 5s (time-ago, clock)

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
    if (ts.touched()) {
        TS_Point p = ts.getPoint();

        // Map raw touch coordinates to screen coordinates
        int16_t x = map(p.x, TOUCH_MIN_X, TOUCH_MAX_X, 0, SCREEN_WIDTH - 1);
        int16_t y = map(p.y, TOUCH_MIN_Y, TOUCH_MAX_Y, 0, SCREEN_HEIGHT - 1);

        x = constrain(x, 0, SCREEN_WIDTH - 1);
        y = constrain(y, 0, SCREEN_HEIGHT - 1);

        data->point.x = x;
        data->point.y = y;
        data->state = LV_INDEV_STATE_PRESSED;
    } else {
        data->state = LV_INDEV_STATE_RELEASED;
    }
}

// ============================================================
// Boot screen with progress info
// ============================================================
static void create_boot_screen(void)
{
    lv_obj_t *scr = lv_screen_active();

    lv_obj_set_style_bg_color(scr, lv_color_hex(COLOR_BG), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);

    // Title
    lv_obj_t *title = lv_label_create(scr);
    lv_label_set_text(title, APP_NAME);
    lv_obj_set_style_text_color(title, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_24, LV_PART_MAIN);
    lv_obj_align(title, LV_ALIGN_CENTER, 0, -30);

    // Status label (updated during boot)
    boot_status_label = lv_label_create(scr);
    lv_label_set_text(boot_status_label, "Initializing...");
    lv_obj_set_style_text_color(boot_status_label, lv_color_hex(0x666666), LV_PART_MAIN);
    lv_obj_set_style_text_font(boot_status_label, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(boot_status_label, LV_ALIGN_CENTER, 0, 10);

    // Version
    lv_obj_t *ver = lv_label_create(scr);
    lv_label_set_text_fmt(ver, "v%s", APP_VERSION);
    lv_obj_set_style_text_color(ver, lv_color_hex(0x444444), LV_PART_MAIN);
    lv_obj_set_style_text_font(ver, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(ver, LV_ALIGN_BOTTOM_RIGHT, -10, -10);
}

// ============================================================
// Update boot status text on display
// ============================================================
static void update_boot_status(const char *msg) {
    if (boot_status_label != nullptr) {
        lv_label_set_text(boot_status_label, msg);
        lv_timer_handler();  // Force display update
        delay(5);
    }
    Serial.printf("[Boot] %s\n", msg);
}

// ============================================================
// Check if any API keys are configured
// ============================================================
static bool has_api_keys(void) {
    return (strlen(g_config.anthropic_key) > 0 || strlen(g_config.openai_key) > 0);
}

// ============================================================
// Transition from QR to main UI (dashboard or setup)
// ============================================================
static void enter_main_ui(void) {
    if (has_api_keys()) {
        // Create and show dashboard
        ui_dashboard_create();
        ui_dashboard_load();
        dashboard_active = true;

        // Trigger immediate first update with current state
        const MonitorState &state = api_manager_get_state();
        ui_dashboard_update(state);

        Serial.println("[UI] Dashboard active");
    } else {
        // Show setup hint screen
        ui_setup_create();
        dashboard_active = false;

        Serial.println("[UI] Setup screen — no API keys");
    }
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
    tft.setRotation(1);  // Landscape
    tft.fillScreen(TFT_BLACK);
    Serial.println("[TFT] Display initialized (320x240 landscape)");

    // --- Touch init (HSPI) ---
    hspi.begin(PIN_TOUCH_CLK, PIN_TOUCH_MISO, PIN_TOUCH_MOSI, PIN_TOUCH_CS);
    ts.begin(hspi);
    ts.setRotation(1);
    Serial.println("[Touch] XPT2046 initialized on HSPI");

    // --- LVGL init ---
    lv_init();
    Serial.println("[LVGL] Core initialized");

    // Create display
    lv_disp = lv_display_create(SCREEN_WIDTH, SCREEN_HEIGHT);
    lv_display_set_flush_cb(lv_disp, disp_flush_cb);
    lv_display_set_buffers(lv_disp, lv_buf1, lv_buf2,
                           sizeof(lv_buf1), LV_DISPLAY_RENDER_MODE_PARTIAL);
    Serial.println("[LVGL] Display driver registered");

    // Create touch input device
    lv_touch = lv_indev_create();
    lv_indev_set_type(lv_touch, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(lv_touch, touch_read_cb);
    Serial.println("[LVGL] Touch input registered");

    // --- Boot screen ---
    create_boot_screen();
    lv_timer_handler();
    delay(10);

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

        // --- Show QR Code ---
        String url = webserver_get_url();
        update_boot_status("Ready!");
        delay(500);

        qr_display_show(url);
        qr_show_time = millis();

        // --- Init API Manager ---
        api_manager_init();

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

    // Switch from QR code to main UI after timeout
    if (qr_display_is_visible() && (millis() - qr_show_time > QR_DISPLAY_DURATION)) {
        qr_display_hide();
        enter_main_ui();
    }

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
