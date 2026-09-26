#ifndef PLUGIN_SCENE_H
#define PLUGIN_SCENE_H

#include <stddef.h>
#include <stdint.h>
#include <ArduinoJson.h>

// One bounded, validated scene per display window. The wire frame can be up to
// 4095 bytes, but retaining eight such frames would waste scarce SRAM.
static constexpr uint8_t PLUGIN_SCENE_SLOTS = 8;
static constexpr uint8_t PLUGIN_SCENE_MAX_NODES = 24;
static constexpr size_t PLUGIN_SCENE_MAX_BYTES = 1536;
static constexpr size_t PLUGIN_VIEW_KEY_BYTES = 48;

struct PluginSceneSlot {
    char *json;
    size_t bytes;
    uint32_t revision;
    bool ready;
};

// Check the complete scene before changing the cached copy. Error messages are
// static literals suitable for a serial error response.
bool plugin_scene_store(uint8_t slot, JsonObject scene, const char **error);
void plugin_scene_clear(uint8_t slot);
void plugin_scene_clear_all();
const PluginSceneSlot *plugin_scene_get(uint8_t slot);

#endif
