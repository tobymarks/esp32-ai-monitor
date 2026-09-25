#include "touch_input.h"
#include "config.h"

#include <Arduino.h>
#include <SPI.h>

// On this board the XPT2046 is wired to HSPI, independently of the display.
// TFT_eSPI's getTouch() always uses its display SPI bus, even if TOUCH_MOSI,
// TOUCH_MISO and TOUCH_CLK are defined, so it cannot read this controller.
static SPIClass touch_spi(HSPI);
static SPISettings touch_settings(2000000, MSBFIRST, SPI_MODE0);

static uint16_t read_channel(uint8_t command) {
    touch_spi.transfer(command);
    touch_spi.transfer16(0); // discard the first conversion after channel change
    touch_spi.transfer(command);
    return touch_spi.transfer16(0) >> 3;
}

static uint16_t screen_coord(uint16_t raw, int16_t origin, int16_t maximum,
                             uint16_t size, bool invert) {
    int32_t value = (int32_t(raw) - origin) * (size - 1) / (maximum - origin);
    if (value < 0) value = 0;
    if (value >= size) value = size - 1;
    return invert ? size - 1 - value : value;
}

void touch_input_begin() {
    pinMode(PIN_TOUCH_CS, OUTPUT);
    digitalWrite(PIN_TOUCH_CS, HIGH);
    touch_spi.begin(PIN_TOUCH_CLK, PIN_TOUCH_MISO, PIN_TOUCH_MOSI, PIN_TOUCH_CS);
    Serial.println("[Touch] XPT2046 initialized on HSPI");
}

bool touch_input_read(uint16_t *x, uint16_t *y, uint8_t orientation) {
    touch_spi.beginTransaction(touch_settings);
    digitalWrite(PIN_TOUCH_CS, LOW);
    touch_spi.transfer(0xB0); // Z1
    int32_t z1 = touch_spi.transfer16(0xC0) >> 3; // Z2 conversion starts
    int32_t z2 = touch_spi.transfer16(0) >> 3;
    int32_t pressure = 4095 + z1 - z2;
    uint16_t raw_x = 0, raw_y = 0;
    if (pressure > 250) {
        raw_x = read_channel(0xD0);
        raw_y = read_channel(0x90);
    }
    digitalWrite(PIN_TOUCH_CS, HIGH);
    touch_spi.endTransaction();

    if (pressure <= 250 || raw_x < 100 || raw_x > 4000 ||
        raw_y < 100 || raw_y > 4000) return false;

    if (orientation == ORIENTATION_PORTRAIT) {
        *x = screen_coord(raw_x, TOUCH_MIN_X, TOUCH_MAX_X, SCREEN_WIDTH, true);
        *y = screen_coord(raw_y, TOUCH_MIN_Y, TOUCH_MAX_Y, SCREEN_HEIGHT, false);
    } else {
        // The XPT2046 axes are swapped in landscape. Both landscape
        // orientations use opposite X/Y directions; on this board a touch
        // near the upper right in landscape_right must map near (319, 0).
        const bool right = orientation == ORIENTATION_LANDSCAPE_RIGHT;
        // Kalibrierwerte gehören zur jeweiligen Rohachse, nicht zur Bildschirmachse.
        *x = screen_coord(raw_y, TOUCH_MIN_Y, TOUCH_MAX_Y, SCREEN_WIDTH, !right);
        *y = screen_coord(raw_x, TOUCH_MIN_X, TOUCH_MAX_X, SCREEN_HEIGHT, !right);
    }
    return true;
}
