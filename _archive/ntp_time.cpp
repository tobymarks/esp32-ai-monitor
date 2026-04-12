/**
 * NTP Time Sync
 *
 * Configures timezone (CET/CEST) and syncs with NTP servers.
 * Provides helper functions for time formatting and day/month boundaries.
 */

#include "ntp_time.h"
#include "config.h"
#include <time.h>

// CET/CEST timezone string for Europe/Berlin
static const char *TZ_INFO = "CET-1CEST,M3.5.0,M10.5.0/3";
static const char *NTP_SERVER_1 = "pool.ntp.org";
static const char *NTP_SERVER_2 = "time.nist.gov";

static bool timeSynced = false;

// ============================================================
// Init NTP
// ============================================================
void ntp_init() {
    Serial.println("[NTP] Configuring timezone and NTP...");
    configTzTime(TZ_INFO, NTP_SERVER_1, NTP_SERVER_2);

    // Wait up to 10 seconds for time to sync
    Serial.print("[NTP] Waiting for sync");
    struct tm timeinfo;
    int retries = 20;
    while (!getLocalTime(&timeinfo, 500) && retries > 0) {
        Serial.print(".");
        retries--;
    }
    Serial.println();

    if (getLocalTime(&timeinfo)) {
        timeSynced = true;
        char buf[32];
        strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &timeinfo);
        Serial.printf("[NTP] Time synced: %s\n", buf);
    } else {
        Serial.println("[NTP] Failed to sync time");
    }
}

// ============================================================
// Is time synced?
// ============================================================
bool ntp_is_synced() {
    if (timeSynced) return true;

    // Check again
    struct tm timeinfo;
    if (getLocalTime(&timeinfo, 0)) {
        timeSynced = true;
    }
    return timeSynced;
}

// ============================================================
// Formatted time "HH:MM:SS"
// ============================================================
String ntp_get_time() {
    struct tm timeinfo;
    if (!getLocalTime(&timeinfo, 0)) return "--:--:--";
    char buf[12];
    strftime(buf, sizeof(buf), "%H:%M:%S", &timeinfo);
    return String(buf);
}

// ============================================================
// Formatted date "YYYY-MM-DD"
// ============================================================
String ntp_get_date() {
    struct tm timeinfo;
    if (!getLocalTime(&timeinfo, 0)) return "----/--/--";
    char buf[12];
    strftime(buf, sizeof(buf), "%Y-%m-%d", &timeinfo);
    return String(buf);
}

// ============================================================
// Formatted datetime "YYYY-MM-DD HH:MM"
// ============================================================
String ntp_get_datetime() {
    struct tm timeinfo;
    if (!getLocalTime(&timeinfo, 0)) return "----/--/-- --:--";
    char buf[20];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M", &timeinfo);
    return String(buf);
}

// ============================================================
// Epoch for start of current day (00:00:00 local)
// ============================================================
time_t ntp_get_day_start() {
    struct tm timeinfo;
    if (!getLocalTime(&timeinfo, 0)) return 0;
    timeinfo.tm_hour = 0;
    timeinfo.tm_min  = 0;
    timeinfo.tm_sec  = 0;
    return mktime(&timeinfo);
}

// ============================================================
// Epoch for start of current month (1st, 00:00:00 local)
// ============================================================
time_t ntp_get_month_start() {
    struct tm timeinfo;
    if (!getLocalTime(&timeinfo, 0)) return 0;
    timeinfo.tm_mday = 1;
    timeinfo.tm_hour = 0;
    timeinfo.tm_min  = 0;
    timeinfo.tm_sec  = 0;
    return mktime(&timeinfo);
}

// ============================================================
// Current epoch time
// ============================================================
time_t ntp_get_epoch() {
    time_t now;
    time(&now);
    return now;
}
