/**
 * Board-Umsetzung: Guition ESP32-S3-4848S040 (4", 480x480)
 *
 * ST7701S als RGB-Panel mit 16 Bit parallel, Init ueber 3-Wire-SPI, GT911 am
 * I2C. Das Panel legen wir selbst ueber esp_lcd an, statt es Arduino_GFX zu
 * ueberlassen: Wir brauchen Zugriff auf Bounce Buffer, Bildanfang-Meldung und
 * Panel-Handle. Von Arduino_GFX nutzen wir nur den Bit-Bang-SPI und die
 * Init-Sequenz des ST7701S (st7701_type9).
 *
 * Werte aus dem Hardware-Test (hardware-test/esp32s3-4848s040/README.md):
 * 10 MHz Pixeltakt und 19200 px Bounce Buffer, rund 35 Bilder/s.
 */

#if defined(BOARD_S3_4848)

#include "board.h"
#include "config.h"

#include <Arduino.h>
#include <Wire.h>
#include <Arduino_GFX_Library.h>
#include <esp_lcd_panel_rgb.h>
#include <esp_lcd_panel_ops.h>
#include <esp_timer.h>
#include <esp_heap_caps.h>

// ============================================================
// Pins und Panel-Parameter
// ============================================================
static const int PIN_BL        = 38;
static const int PIN_TOUCH_SDA = 19;
static const int PIN_TOUCH_SCL = 45;

static const uint32_t PCLK_HZ         = 10000000;
static const size_t   BOUNCE_BUFFER_PX = 19200;  // 40 Zeilen im internen RAM

static const uint8_t  BL_RES_BITS = 8;
static const uint32_t BL_FREQ_HZ  = 1000;

static esp_lcd_panel_handle_t panel = nullptr;

// ============================================================
// Aussetzer-Zaehlung
// ------------------------------------------------------------
// Das Panel meldet jeden Bildanfang. Reisst der Nachschub aus dem PSRAM ab,
// dauert ein Bild deutlich laenger — genau dann verrutscht das Bild. Der
// Zaehler geht in die Diagnose, damit sich das im Feld nachsehen laesst,
// ohne dass jemand danebensteht.
// ============================================================
static const int64_t FRAME_US_NOMINAL =
    (int64_t)(548.0 * 518.0 * 1000000.0 / (double)PCLK_HZ);

static volatile uint32_t frame_glitches = 0;
static volatile int64_t  last_vsync_us = 0;

static bool IRAM_ATTR on_vsync(esp_lcd_panel_handle_t p,
                               const esp_lcd_rgb_panel_event_data_t *data, void *user)
{
    int64_t now = esp_timer_get_time();
    if (last_vsync_us != 0 && (now - last_vsync_us) > (FRAME_US_NOMINAL * 3) / 2) {
        frame_glitches++;
    }
    last_vsync_us = now;
    return false;
}

// ============================================================
// Touch: GT911, INT und RST sind auf diesem Board nicht angeschlossen
// ============================================================
static uint8_t gt_addr = 0;

static bool gt_read(uint16_t reg, uint8_t *buf, size_t len)
{
    Wire.beginTransmission(gt_addr);
    Wire.write((uint8_t)(reg >> 8));
    Wire.write((uint8_t)(reg & 0xFF));
    if (Wire.endTransmission(true) != 0) return false;
    if (Wire.requestFrom((uint16_t)gt_addr, (size_t)len, true) != len) return false;
    for (size_t i = 0; i < len; i++) buf[i] = Wire.read();
    return true;
}

static void gt_clear_status()
{
    Wire.beginTransmission(gt_addr);
    Wire.write(0x81);
    Wire.write(0x4E);
    Wire.write((uint8_t)0);
    Wire.endTransmission(true);
}

static void gt_init()
{
    Wire.begin(PIN_TOUCH_SDA, PIN_TOUCH_SCL);
    Wire.setClock(400000);

    // Ohne RST-Leitung entscheidet der Pegel beim Einschalten ueber die
    // Adresse — beide moeglichen probieren.
    const uint8_t candidates[] = {0x5D, 0x14};
    for (uint8_t addr : candidates) {
        Wire.beginTransmission(addr);
        if (Wire.endTransmission(true) == 0) {
            gt_addr = addr;
            break;
        }
    }
    if (gt_addr == 0) {
        Serial.println("[Touch] GT911 nicht gefunden (weder 0x5D noch 0x14)");
        return;
    }
    Serial.printf("[Touch] GT911 an 0x%02X\n", gt_addr);
}

// ============================================================
// Display
// ============================================================
void board_display_init()
{
    // 1. Init-Sequenz des ST7701S ueber den Bit-Bang-SPI schicken.
    Arduino_DataBus *bus = new Arduino_SWSPI(
        GFX_NOT_DEFINED /* DC */, 39 /* CS */,
        48 /* SCK */, 47 /* MOSI */, GFX_NOT_DEFINED /* MISO */);
    bus->begin();
    bus->batchOperation(st7701_type9_init_operations, sizeof(st7701_type9_init_operations));

    // 2. RGB-Panel selbst anlegen.
    esp_lcd_rgb_panel_config_t cfg = {};
    cfg.clk_src = LCD_CLK_SRC_DEFAULT;
    cfg.timings.pclk_hz           = PCLK_HZ;
    cfg.timings.h_res             = DISPLAY_SHORT_SIDE;
    cfg.timings.v_res             = DISPLAY_LONG_SIDE;
    cfg.timings.hsync_pulse_width = 8;
    cfg.timings.hsync_back_porch  = 50;
    cfg.timings.hsync_front_porch = 10;
    cfg.timings.vsync_pulse_width = 8;
    cfg.timings.vsync_back_porch  = 20;
    cfg.timings.vsync_front_porch = 10;
    cfg.timings.flags.pclk_active_neg = 0;
    cfg.data_width       = 16;
    cfg.bits_per_pixel   = 16;
    cfg.num_fbs          = 1;
    cfg.bounce_buffer_size_px = BOUNCE_BUFFER_PX;
    cfg.sram_trans_align  = 8;
    cfg.psram_trans_align = 64;
    cfg.hsync_gpio_num = 16;
    cfg.vsync_gpio_num = 17;
    cfg.de_gpio_num    = 18;
    cfg.pclk_gpio_num  = 21;
    cfg.disp_gpio_num  = GPIO_NUM_NC;
    const int data_pins[16] = {
        4, 5, 6, 7, 15,            // B0..B4
        8, 20, 3, 46, 9, 10,       // G0..G5
        11, 12, 13, 14, 0,         // R0..R4
    };
    for (int i = 0; i < 16; i++) cfg.data_gpio_nums[i] = data_pins[i];
    cfg.flags.fb_in_psram = true;

    esp_err_t err = esp_lcd_new_rgb_panel(&cfg, &panel);
    if (err != ESP_OK) {
        Serial.printf("[Display] esp_lcd_new_rgb_panel: %s\n", esp_err_to_name(err));
        return;
    }
    esp_lcd_panel_reset(panel);
    esp_lcd_panel_init(panel);

    esp_lcd_rgb_panel_event_callbacks_t cbs = {};
    cbs.on_vsync = on_vsync;
    esp_lcd_rgb_panel_register_event_callbacks(panel, &cbs, nullptr);

    Serial.printf("[Display] ST7701S bereit, %u Hz Pixeltakt, %u px Bounce Buffer\n",
                  (unsigned)PCLK_HZ, (unsigned)BOUNCE_BUFFER_PX);

    gt_init();
}

const char* board_display_id()
{
    return DISPLAY_ID;
}

// Das Panel sitzt ungedreht richtig herum, wenn USB rechts liegt
// (Markierung oben links, im Hardware-Test geprueft). Die Apps beschreiben die
// Ausrichtung ueber die Lage des USB-Anschlusses; daraus folgt die Drehung,
// die LVGL in Software macht (das RGB-Panel kann nicht selbst drehen):
//   USB rechts -> 0 Grad, USB unten (Hochformat) -> 90 Grad, USB links -> 180 Grad.
static lv_display_rotation_t sw_rotation = LV_DISPLAY_ROTATION_90;

void board_set_rotation(uint8_t orientation)
{
    switch (orientation) {
        case ORIENTATION_LANDSCAPE_RIGHT: sw_rotation = LV_DISPLAY_ROTATION_0;   break;
        case ORIENTATION_LANDSCAPE_LEFT:  sw_rotation = LV_DISPLAY_ROTATION_180; break;
        case ORIENTATION_PORTRAIT:
        default:                          sw_rotation = LV_DISPLAY_ROTATION_90;  break;
    }
    // Quadratisch: die Masse bleiben bei jeder Drehung gleich.
    SCREEN_WIDTH  = DISPLAY_SHORT_SIDE;
    SCREEN_HEIGHT = DISPLAY_LONG_SIDE;
}

lv_display_rotation_t board_lvgl_rotation()
{
    return sw_rotation;
}

void board_fill_black()
{
    if (panel == nullptr) return;
    // Eine schwarze Zeile wiederholt schreiben spart einen Vollbild-Puffer.
    static uint16_t *line = nullptr;
    if (line == nullptr) {
        line = (uint16_t *)heap_caps_calloc(DISPLAY_SHORT_SIDE, sizeof(uint16_t), MALLOC_CAP_DMA);
        if (line == nullptr) return;
    }
    for (int y = 0; y < DISPLAY_LONG_SIDE; y++) {
        esp_lcd_panel_draw_bitmap(panel, 0, y, DISPLAY_SHORT_SIDE, y + 1, line);
    }
}

// Zielpuffer fuer gedrehte Ausschnitte, so gross wie ein LVGL-Zeichenpuffer.
static uint8_t *rotate_buf = nullptr;
static uint32_t rotate_buf_bytes = 0;

void board_flush(const lv_area_t *area, uint8_t *px_map)
{
    if (panel == nullptr) return;
    lv_display_t *disp = lv_display_get_default();
    const lv_display_rotation_t rotation = disp ? lv_display_get_rotation(disp) : LV_DISPLAY_ROTATION_0;
    if (rotation == LV_DISPLAY_ROTATION_0 || rotate_buf == nullptr) {
        esp_lcd_panel_draw_bitmap(panel, area->x1, area->y1,
                                  area->x2 + 1, area->y2 + 1, px_map);
        return;
    }

    // LVGL zeichnet in logischen Koordinaten; Ausschnitt und Pixel hier auf
    // die Lage des Panels drehen (siehe LVGL-Doku zu lv_display_set_rotation).
    lv_area_t rotated = *area;
    lv_display_rotate_area(disp, &rotated);
    const int32_t src_w = lv_area_get_width(area);
    const int32_t src_h = lv_area_get_height(area);
    const uint32_t src_stride  = lv_draw_buf_width_to_stride(src_w, LV_COLOR_FORMAT_RGB565);
    const uint32_t dest_stride = lv_draw_buf_width_to_stride(lv_area_get_width(&rotated), LV_COLOR_FORMAT_RGB565);
    if ((uint32_t)src_w * src_h * 2 > rotate_buf_bytes) return;
    lv_draw_sw_rotate(px_map, rotate_buf, src_w, src_h, src_stride, dest_stride,
                      rotation, LV_COLOR_FORMAT_RGB565);
    esp_lcd_panel_draw_bitmap(panel, rotated.x1, rotated.y1,
                              rotated.x2 + 1, rotated.y2 + 1, rotate_buf);
}

// Der GT911 meldet nur, wenn sich etwas geaendert hat. LVGL fragt dagegen in
// festem Takt und erwartet den aktuellen Zustand: Wuerden wir zwischen zwei
// Meldungen "losgelassen" liefern, zerfiele jeder Tipp in viele kurze, und
// weder Klicks noch der lange Druck aufs Dashboard funktionierten zuverlaessig.
// Deshalb halten wir den letzten Zustand, bis der Controller einen neuen meldet.
static bool     touch_down = false;
static uint16_t touch_x = 0, touch_y = 0;

bool board_touch_read(uint16_t *x, uint16_t *y)
{
    if (gt_addr == 0) return false;

    uint8_t status = 0;
    if (gt_read(0x814E, &status, 1) && (status & 0x80)) {
        uint8_t points = status & 0x0F;
        if (points > 0 && points <= 5) {
            uint8_t p[4];
            if (gt_read(0x8150, p, 4)) {
                touch_x = p[0] | (p[1] << 8);
                touch_y = p[2] | (p[3] << 8);
                touch_down = true;
            }
        } else {
            touch_down = false;
        }
        gt_clear_status();
    }

    *x = touch_x;
    *y = touch_y;
    return touch_down;
}

void board_lvgl_buffers(void **buf1, void **buf2, uint32_t *size_bytes)
{
    // 40 Zeilen je Puffer im PSRAM. Klein genug, dass LVGL zuegig flusht,
    // gross genug, dass die Balken und Ringe in wenigen Stuecken rausgehen.
    const uint32_t px = DISPLAY_SHORT_SIDE * 40;
    const uint32_t bytes = px * sizeof(lv_color_t);
    *buf1 = heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM);
    *buf2 = heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM);
    *size_bytes = bytes;
    // Fuer die Software-Drehung ein dritter Puffer gleicher Groesse.
    rotate_buf = (uint8_t *)heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM);
    rotate_buf_bytes = rotate_buf ? bytes : 0;
    Serial.printf("[LVGL] Zeichenpuffer 2 x %u KB im PSRAM\n", (unsigned)(bytes / 1024));
}

void board_backlight_init()
{
    ledcAttach(PIN_BL, BL_FREQ_HZ, BL_RES_BITS);
    ledcWrite(PIN_BL, 255);
    Serial.printf("[BL] PWM an Pin %d, %u Hz\n", PIN_BL, (unsigned)BL_FREQ_HZ);
}

void board_backlight_set_percent(uint8_t pct)
{
    if (pct < BRIGHTNESS_MIN_PERCENT) pct = BRIGHTNESS_MIN_PERCENT;
    if (pct > BRIGHTNESS_MAX_PERCENT) pct = BRIGHTNESS_MAX_PERCENT;
    ledcWrite(PIN_BL, (uint32_t)pct * 255u / 100u);
}

bool board_persists_config()
{
    // Nein: siehe board.h. Schreibzugriffe ins Flash verschieben das Bild
    // dauerhaft, die Einstellungen kommen vom Host.
    return false;
}

uint32_t board_frame_glitches()
{
    return frame_glitches;
}

#endif // BOARD_S3_4848
