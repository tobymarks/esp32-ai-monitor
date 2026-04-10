/**
 * AI Usage Monitor - ESP32-2432S028R (CYD 2.8")
 * Hello World: Display + Touch + LVGL v9
 *
 * Initializes TFT_eSPI, LVGL v9, and XPT2046 touch input,
 * then shows a simple startup screen.
 */

#include <Arduino.h>
#include <SPI.h>
#include <TFT_eSPI.h>
#include <XPT2046_Touchscreen.h>
#include <lvgl.h>
#include "config.h"

// ============================================================
// Globals
// ============================================================

TFT_eSPI tft = TFT_eSPI();

// Touch on HSPI with dedicated pins
SPIClass hspi(HSPI);
XPT2046_Touchscreen ts(PIN_TOUCH_CS);

// LVGL display buffer (one 10-line strip)
static const uint32_t LV_BUF_SIZE = SCREEN_WIDTH * 10;
static lv_color_t lv_buf1[LV_BUF_SIZE];
static lv_color_t lv_buf2[LV_BUF_SIZE];

// LVGL display and input device
static lv_display_t  *lv_disp = nullptr;
static lv_indev_t    *lv_touch = nullptr;

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
        // CYD in landscape: swap and invert as needed
        int16_t x = map(p.x, TOUCH_MIN_X, TOUCH_MAX_X, 0, SCREEN_WIDTH - 1);
        int16_t y = map(p.y, TOUCH_MIN_Y, TOUCH_MAX_Y, 0, SCREEN_HEIGHT - 1);

        // Constrain to screen bounds
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
// Build the startup UI
// ============================================================
static void create_startup_screen(void)
{
    // Get the active screen
    lv_obj_t *scr = lv_screen_active();

    // Dark background
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x1A1A2E), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);

    // Title label
    lv_obj_t *title = lv_label_create(scr);
    lv_label_set_text(title, APP_NAME);
    lv_obj_set_style_text_color(title, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_24, LV_PART_MAIN);
    lv_obj_align(title, LV_ALIGN_CENTER, 0, -20);

    // Status label
    lv_obj_t *status = lv_label_create(scr);
    lv_label_set_text(status, "Initializing...");
    lv_obj_set_style_text_color(status, lv_color_hex(0x888888), LV_PART_MAIN);
    lv_obj_set_style_text_font(status, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(status, LV_ALIGN_CENTER, 0, 20);

    // Version label (bottom right)
    lv_obj_t *ver = lv_label_create(scr);
    lv_label_set_text_fmt(ver, "v%s", APP_VERSION);
    lv_obj_set_style_text_color(ver, lv_color_hex(0x444444), LV_PART_MAIN);
    lv_obj_set_style_text_font(ver, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(ver, LV_ALIGN_BOTTOM_RIGHT, -10, -10);
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

    // --- Build UI ---
    create_startup_screen();
    Serial.println("[UI] Startup screen created");

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
    delay(5);            // Short yield
}
