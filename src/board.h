#ifndef BOARD_H
#define BOARD_H

#include <stdint.h>
#include <lvgl.h>

// ============================================================
// Board-Schnittstelle
// ------------------------------------------------------------
// Alles, was die Firmware an Hardware anfasst, laeuft ueber diese Funktionen.
// Es gibt genau eine Umsetzung pro Board-Familie:
//
//   board_cyd.cpp  — ESP32, SPI-Panel (ILI9341 oder ST7789), XPT2046-Touch
//   board_s3.cpp   — ESP32-S3, RGB-Panel (ST7701S, 480x480), GT911-Touch
//
// Welche gebaut wird, entscheidet ein Build-Flag aus platformio.ini
// (BOARD_CYD bzw. BOARD_S3_4848). Der Rest der Firmware kennt kein
// TFT_eSPI und kein esp_lcd mehr.
// ============================================================

// Panel und Touch hochfahren. Muss vor allem anderen laufen.
void board_display_init();

// Kennung fuer das `display`-Feld in get_info ("ili9341", "st7789", "st7701").
const char* board_display_id();

// Drehung setzen; aktualisiert SCREEN_WIDTH und SCREEN_HEIGHT (config.h).
void board_set_rotation(uint8_t orientation);

// Ganzen Bildschirm schwarz fuellen (Boot, Orientierungswechsel).
void board_fill_black();

// LVGL-Flush: einen Bildausschnitt ausgeben.
void board_flush(const lv_area_t *area, uint8_t *px_map);

// Beruehrpunkt in Bildschirmkoordinaten lesen. false = kein Kontakt.
bool board_touch_read(uint16_t *x, uint16_t *y);

// Zeichenpuffer fuer LVGL. Groesse und Ort haengen am Board: die CYDs
// zeichnen in kleinen Streifen im SRAM, das RGB-Panel in grossen im PSRAM.
void board_lvgl_buffers(void **buf1, void **buf2, uint32_t *size_bytes);

// Hintergrundbeleuchtung (PWM).
void board_backlight_init();
void board_backlight_set_percent(uint8_t pct);

// Speichert dieses Board Einstellungen dauerhaft?
//
// Auf dem S3-Board nicht: Waehrend ins Flash geschrieben wird, ist der Cache
// abgeschaltet und der RGB-Treiber kommt nicht an den Framebuffer im PSRAM.
// Das Bild verrutscht dann dauerhaft und laesst sich nur durch einen Neustart
// geraderuecken (Messung: hardware-test/esp32s3-4848s040/README.md). Die
// Einstellungen kommen dort bei jedem Verbinden vom Host.
bool board_persists_config();

// Diagnose: Bildaussetzer seit dem Start. Nur das RGB-Panel kann das messen,
// die SPI-Boards melden immer 0.
uint32_t board_frame_glitches();

#endif // BOARD_H
