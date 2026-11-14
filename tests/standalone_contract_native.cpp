#include "standalone_profile.h"
#include <fstream>
#include <iostream>
#include <string>
#include <cassert>
static std::string encoded(JsonVariantConst v) {
    std::string s;
    serializeJson(v, s);
    return s;
}
static bool equivalent(JsonVariantConst a, JsonVariantConst b) {
    if (a.is<JsonObjectConst>() && b.is<JsonObjectConst>()) {
        auto left = a.as<JsonObjectConst>(), right = b.as<JsonObjectConst>();
        if (left.size() != right.size())
            return false;
        for (JsonPairConst p : left)
            if (!equivalent(p.value(), right[p.key()]))
                return false;
        return true;
    }
    if (a.is<JsonArrayConst>() && b.is<JsonArrayConst>()) {
        auto left = a.as<JsonArrayConst>(), right = b.as<JsonArrayConst>();
        if (left.size() != right.size())
            return false;
        for (size_t i = 0; i < left.size(); ++i)
            if (!equivalent(left[i], right[i]))
                return false;
        return true;
    }
    return a == b;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    std::ifstream input(argv[1]);
    assert(input.good());
    std::string line;
    unsigned passed = 0;
    JsonDocument fixture;
    while (std::getline(input, line)) {
        assert(!deserializeJson(fixture, line));
        StandaloneAllocator profileMemory, responseMemory, sceneMemory;
        JsonDocument profile(&profileMemory), response(&responseMemory), scene(&sceneMemory);
        std::string source = fixture["profileJson"].as<const char *>();
        std::string body = fixture["responseJson"].as<const char *>();
        const char *error = nullptr;
        if (!standalone_parse(source.data(), source.size(), profile, &error) ||
            !standalone_validate(profile.as<JsonObjectConst>(), &error) ||
            !standalone_parse(body.data(), body.size(), response, &error) ||
            !standalone_render(profile.as<JsonObjectConst>(), response.as<JsonVariantConst>(),
                               scene, &error)) {
            std::cerr << fixture["name"].as<const char *>() << ": " << (error ? error : "unknown")
                      << "\n";
            return 1;
        }
        if (!equivalent(scene.as<JsonVariantConst>(), fixture["expected"])) {
            std::cerr << fixture["name"].as<const char *>() << "\nExpected "
                      << encoded(fixture["expected"]) << "\nActual   "
                      << encoded(scene.as<JsonVariantConst>()) << "\n";
            return 1;
        }
        ++passed;
    }
    assert(passed >= 192);
    for (auto malformed : {"{}{}", "{}x", "{\"a\":", "[[[[[[[[[0]]]]]]]]]", "{\"a\":NaN}",
                           "{\"a\":true,}", "{\"a\":1,\"b\":}", "\"string\""}) {
        JsonDocument doc;
        const char *e = nullptr;
        if (standalone_parse(malformed, strlen(malformed), doc, &e)) {
            std::cerr << "Accepted malformed: " << malformed << "\n";
            return 1;
        }
    }
    const char *error = nullptr;
    {
        JsonDocument doc;
        std::string large(8193, ' ');
        assert(!standalone_parse(large.data(), large.size(), doc, &error));
    }
    {
        JsonDocument doc;
        std::string nul("{}\0", 3);
        assert(!standalone_parse(nul.data(), nul.size(), doc, &error));
    }
    {
        StandaloneAllocator memory;
        JsonDocument doc(&memory);
        std::string many = "[";
        for (int i = 0; i < 3900; ++i)
            many += "0,";
        many += "0]";
        assert(!standalone_parse(many.data(), many.size(), doc, &error));
        assert(memory.used() <= STANDALONE_JSON_HEAP);
    }
    {
        StandaloneAllocator memory;
        assert(memory.allocate(STANDALONE_JSON_HEAP + 1) == nullptr);
        void *p = memory.allocate(STANDALONE_JSON_HEAP - 64);
        assert(p);
        assert(!memory.allocate(65));
        assert(!memory.reallocate(p, STANDALONE_JSON_HEAP + 1));
        memory.deallocate(p);
        assert(memory.used() == 0);
    }
    auto base = encoded(fixture["profile"]);
    for (int test = 0; test < 13; ++test) {
        JsonDocument p;
        assert(!deserializeJson(p, base));
        switch (test) {
        case 0:
            p["protocol"] = 2;
            break;
        case 1:
            p["intervalSeconds"] = 59;
            break;
        case 2:
            p["url"] = "http://example.org";
            break;
        case 3:
            p["url"] = "https://user:pass@example.org";
            break;
        case 4:
            p["url"] = "https://example.org/?%61uth=secret";
            break;
        case 5:
            p["extra"] = true;
            break;
        case 6:
            p["bindings"][0]["format"] = "script";
            break;
        case 7:
            p["bindings"][0]["constant"].to<JsonArray>().add("secret");
            break;
        case 8:
            p["bindings"][0]["path"] = "a.b.c.d.e.f.g.h.i";
            break;
        case 9:
            p["scene"]["nodes"][0]["w"] = INT64_MAX;
            break;
        case 10:
            p["scene"]["nodes"][0]["script"] = "alert";
            break;
        case 11:
            p["bindings"][1]["name"] = p["bindings"][0]["name"];
            break;
        case 12:
            for (int i = 0; i < 17; ++i)
                p["bindings"].as<JsonArray>().add(p["bindings"][0]);
            break;
        }
        if (standalone_validate(p.as<JsonObjectConst>(), &error)) {
            std::cerr << "Accepted invalid profile " << test << "\n";
            return 1;
        }
    }
    std::cout << passed
              << " host/firmware scenes match; malformed JSON, profile bounds and allocator budget "
                 "checks pass\n";
}
