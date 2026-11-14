#ifndef STANDALONE_RUNTIME_H
#define STANDALONE_RUNTIME_H
#include <ArduinoJson.h>
#include "plugin_scene.h"
void standalone_init();
void standalone_tick(bool usb_owner);
void standalone_invalidate();
bool standalone_command(JsonObjectConst command, JsonDocument &reply);
bool standalone_active();
const PluginSceneSlot *standalone_scene();
const char *standalone_status();
uint32_t standalone_success_age_seconds(); // UINT32_MAX means no success
bool standalone_stale();
#endif
