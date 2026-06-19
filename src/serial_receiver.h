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

// C4: Deferred UI rebuild. The parser requests a rebuild (set_theme /
// set_language / set_orientation); main loop() performs it after the tick.
void serial_request_ui_rebuild();
bool serial_ui_rebuild_requested();
void serial_ui_rebuild_clear();

// C3: True once the Mac companion sent a TZ offset. wifi_time uses this to
// avoid overwriting the host-selected timezone with its fixed NTP TZ.
bool host_timezone_is_set();

#endif // SERIAL_RECEIVER_H
