#include "standalone_profile.h"
#include "plugin_scene.h"
#include <cassert>
#include <cstring>
#include <cstdio>
#include <string>
#include <functional>

static const char *profile =
    R"JSON({"protocol":1,"pluginId":"test.status","name":"Status","pluginVersion":"1.0.0","url":"https://status.example.org/api/status.json","intervalSeconds":60,"usesLocation":false,"theme":"dark","locale":"en","layout":"portrait","bindings":[{"name":"status","path":"status.description","format":"text","suffix":"","fallback":"Unknown","displayFallback":"Unknown","trim":true,"map":{},"displayMap":{}}],"scene":{"background":0,"nodes":[{"type":"text","x":0,"y":0,"w":1000,"h":100,"color":16777215,"text":"{{status}}"}]}})JSON";
static unsigned checks = 0;
static void check(bool value) {
    ++checks;
    assert(value);
}
static void rejects(const std::function<void(JsonDocument &)> &edit) {
    JsonDocument doc;
    check(!deserializeJson(doc, profile));
    edit(doc);
    const char *error = nullptr;
    check(!standalone_validate(doc.as<JsonObjectConst>(), &error));
    check(error != nullptr);
}
static void parse_rejects(const std::string &value) {
    StandaloneAllocator alloc;
    JsonDocument doc(&alloc);
    const char *error = nullptr;
    check(!standalone_parse(value.data(), value.size(), doc, &error));
    check(error != nullptr);
    check(alloc.used() <= STANDALONE_JSON_HEAP);
}
int main() {
    const char *error = nullptr;
    StandaloneAllocator alloc;
    JsonDocument doc(&alloc);
    check(standalone_parse(profile, strlen(profile), doc, &error));
    check(standalone_validate(doc.as<JsonObjectConst>(), &error));
    for (const char *s : {"", "null", "42", "\"x\"", "{}{}", "{} trailing", "{\"a\":", "[}",
                          "{\"a\":true,}", "[[[[[[[[[]]]]]]]]]"})
        parse_rejects(s);
    parse_rejects(std::string("{}\0", 3));
    parse_rejects(R"({"url":"https://example.org/\u0000hidden"})");
    parse_rejects(R"({"a\u0000b":1})");
    parse_rejects(std::string(8193, ' '));
    parse_rejects(std::string("{\"x\":\"line\nbreak\"}"));
    // Many tiny tokens exhaust the parsed-document budget before the body cap.
    std::string dense = "[";
    for (int i = 0; i < 4000; ++i)
        dense += i ? ",0" : "0";
    dense += "]";
    parse_rejects(dense);
    {
        StandaloneAllocator budget;
        void *p = budget.allocate(STANDALONE_JSON_HEAP / 2);
        check(p);
        check(budget.used() > STANDALONE_JSON_HEAP / 2);
        check(!budget.allocate(STANDALONE_JSON_HEAP / 2));
        check(!budget.reallocate(p, STANDALONE_JSON_HEAP + 1));
        budget.deallocate(p);
        check(budget.used() == 0);
    }
    for (const char *url :
         {"http://example.org/x", "https://user:pass@example.org/", "https://example.org/#frag",
          "https://example.org/?token=abc", "https://example.org/?%61pi_key=x",
          "https://127.0.0.1/", "https://[::1]/", "https://example.org:444/",
          "https://example.org/\r\nX: y", "https://example.org\\evil"})
        check(!standalone_url_valid(url));
    check(standalone_url_valid("https://api.open-meteo.com/v1/"
                               "forecast?latitude=50.938&longitude=6.960&current=temperature_2m"));
    check(standalone_url_valid("https://status.example.org:443/api/v2/status.json"));
    rejects([](auto &d) { d["protocol"] = 2; });
    rejects([](auto &d) { d["intervalSeconds"] = 59; });
    rejects([](auto &d) { d["intervalSeconds"] = 86401; });
    rejects([](auto &d) { d["authentication"] = "secret"; });
    rejects([](auto &d) { d["usesLocation"] = "false"; });
    rejects([](auto &d) { d["bindings"][0]["path"] = "a.b.c.d.e.f.g.h.i"; });
    rejects([](auto &d) { d["bindings"][0]["path"] = "a..b"; });
    rejects([](auto &d) { d["bindings"][0]["format"] = "script"; });
    rejects([](auto &d) { d["bindings"][0]["scale"] = 2; });
    rejects([](auto &d) { d["bindings"][0]["constant"].template to<JsonArray>().add(1); });
    rejects([](auto &d) { d["bindings"].template as<JsonArray>().add(d["bindings"][0]); });
    rejects([](auto &d) {
        auto a = d["bindings"].template as<JsonArray>();
        for (int i = 0; i < 16; ++i)
            a.add(a[0]);
    });
    rejects([](auto &d) { d["scene"]["nodes"][0]["text"] = "{{missing}}"; });
    rejects([](auto &d) { d["scene"]["nodes"][0]["x"] = 2147483647; });
    rejects([](auto &d) { d["scene"]["nodes"][0]["color"] = 0x1000000; });
    rejects([](auto &d) { d["scene"]["nodes"][0]["visibleWhen"]["binding"] = "missing"; });
    rejects([](auto &d) {
        auto a = d["scene"]["nodes"].template as<JsonArray>();
        for (int i = 0; i < 24; ++i)
            a.add(a[0]);
    });
    JsonDocument response, scene;
    response["status"]["description"] = "  Operational  ";
    check(standalone_render(doc.as<JsonObjectConst>(), response.as<JsonVariantConst>(), scene,
                            &error));
    check(!strcmp(scene["nodes"][0]["text"], "Operational"));
    check(plugin_scene_store(0, scene.as<JsonObject>(), &error));
    auto revision = plugin_scene_get(0)->revision;
    response["status"]["description"] = std::string(65, 'a');
    check(!standalone_render(doc.as<JsonObjectConst>(), response.as<JsonVariantConst>(), scene,
                             &error));
    check(plugin_scene_get(0)->revision == revision);
    response.clear();
    check(standalone_render(doc.as<JsonObjectConst>(), response.as<JsonVariantConst>(), scene,
                            &error));
    check(!strcmp(scene["nodes"][0]["text"], "Unknown"));
    plugin_scene_clear_all();
    std::printf("standalone malformed/resource checks: %u passed\n", checks);
}
