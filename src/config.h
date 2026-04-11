#ifndef CONFIG_H
#define CONFIG_H

// ============================================================
// ESP32-2432S028R (CYD 2.8") Pin Configuration
// ============================================================

// App version
#define APP_VERSION "1.0.0"
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
// WiFi / Network Configuration
// ============================================================
#define WIFI_AP_NAME             "AI-Monitor-Setup"
#define WIFIMANAGER_TIMEOUT_SEC  180
#define MDNS_HOSTNAME            "ai-monitor"

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
// OAuth / API endpoints
// ============================================================
#define CLAUDE_USAGE_ENDPOINT   "https://api.anthropic.com/api/oauth/usage"
#define CLAUDE_OAUTH_BETA       "oauth-2025-04-20"

// ============================================================
// Orientation options
// ============================================================
#define ORIENTATION_PORTRAIT   0   // setRotation(2): 240x320, USB at bottom
#define ORIENTATION_LANDSCAPE  1   // setRotation(1): 320x240, USB at left

// ============================================================
// Application Configuration Struct
// ============================================================
struct AppConfig {
    char     access_token[512];       // OAuth access token (pushed from Mac, read-only)
    uint8_t  provider;                // PROVIDER_CLAUDE(0) or PROVIDER_OPENAI(1)
    uint16_t poll_interval_sec;       // Default 120
    uint8_t  orientation;             // ORIENTATION_PORTRAIT(0) or ORIENTATION_LANDSCAPE(1)
};

// ============================================================
// UI Colors (matching web UI)
// ============================================================
#define COLOR_BG           0x1A1A2E
#define COLOR_PANEL        0x16213E
#define COLOR_ACCENT       0xE94560
#define COLOR_TEXT         0xE0E0E0
#define COLOR_TEXT_SEC     0xAAAAAA
#define COLOR_TEXT_DIM     0x666666
#define COLOR_HIGHLIGHT    0x0F3460
#define COLOR_ANTHROPIC    0xE94560
#define COLOR_OPENAI       0x0ACF83
#define COLOR_BAR_BG       0x0F3460
#define COLOR_STATUS_OK    0x27AE60
#define COLOR_STATUS_ERR   0xE74C3C
#define COLOR_STATUS_FETCH 0xF1C40F

#endif // CONFIG_H
