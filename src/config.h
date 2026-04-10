#ifndef CONFIG_H
#define CONFIG_H

// ============================================================
// ESP32-2432S028R (CYD 2.8") Pin Configuration
// ============================================================

// App version
#define APP_VERSION "0.1.0"
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
// Display dimensions
// ============================================================
#define SCREEN_WIDTH  320
#define SCREEN_HEIGHT 240

// ============================================================
// Touch calibration defaults (raw ADC values)
// Adjust after running calibration routine
// ============================================================
#define TOUCH_MIN_X   200
#define TOUCH_MAX_X  3700
#define TOUCH_MIN_Y   300
#define TOUCH_MAX_Y  3800

// ============================================================
// WiFi / API configuration (placeholders)
// ============================================================
struct WiFiConfig {
    char ssid[32]     = "";
    char password[64] = "";
};

struct ApiConfig {
    char endpoint[128] = "";
    char api_key[128]  = "";
};

struct AppConfig {
    WiFiConfig wifi;
    ApiConfig  api;
    uint32_t   poll_interval_ms = 300000;  // 5 minutes
};

#endif // CONFIG_H
