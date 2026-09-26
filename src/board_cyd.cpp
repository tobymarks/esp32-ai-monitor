/**
 * Board-Umsetzung: CYD (ESP32-2432S028 / -S028R)
 *
 * SPI-Panel (ILI9341 oder ST7789, per Build-Flag) ueber TFT_eSPI, XPT2046-Touch
 * auf eigenem HSPI-Bus ueber touch_input.cpp (TFT_eSPI kann ihn nicht lesen). Der Code stammt unveraendert aus main.cpp v2.17.0; die
 * muehsam ermittelten Panel-Einstellungen (BGR, keine Inversion, Backlight
 * ueber eigenen LEDC-Channel) bleiben genau so, wie sie waren.
 */

#if defined(BOARD_CYD)

#include "board.h"
#include "config.h"
#include "touch_input.h"

#include <Arduino.h>
#include <SPI.h>
#include <TFT_eSPI.h>

static TFT_eSPI tft = TFT_eSPI();
// Der Touch-Treiber rechnet die Koordinaten selbst passend zur Drehung um.
static uint8_t touch_orientation = ORIENTATION_PORTRAIT;

// LVGL-Puffer: ein Streifen ueber 10 Zeilen, doppelt. Klein genug fuer den
// internen Speicher, gross genug, dass LVGL nicht in Winzstuecken flusht.
static const uint32_t LV_BUF_PX = DISPLAY_SHORT_SIDE * 10;
static lv_color_t lv_buf1[LV_BUF_PX];
static lv_color_t lv_buf2[LV_BUF_PX];

void board_display_init()
{
    // Wichtig: tft.init() laeuft vor dem LEDC-Attach des Backlights, damit die
    // SPI-Peripherie samt Panel-Reset sauber hochkommt.
    tft.init();

    // Deterministischer Reset des INVON/INVOFF-Registers: fruehere Farbtests
    // koennten die Inversion sonst persistent im Panel haengen lassen.
    tft.invertDisplay(false);

    touch_input_begin();
}

const char* board_display_id()
{
    return DISPLAY_ID;
}

void board_set_rotation(uint8_t orientation)
{
    switch (orientation) {
        case ORIENTATION_LANDSCAPE_LEFT:
            tft.setRotation(3);
            SCREEN_WIDTH  = DISPLAY_LONG_SIDE;
            SCREEN_HEIGHT = DISPLAY_SHORT_SIDE;
            break;
        case ORIENTATION_LANDSCAPE_RIGHT:
            tft.setRotation(1);
            SCREEN_WIDTH  = DISPLAY_LONG_SIDE;
            SCREEN_HEIGHT = DISPLAY_SHORT_SIDE;
            break;
        case ORIENTATION_PORTRAIT:
        default:
            tft.setRotation(0);
            SCREEN_WIDTH  = DISPLAY_SHORT_SIDE;
            SCREEN_HEIGHT = DISPLAY_LONG_SIDE;
            break;
    }
    touch_orientation = orientation;
}

lv_display_rotation_t board_lvgl_rotation()
{
    return LV_DISPLAY_ROTATION_0;   // TFT_eSPI dreht im Panel
}

void board_fill_black()
{
    tft.fillScreen(TFT_BLACK);
}

void board_flush(const lv_area_t *area, uint8_t *px_map)
{
    uint32_t w = (area->x2 - area->x1 + 1);
    uint32_t h = (area->y2 - area->y1 + 1);

    tft.startWrite();
    tft.setAddrWindow(area->x1, area->y1, w, h);
    // LVGL legt RGB565 in Host-Byte-Reihenfolge ab, TFT_eSPI schiebt MSB
    // zuerst raus. Die RGB/BGR-Reihenfolge des Panels kommt per Build-Flag
    // (TFT_RGB_ORDER) aus platformio.ini.
    tft.pushColors((uint16_t *)px_map, w * h, true);
    tft.endWrite();
}

bool board_touch_read(uint16_t *x, uint16_t *y)
{
    return touch_input_read(x, y, touch_orientation);
}

void board_lvgl_buffers(void **buf1, void **buf2, uint32_t *size_bytes)
{
    *buf1 = lv_buf1;
    *buf2 = lv_buf2;
    *size_bytes = sizeof(lv_buf1);
}

void board_backlight_init()
{
    // Reihenfolge: ledcSetup -> ledcAttachPin -> ledcWrite. Kein pinMode oder
    // digitalWrite danach, das wuerde den Pin wieder aus dem PWM-Modus reissen.
    // Channel 7 statt 0, um TFT_eSPI-internen Channels aus dem Weg zu gehen.
    ledcSetup(BACKLIGHT_LEDC_CHANNEL, BACKLIGHT_LEDC_FREQ_HZ, BACKLIGHT_LEDC_RES_BITS);
    ledcAttachPin(PIN_TFT_BL, BACKLIGHT_LEDC_CHANNEL);
    ledcWrite(BACKLIGHT_LEDC_CHANNEL, 255);  // volle Helligkeit bis NVS geladen ist
    Serial.printf("[BL] LEDC attached: pin=%d ch=%d freq=%uHz res=%ubit duty=255\n",
                  PIN_TFT_BL, BACKLIGHT_LEDC_CHANNEL,
                  BACKLIGHT_LEDC_FREQ_HZ, BACKLIGHT_LEDC_RES_BITS);
}

void board_backlight_set_percent(uint8_t pct)
{
    if (pct < BRIGHTNESS_MIN_PERCENT) pct = BRIGHTNESS_MIN_PERCENT;
    if (pct > BRIGHTNESS_MAX_PERCENT) pct = BRIGHTNESS_MAX_PERCENT;
    ledcWrite(BACKLIGHT_LEDC_CHANNEL, (uint32_t)pct * 255u / 100u);
}

bool board_persists_config()
{
    return true;
}

uint32_t board_frame_glitches()
{
    return 0;
}

#endif // BOARD_CYD
