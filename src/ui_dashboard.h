#ifndef UI_DASHBOARD_H
#define UI_DASHBOARD_H

#include <lvgl.h>
#include "api_common.h"

// Create the main dashboard screen (call once)
void ui_dashboard_create();

// Update all dashboard values from current state
void ui_dashboard_update(const MonitorState &state);

// Load (show) the dashboard screen with fade animation
void ui_dashboard_load();

// Load (show) the dashboard screen with slide-right (back) animation
void ui_dashboard_load_back();

// Get the dashboard screen object
lv_obj_t* ui_dashboard_get_screen();

// Get a copy of the last known state (for detail/settings screens)
const MonitorState& ui_dashboard_get_last_state();

#endif // UI_DASHBOARD_H
