#ifndef QR_DISPLAY_H
#define QR_DISPLAY_H

#include <Arduino.h>

// Create and show the QR code setup screen on the LVGL display
// Shows QR code with the given URL and text info below
void qr_display_show(const String &url);

// Hide the QR screen and return to previous screen
void qr_display_hide();

// Is the QR screen currently visible?
bool qr_display_is_visible();

#endif // QR_DISPLAY_H
