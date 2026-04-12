#ifndef API_MANAGER_H
#define API_MANAGER_H

#include "api_common.h"

// Initialize the API manager (call once after WiFi + NTP are ready)
void api_manager_init();

// Call from loop() — checks if poll interval elapsed, triggers fetch
void api_manager_tick();

// Force an immediate fetch of all APIs (blocks until done)
void api_manager_fetch();

// Get current monitor state (thread-safe copy)
MonitorState api_manager_get_state();

// Accept usage data pushed from companion app (called from web server)
void api_manager_push_usage(const UsageData &data);

#endif // API_MANAGER_H
