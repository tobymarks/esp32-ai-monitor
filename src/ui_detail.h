#ifndef UI_DETAIL_H
#define UI_DETAIL_H

#include <lvgl.h>
#include "api_common.h"

// Create and show the detail screen from a MonitorState
// Automatically loads the screen with slide-left animation
void ui_detail_create(const MonitorState &state);

#endif // UI_DETAIL_H
