#include "plugin_scene.h"

#include <string.h>
#include <stdlib.h>

static PluginSceneSlot scenes[PLUGIN_SCENE_SLOTS] = {};
static constexpr size_t TOTAL_SCENE_BYTES = PLUGIN_SCENE_SLOTS * (PLUGIN_SCENE_MAX_BYTES + 1);
static size_t scene_bytes_used = 0;

static bool is_ascii_text(const char *value, size_t max_len) {
    if (!value) return false;
    size_t length = strlen(value);
    if (length > max_len) return false;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)value[i];
        if (c < 0x20 || c > 0x7E) return false;
    }
    return true;
}

static bool is_coord(JsonVariantConst value) {
    return value.is<int>() && value.as<int>() >= 0 && value.as<int>() <= 1000;
}

static bool is_color(JsonVariantConst value) {
    return value.is<unsigned int>() && value.as<unsigned int>() <= 0xFFFFFF;
}

static bool valid_node(JsonObjectConst node) {
    const char *type = node["type"];
    if (!type || !is_coord(node["x"]) || !is_coord(node["y"])
        || !is_coord(node["w"]) || !is_coord(node["h"])) return false;
    int x = node["x"].as<int>(), y = node["y"].as<int>();
    int w = node["w"].as<int>(), h = node["h"].as<int>();
    if (w == 0 || h == 0 || x + w > 1000 || y + h > 1000) return false;
    if (!is_color(node["color"])) return false;

    if (strcmp(type, "text") == 0) {
        if (!is_ascii_text(node["text"], 64)) return false;
        int font = node["font"] | 14;
        if (font != 12 && font != 14 && font != 16 && font != 20
            && font != 24 && font != 36 && font != 48) return false;
        const char *align = node["align"] | "left";
        return strcmp(align, "left") == 0 || strcmp(align, "center") == 0
            || strcmp(align, "right") == 0;
    }
    if (strcmp(type, "rect") == 0 || strcmp(type, "circle") == 0)
        return true;
    if (strcmp(type, "bar") == 0) {
        int value = node["value"] | -1;
        return value >= 0 && value <= 100 && is_color(node["trackColor"]);
    }
    return false;
}

bool plugin_scene_store(uint8_t slot, JsonObject scene, const char **error) {
    if (error) *error = "invalid scene";
    if (slot >= PLUGIN_SCENE_SLOTS || scene.isNull()) return false;
    if (!is_color(scene["background"])) return false;
    JsonArrayConst nodes = scene["nodes"].as<JsonArrayConst>();
    if (nodes.isNull() || nodes.size() > PLUGIN_SCENE_MAX_NODES) return false;
    for (JsonVariantConst item : nodes) {
        if (!item.is<JsonObjectConst>() || !valid_node(item.as<JsonObjectConst>())) return false;
    }
    size_t bytes = measureJson(scene);
    if (bytes == 0 || bytes > PLUGIN_SCENE_MAX_BYTES) {
        if (error) *error = "scene too large";
        return false;
    }

    PluginSceneSlot &target = scenes[slot];
    if (scene_bytes_used - target.bytes + bytes + 1 > TOTAL_SCENE_BYTES) {
        if (error) *error = "scene cache full";
        return false;
    }
    char *next = (char *)malloc(bytes + 1);
    if (!next) {
        if (error) *error = "out of memory";
        return false;
    }
    serializeJson(scene, next, bytes + 1);
    free(target.json);
    scene_bytes_used = scene_bytes_used - target.bytes + bytes + 1;
    target.json = next;
    target.bytes = bytes + 1;
    target.ready = true;
    ++target.revision;
    return true;
}

void plugin_scene_clear(uint8_t slot) {
    if (slot >= PLUGIN_SCENE_SLOTS) return;
    free(scenes[slot].json);
    scene_bytes_used -= scenes[slot].bytes;
    scenes[slot].json = nullptr;
    scenes[slot].bytes = 0;
    scenes[slot].ready = false;
    ++scenes[slot].revision;
}

void plugin_scene_clear_all() {
    for (uint8_t i = 0; i < PLUGIN_SCENE_SLOTS; ++i) plugin_scene_clear(i);
}

const PluginSceneSlot *plugin_scene_get(uint8_t slot) {
    return slot < PLUGIN_SCENE_SLOTS ? &scenes[slot] : nullptr;
}
