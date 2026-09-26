#include "plugin_scene_renderer.h"

#include <string.h>

static const lv_font_t *plugin_font(int size) {
    switch (size) {
        case 12: return &lv_font_montserrat_12;
        case 16: return &lv_font_montserrat_16;
        case 20: return &lv_font_montserrat_20;
        case 24: return &lv_font_montserrat_24;
        case 36: return &lv_font_montserrat_36;
        case 48: return &lv_font_montserrat_48;
        default: return &lv_font_montserrat_14;
    }
}

static int16_t plugin_scale(int value, int16_t screen_size) {
    return (int16_t)((int32_t)value * screen_size / 1000);
}

static void plugin_shape(lv_obj_t *parent, int16_t x, int16_t y,
                         int16_t w, int16_t h, lv_color_t color, bool circle) {
    lv_obj_t *shape = lv_obj_create(parent);
    lv_obj_remove_style_all(shape);
    lv_obj_set_pos(shape, x, y);
    lv_obj_set_size(shape, w, h);
    lv_obj_set_style_bg_color(shape, color, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(shape, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(shape, circle ? LV_RADIUS_CIRCLE : 0, LV_PART_MAIN);
    lv_obj_clear_flag(shape, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(shape, LV_OBJ_FLAG_SCROLLABLE);
}

void plugin_scene_draw(lv_obj_t *overlay, JsonObjectConst scene,
                       int16_t screen_width, int16_t screen_height) {
    lv_obj_set_style_bg_color(overlay,
                              lv_color_hex(scene["background"].as<uint32_t>()), LV_PART_MAIN);
    for (JsonObjectConst node : scene["nodes"].as<JsonArrayConst>()) {
        const char *type = node["type"];
        int16_t x = plugin_scale(node["x"].as<int>(), screen_width);
        int16_t y = plugin_scale(node["y"].as<int>(), screen_height);
        int16_t w = plugin_scale(node["w"].as<int>(), screen_width);
        int16_t h = plugin_scale(node["h"].as<int>(), screen_height);
        lv_color_t color = lv_color_hex(node["color"].as<uint32_t>());
        if (strcmp(type, "text") == 0) {
            lv_obj_t *label = lv_label_create(overlay);
            lv_obj_set_pos(label, x, y);
            lv_obj_set_size(label, w, h);
            lv_label_set_long_mode(label, LV_LABEL_LONG_CLIP);
            lv_label_set_text(label, node["text"] | "");
            lv_obj_set_style_text_color(label, color, LV_PART_MAIN);
            lv_obj_set_style_text_font(label, plugin_font(node["font"] | 14), LV_PART_MAIN);
            const char *align = node["align"] | "left";
            lv_obj_set_style_text_align(label,
                strcmp(align, "center") == 0 ? LV_TEXT_ALIGN_CENTER :
                strcmp(align, "right") == 0 ? LV_TEXT_ALIGN_RIGHT : LV_TEXT_ALIGN_LEFT,
                LV_PART_MAIN);
        } else if (strcmp(type, "bar") == 0) {
            plugin_shape(overlay, x, y, w, h,
                         lv_color_hex(node["trackColor"].as<uint32_t>()), false);
            int value = node["value"].as<int>();
            if (value > 0) plugin_shape(overlay, x, y,
                                       (int16_t)((int32_t)w * value / 100), h, color, false);
        } else {
            plugin_shape(overlay, x, y, w, h, color,
                         strcmp(type, "circle") == 0);
        }
    }
}
