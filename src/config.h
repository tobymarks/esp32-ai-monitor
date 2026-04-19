#ifndef CONFIG_H
#define CONFIG_H

#include <stdint.h>

// ============================================================
// ESP32-2432S028R (CYD 2.8") Pin Configuration
// ============================================================

// App version
#define APP_VERSION "2.8.1"
#define APP_NAME    "AI Usage Monitor"

// --- Display (ILI9341 on VSPI) ---
#define PIN_TFT_MISO  12
#define PIN_TFT_MOSI  13
#define PIN_TFT_SCLK  14
#define PIN_TFT_CS    15
#define PIN_TFT_DC     2
#define PIN_TFT_RST   -1  // Connected to EN/reset
#define PIN_TFT_BL    21  // Backlight: HIGH = on

// --- Touch (XPT2046 on HSPI) ---
#define PIN_TOUCH_MOSI 32
#define PIN_TOUCH_MISO 39
#define PIN_TOUCH_CLK  25
#define PIN_TOUCH_CS   33
#define PIN_TOUCH_IRQ  36

// --- Onboard RGB LED ---
#define PIN_LED_R       4
#define PIN_LED_G      16
#define PIN_LED_B      17

// --- LDR (light sensor, active low) ---
#define PIN_LDR        34

// ============================================================
// Display dimensions (physical panel)
// ============================================================
#define DISPLAY_SHORT_SIDE 240
#define DISPLAY_LONG_SIDE  320

// Runtime screen dimensions (set in main.cpp based on orientation)
extern uint16_t SCREEN_WIDTH;
extern uint16_t SCREEN_HEIGHT;

// ============================================================
// Touch calibration defaults (raw ADC values)
// Adjust after running calibration routine
// ============================================================
#define TOUCH_MIN_X   200
#define TOUCH_MAX_X  3700
#define TOUCH_MIN_Y   300
#define TOUCH_MAX_Y  3800

// ============================================================
// NVS (Non-Volatile Storage) Configuration
// ============================================================
#define NVS_NAMESPACE      "aim_config"    // Max 15 chars
#define NVS_VAL_MAX_LEN    512             // Max length for tokens

// ============================================================
// Defaults
// ============================================================
#define DEFAULT_POLL_INTERVAL_SEC  120     // 2 minutes

// ============================================================
// Provider constants
// ============================================================
#define PROVIDER_CLAUDE   0
#define PROVIDER_OPENAI   1

// ============================================================
// Orientation options
// ============================================================
#define ORIENTATION_PORTRAIT          0   // setRotation(0): 240x320, USB bottom
#define ORIENTATION_LANDSCAPE_LEFT    1   // setRotation(3): 320x240, USB left
#define ORIENTATION_LANDSCAPE_RIGHT   2   // setRotation(1): 320x240, USB right
// Alias für Rückwärtskompatibilität (alte NVS-Werte):
#define ORIENTATION_LANDSCAPE         ORIENTATION_LANDSCAPE_LEFT

// ============================================================
// Theme options
// ============================================================
#define THEME_DARK   0
#define THEME_LIGHT  1

// ============================================================
// Language options
// ============================================================
#define LANG_DE  0
#define LANG_EN  1

// ============================================================
// Brightness limits (percent 0..100 on the wire,
// internally mapped to 8-bit PWM via LEDC)
// ============================================================
#define BRIGHTNESS_MIN_PERCENT  5      // nie komplett aus — sonst Display "verloren"
#define BRIGHTNESS_MAX_PERCENT  100
#define BRIGHTNESS_DEFAULT_PERCENT 80
#define BACKLIGHT_LEDC_CHANNEL  0
#define BACKLIGHT_LEDC_FREQ_HZ  5000
#define BACKLIGHT_LEDC_RES_BITS 8      // 0..255 duty

// ============================================================
// Application Configuration Struct
// ============================================================
struct AppConfig {
    uint16_t poll_interval_sec;       // Default 120
    uint8_t  orientation;             // ORIENTATION_PORTRAIT(0) / LANDSCAPE_LEFT(1) / LANDSCAPE_RIGHT(2)
    uint8_t  theme;                   // THEME_DARK(0) or THEME_LIGHT(1)
    uint8_t  language;                // LANG_DE(0) or LANG_EN(1)
    uint8_t  brightness_pct;          // 5..100
};

// ============================================================
// UI Colors (Claude Design System)
// ============================================================
#define COLOR_BG           0x2B2A27
#define COLOR_PANEL        0x353432
#define COLOR_ACCENT       0xD97757
#define COLOR_TEXT         0xF4F3EE
#define COLOR_TEXT_SEC     0x8A8880
#define COLOR_TEXT_DIM     0x5A5955
#define COLOR_HIGHLIGHT    0x1F1E1B
#define COLOR_ANTHROPIC    0xD97757
#define COLOR_OPENAI       0x0ACF83
#define COLOR_BAR_BG       0x3A3937
#define COLOR_STATUS_OK    0x27AE60
#define COLOR_STATUS_ERR   0xE74C3C
#define COLOR_STATUS_FETCH 0xF1C40F

#endif // CONFIG_H
