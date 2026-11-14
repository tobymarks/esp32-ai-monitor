#ifndef STANDALONE_PROFILE_H
#define STANDALONE_PROFILE_H
#include <ArduinoJson.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

constexpr size_t STANDALONE_PROFILE_BYTES = 8192;
constexpr size_t STANDALONE_RESPONSE_BYTES = 8192;
constexpr size_t STANDALONE_JSON_HEAP = 28672;

// Includes allocator bookkeeping; ArduinoJson's dynamic pool cannot exceed this
// budget even when a tiny input contains thousands of JSON tokens.
class StandaloneAllocator : public ArduinoJson::Allocator {
    size_t used_ = 0;

  public:
    void *allocate(size_t n) override;
    void deallocate(void *p) override;
    void *reallocate(void *p, size_t n) override;
    size_t used() const { return used_; }
};
bool standalone_parse(const char *bytes, size_t length, JsonDocument &document, const char **error);
bool standalone_validate(JsonObjectConst profile, const char **error);
bool standalone_render(JsonObjectConst profile, JsonVariantConst response, JsonDocument &scene,
                       const char **error);
bool standalone_url_valid(const char *url);
#endif
