#ifndef WEB_SERVER_H
#define WEB_SERVER_H

#include <Arduino.h>

// Start the async web server (call after WiFi is connected)
void webserver_init();

// Get the config URL string (for QR code)
String webserver_get_url();

#endif // WEB_SERVER_H
