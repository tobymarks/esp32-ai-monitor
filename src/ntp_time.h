#ifndef NTP_TIME_H
#define NTP_TIME_H

#include <Arduino.h>

// Initialize NTP sync (call after WiFi is connected)
void ntp_init();

// Is time synced?
bool ntp_is_synced();

// Get formatted time string "HH:MM:SS"
String ntp_get_time();

// Get formatted date string "YYYY-MM-DD"
String ntp_get_date();

// Get formatted datetime "YYYY-MM-DD HH:MM"
String ntp_get_datetime();

// Get epoch timestamp for start of current day (00:00:00 local time)
time_t ntp_get_day_start();

// Get epoch timestamp for start of current month (1st, 00:00:00 local time)
time_t ntp_get_month_start();

// Get current epoch time
time_t ntp_get_epoch();

#endif // NTP_TIME_H
