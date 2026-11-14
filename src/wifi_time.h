#ifndef WIFI_TIME_H
#define WIFI_TIME_H

#include <Arduino.h>

void wifi_time_init();
void wifi_time_tick();

bool wifi_time_has_credentials();
bool wifi_time_is_connected();
bool wifi_time_is_synced();
// True only after an observed NTP callback or a valid companion clock update.
bool wifi_time_clock_trusted();
void wifi_time_note_host_clock();

void wifi_time_save_credentials(const char *ssid, const char *password);
void wifi_time_forget_credentials();
bool wifi_time_connect_now(uint32_t timeout_ms);

void wifi_time_print_status(const char *type = "wifi_status");
void wifi_time_print_scan();

#endif // WIFI_TIME_H
