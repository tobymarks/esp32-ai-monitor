#ifndef CONFIG_STORE_H
#define CONFIG_STORE_H

#include "config.h"

// Global config instance
extern AppConfig g_config;

// Load config from NVS (orientation, poll_interval)
void config_load(AppConfig &cfg);

// Save config to NVS
void config_save(const AppConfig &cfg);

#endif // CONFIG_STORE_H
