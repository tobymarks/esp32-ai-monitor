#include "plugin_scene.h"
#include "plugin_scene_renderer.h"

#include <ArduinoJson.h>
#include <lvgl.h>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

static std::vector<uint16_t> framebuffer;
static int display_width;

static void flush(lv_display_t *display, const lv_area_t *area, uint8_t *pixels) {
    const auto *source = reinterpret_cast<const uint16_t *>(pixels);
    const int width = area->x2 - area->x1 + 1;
    for (int y = area->y1; y <= area->y2; ++y) {
        for (int x = area->x1; x <= area->x2; ++x) {
            framebuffer[y * display_width + x] = source[(y - area->y1) * width + x - area->x1];
        }
    }
    lv_display_flush_ready(display);
}

static bool write_ppm(const char *path, int width, int height) {
    FILE *file = fopen(path, "wb");
    if (!file) return false;
    fprintf(file, "P6\n%d %d\n255\n", width, height);
    for (uint16_t pixel : framebuffer) {
        const uint8_t rgb[] = {
            static_cast<uint8_t>(((pixel >> 11) & 0x1f) * 255 / 31),
            static_cast<uint8_t>(((pixel >> 5) & 0x3f) * 255 / 63),
            static_cast<uint8_t>((pixel & 0x1f) * 255 / 31),
        };
        if (fwrite(rgb, 1, sizeof(rgb), file) != sizeof(rgb)) {
            fclose(file);
            return false;
        }
    }
    return fclose(file) == 0;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s scene.json width height output.ppm\n", argv[0]);
        return 2;
    }
    const int width = atoi(argv[2]);
    const int height = atoi(argv[3]);
    if (width < 1 || width > 480 || height < 1 || height > 480) return 2;
    std::ifstream input(argv[1], std::ios::binary);
    if (!input) return 2;
    const std::string json((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    JsonDocument received;
    if (deserializeJson(received, json) || !received.is<JsonObject>()) return 1;
    const char *error = nullptr;
    if (!plugin_scene_store(0, received.as<JsonObject>(), &error)) {
        fprintf(stderr, "firmware rejected scene: %s\n", error);
        return 1;
    }

    lv_init();
    lv_display_t *display = lv_display_create(width, height);
    lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);
    display_width = width;
    framebuffer.resize(width * height);
    std::vector<uint16_t> draw_buffer(width * 10);
    lv_display_set_buffers(display, draw_buffer.data(), nullptr,
                           draw_buffer.size() * sizeof(uint16_t), LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(display, flush);

    lv_obj_t *overlay = lv_obj_create(lv_screen_active());
    lv_obj_remove_style_all(overlay);
    lv_obj_set_size(overlay, width, height);
    lv_obj_set_style_bg_opa(overlay, LV_OPA_COVER, LV_PART_MAIN);
    const PluginSceneSlot *slot = plugin_scene_get(0);
    JsonDocument cached;
    if (!slot || !slot->ready || deserializeJson(cached, slot->json)) return 1;
    plugin_scene_draw(overlay, cached.as<JsonObjectConst>(), width, height);
    lv_refr_now(display);

    lv_mem_monitor_t memory;
    lv_mem_monitor(&memory);
    fprintf(stderr, "%dx%d LVGL heap: %zu/%zu bytes peak; %zu bytes free\n",
            width, height, memory.max_used, memory.total_size, memory.free_size);
    if (!write_ppm(argv[4], width, height)) return 1;
    plugin_scene_clear_all();
    lv_display_delete(display);
    lv_deinit();
    return 0;
}
