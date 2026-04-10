#ifndef UI_DETAIL_H
#define UI_DETAIL_H

#include <lvgl.h>
#include "api_common.h"

// Create and show the detail screen for a provider
// Automatically loads the screen with slide-left animation
void ui_detail_create(const char *provider, const UsageData &data, lv_color_t brand_color);

#endif // UI_DETAIL_H
