#ifndef CONFIG_STORE_H
#define CONFIG_STORE_H

#include "config.h"

// Global config instance
extern AppConfig g_config;

// Load config from NVS (orientation, poll_interval)
void config_load(AppConfig &cfg);

// Save config to NVS
void config_save(const AppConfig &cfg);

// Backlight control — implemented in main.cpp (LEDC PWM)
void backlight_apply_percent(uint8_t pct);

// Orientation change without reboot — re-initialises TFT rotation, LVGL display
// dimensions and recreates the dashboard. Implemented in main.cpp.
void apply_orientation(uint8_t orientation);

#endif // CONFIG_STORE_H
