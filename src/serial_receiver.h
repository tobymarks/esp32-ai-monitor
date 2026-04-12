#ifndef SERIAL_RECEIVER_H
#define SERIAL_RECEIVER_H

#include "api_common.h"

// Initialize serial receiver state
void serial_receiver_init();

// Call from loop() — reads Serial, parses complete JSON lines
void serial_receiver_tick();

// Get a copy of the current monitor state
MonitorState serial_get_state();

// Returns true if we received valid data within the last 5 minutes
bool serial_has_recent_data();

// Returns true if new data arrived since last call (auto-resets)
bool serial_has_new_data();

// Returns current display time string ("HH:MM" or "--:--")
const char* serial_get_display_time();

#endif // SERIAL_RECEIVER_H
