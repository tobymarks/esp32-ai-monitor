#ifndef WIFI_SETUP_H
#define WIFI_SETUP_H

#include <Arduino.h>

// Initialize WiFi: try stored credentials, fall back to AP config portal
// Returns true if connected successfully
bool wifi_setup_init();

// Start the captive portal for reconfiguration (e.g. double-reset)
void wifi_start_config_portal();

// Check WiFi connection and reconnect if needed (call from loop)
void wifi_check_connection();

// Get current IP address as string
String wifi_get_ip();

// Get RSSI
int wifi_get_rssi();

// Get connected SSID
String wifi_get_ssid();

// Is WiFi connected?
bool wifi_is_connected();

#endif // WIFI_SETUP_H
