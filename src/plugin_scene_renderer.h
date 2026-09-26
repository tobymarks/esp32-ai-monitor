#ifndef PLUGIN_SCENE_RENDERER_H
#define PLUGIN_SCENE_RENDERER_H

#include <ArduinoJson.h>
#include <lvgl.h>

// Draw an already validated scene into a full-screen LVGL object. Shared with
// the native render test so it exercises the firmware's actual drawing code.
void plugin_scene_draw(lv_obj_t *overlay, JsonObjectConst scene,
                       int16_t screen_width, int16_t screen_height);

#endif
