#include "standalone_profile.h"
#include <string>
#include <string.h>
#include <stdio.h>
#include <cmath>
#include <ctype.h>
#include <limits.h>
#include <errno.h>

struct alignas(max_align_t) AllocationHeader {
    size_t size;
};
void *StandaloneAllocator::allocate(size_t n) {
    if (n > STANDALONE_JSON_HEAP - sizeof(AllocationHeader) ||
        used_ > STANDALONE_JSON_HEAP - n - sizeof(AllocationHeader))
        return nullptr;
    auto h = static_cast<AllocationHeader *>(malloc(sizeof(AllocationHeader) + n));
    if (!h)
        return nullptr;
    h->size = n;
    used_ += n + sizeof(AllocationHeader);
    return h + 1;
}
void StandaloneAllocator::deallocate(void *p) {
    if (!p)
        return;
    auto h = static_cast<AllocationHeader *>(p) - 1;
    used_ -= h->size + sizeof(AllocationHeader);
    free(h);
}
void *StandaloneAllocator::reallocate(void *p, size_t n) {
    if (!p)
        return allocate(n);
    auto old = static_cast<AllocationHeader *>(p) - 1;
    if (n > STANDALONE_JSON_HEAP - sizeof(AllocationHeader) ||
        used_ - old->size > STANDALONE_JSON_HEAP - n)
        return nullptr;
    size_t previous = old->size;
    auto h = static_cast<AllocationHeader *>(realloc(old, sizeof(AllocationHeader) + n));
    if (!h)
        return nullptr;
    h->size = n;
    used_ = used_ - previous + n;
    return h + 1;
}
static bool fail(const char **e, const char *s) {
    if (e)
        *e = s;
    return false;
}

// Parse the bounded wire JSON ourselves. ArduinoJson's permissive parser accepts
// trailing commas and its fast decimal parser can change a rounding tie after
// scale multiplication. strtod gives the same correctly rounded IEEE value as
// serde_json. The document still uses the budgeted ArduinoJson allocator.
class StrictJson {
    const char *p_, *end_;
    const char **error_;
    bool bad(const char *message = "json_invalid") { return fail(error_, message); }
    void space() {
        while (p_ < end_ && (*p_ == ' ' || *p_ == '\r' || *p_ == '\n' || *p_ == '\t'))
            ++p_;
    }
    bool take(char c) {
        space();
        if (p_ == end_ || *p_ != c)
            return false;
        ++p_;
        return true;
    }
    static int digit(char c) {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }
    bool hex4(uint32_t &n) {
        n = 0;
        for (unsigned i = 0; i < 4; ++i) {
            if (p_ == end_)
                return false;
            int d = digit(*p_++);
            if (d < 0)
                return false;
            n = n * 16 + d;
        }
        return true;
    }
    static void utf8(std::string &s, uint32_t n) {
        if (n < 0x80)
            s += (char)n;
        else if (n < 0x800) {
            s += (char)(0xc0 | (n >> 6));
            s += (char)(0x80 | (n & 63));
        } else if (n < 0x10000) {
            s += (char)(0xe0 | (n >> 12));
            s += (char)(0x80 | ((n >> 6) & 63));
            s += (char)(0x80 | (n & 63));
        } else {
            s += (char)(0xf0 | (n >> 18));
            s += (char)(0x80 | ((n >> 12) & 63));
            s += (char)(0x80 | ((n >> 6) & 63));
            s += (char)(0x80 | (n & 63));
        }
    }
    bool string(std::string &s) {
        if (!take('"'))
            return bad();
        while (p_ < end_) {
            unsigned char c = *p_++;
            if (c == '"')
                return true;
            if (c < 32)
                return bad();
            if (c == '\\') {
                if (p_ == end_)
                    return bad();
                char escaped = *p_++;
                switch (escaped) {
                case '"':
                case '\\':
                case '/':
                    s += escaped;
                    break;
                case 'b':
                    s += '\b';
                    break;
                case 'f':
                    s += '\f';
                    break;
                case 'n':
                    s += '\n';
                    break;
                case 'r':
                    s += '\r';
                    break;
                case 't':
                    s += '\t';
                    break;
                case 'u': {
                    uint32_t cp;
                    if (!hex4(cp) || cp == 0)
                        return bad();
                    if (cp >= 0xd800 && cp <= 0xdbff) {
                        if (end_ - p_ < 2 || *p_++ != '\\' || *p_++ != 'u')
                            return bad();
                        uint32_t low;
                        if (!hex4(low) || low < 0xdc00 || low > 0xdfff)
                            return bad();
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                    } else if (cp >= 0xdc00 && cp <= 0xdfff)
                        return bad();
                    utf8(s, cp);
                    break;
                }
                default:
                    return bad();
                }
            } else if (c < 128)
                s += (char)c;
            else {
                unsigned remaining = c >= 0xc2 && c <= 0xdf   ? 1
                                     : c >= 0xe0 && c <= 0xef ? 2
                                     : c >= 0xf0 && c <= 0xf4 ? 3
                                                              : 0;
                if (!remaining)
                    return bad();
                uint32_t cp = c & ((1 << (6 - remaining)) - 1);
                unsigned original = remaining;
                while (remaining--) {
                    if (p_ == end_ || ((unsigned char)*p_ & 0xc0) != 0x80)
                        return bad();
                    cp = (cp << 6) | ((unsigned char)*p_++ & 63);
                }
                if ((original == 1 && cp < 0x80) || (original == 2 && cp < 0x800) ||
                    (original == 3 && cp < 0x10000) || cp > 0x10ffff ||
                    (cp >= 0xd800 && cp <= 0xdfff))
                    return bad();
                utf8(s, cp);
            }
        }
        return bad("json_incomplete");
    }
    bool number(JsonVariant slot) {
        const char *start = p_;
        bool fractional = false;
        if (p_ < end_ && *p_ == '-')
            ++p_;
        if (p_ == end_)
            return bad();
        if (*p_ == '0')
            ++p_;
        else {
            if (*p_ < '1' || *p_ > '9')
                return bad();
            while (p_ < end_ && *p_ >= '0' && *p_ <= '9')
                ++p_;
        }
        if (p_ < end_ && *p_ == '.') {
            fractional = true;
            ++p_;
            if (p_ == end_ || *p_ < '0' || *p_ > '9')
                return bad();
            while (p_ < end_ && *p_ >= '0' && *p_ <= '9')
                ++p_;
        }
        if (p_ < end_ && (*p_ == 'e' || *p_ == 'E')) {
            fractional = true;
            ++p_;
            if (p_ < end_ && (*p_ == '+' || *p_ == '-'))
                ++p_;
            if (p_ == end_ || *p_ < '0' || *p_ > '9')
                return bad();
            while (p_ < end_ && *p_ >= '0' && *p_ <= '9')
                ++p_;
        }
        std::string token(start, p_);
        char *tail = nullptr;
        if (!fractional && token != "-0") {
            errno = 0;
            if (token[0] == '-') {
                long long n = strtoll(token.c_str(), &tail, 10);
                if (errno != ERANGE) {
                    slot.set((int64_t)n);
                    return true;
                }
            } else {
                unsigned long long n = strtoull(token.c_str(), &tail, 10);
                if (errno != ERANGE) {
                    slot.set((uint64_t)n);
                    return true;
                }
            }
        }
        double n = strtod(token.c_str(), &tail);
        if (!std::isfinite(n) || tail != token.c_str() + token.size())
            return bad();
        slot.set(n);
        return true;
    }
    bool value(JsonVariant slot, unsigned depth) {
        space();
        if (p_ == end_)
            return bad("json_incomplete");
        if (*p_ == '{' || *p_ == '[') {
            if (depth >= 8)
                return bad("json_depth");
            bool object = *p_++ == '{';
            if (object) {
                auto dest = slot.to<JsonObject>();
                if (take('}'))
                    return true;
                while (true) {
                    std::string name;
                    if (!string(name) || !take(':'))
                        return bad();
                    if (!dest[name].isUnbound())
                        return bad("json_duplicate");
                    if (!value(dest[name].to<JsonVariant>(), depth + 1))
                        return false;
                    if (take('}'))
                        return true;
                    if (!take(','))
                        return bad();
                }
            } else {
                auto dest = slot.to<JsonArray>();
                if (take(']'))
                    return true;
                while (true) {
                    if (!value(dest.add<JsonVariant>(), depth + 1))
                        return false;
                    if (take(']'))
                        return true;
                    if (!take(','))
                        return bad();
                }
            }
        }
        if (*p_ == '"') {
            std::string s;
            if (!string(s))
                return false;
            slot.set(s);
            return true;
        }
        for (const char *literal : {"true", "false", "null"}) {
            size_t n = strlen(literal);
            if ((size_t)(end_ - p_) >= n && !memcmp(p_, literal, n)) {
                p_ += n;
                if (!strcmp(literal, "null"))
                    slot.set(nullptr);
                else
                    slot.set(!strcmp(literal, "true"));
                return true;
            }
        }
        return number(slot);
    }

  public:
    StrictJson(const char *bytes, size_t length, const char **error)
        : p_(bytes), end_(bytes + length), error_(error) {}
    bool parse(JsonDocument &doc) {
        space();
        if (p_ == end_ || (*p_ != '{' && *p_ != '['))
            return bad("json_root");
        doc.clear();
        if (!value(doc.to<JsonVariant>(), 0))
            return false;
        space();
        if (p_ != end_)
            return bad("json_trailing");
        return !doc.overflowed() || bad("json_memory");
    }
};
bool standalone_parse(const char *bytes, size_t length, JsonDocument &document,
                      const char **error) {
    if (!bytes || !length || length > STANDALONE_PROFILE_BYTES)
        return fail(error, "json_size");
    return StrictJson(bytes, length, error).parse(document);
}
static bool keys(JsonObjectConst o, const char *allowed) {
    for (JsonPairConst p : o) {
        std::string key = std::string("|") + p.key().c_str() + "|";
        if (!strstr(allowed, key.c_str()))
            return false;
    }
    return true;
}
static bool text(const char *s, size_t max = 64) {
    if (!s || strlen(s) > max)
        return false;
    for (size_t i = 0; s[i]; ++i) {
        unsigned char c = s[i], n = s[i + 1];
        if (c >= 32 && c <= 126)
            continue;
        if ((c == 0xc2 && n == 0xb0) ||
            (c == 0xc3 && (n == 0x84 || n == 0x96 || n == 0x9c || n == 0x9f || n == 0xa4 ||
                           n == 0xb6 || n == 0xbc))) {
            ++i;
            continue;
        }
        return false;
    }
    return true;
}
static bool key(const char *s, size_t max) {
    if (!s || !*s || strlen(s) > max)
        return false;
    for (; *s; ++s)
        if (!(*s >= 'a' && *s <= 'z') && !(*s >= '0' && *s <= '9') && *s != '.' && *s != '_' &&
            *s != '-')
            return false;
    return true;
}
static bool path(const char *s) {
    if (!s || !*s || strlen(s) > 100)
        return false;
    unsigned count = 1;
    bool nonempty = false;
    for (; *s; ++s) {
        if (*s == '.') {
            if (!nonempty || ++count > 8)
                return false;
            nonempty = false;
        } else {
            unsigned char c = *s;
            if (!(isalnum(c) || c == '_' || c == '-'))
                return false;
            nonempty = true;
        }
    }
    return nonempty;
}
static int hex(char c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return -1;
}
bool standalone_url_valid(const char *url) {
    if (!url || strlen(url) > 2048 || strncmp(url, "https://", 8))
        return false;
    const char *authority = url + 8, *end = authority;
    while (*end && *end != '/' && *end != '?') {
        if (*end == '@' || *end == '#')
            return false;
        ++end;
    }
    if (end == authority)
        return false;
    // DNS names only: no literal LAN IPs, malformed ports or IPv6 authorities.
    const char *colon = nullptr;
    bool letter = false;
    for (const char *p = authority; p < end; ++p) {
        if (*p == ':') {
            if (colon)
                return false;
            colon = p;
        } else if (!isalnum((unsigned char)*p) && *p != '.' && *p != '-')
            return false;
        else if (isalpha((unsigned char)*p))
            letter = true;
    }
    if (!letter)
        return false;
    if (colon && std::string(colon, end) != (":443"))
        return false;
    for (const char *p = url; *p; ++p)
        if ((unsigned char)*p < 33 || (unsigned char)*p > 126 || *p == '#' || *p == '\\' ||
            *p == '{' || *p == '}')
            return false;
    const char *query = strchr(end, '?');
    if (query) {
        ++query;
        while (*query) {
            const char *stop = strchr(query, '&');
            if (!stop)
                stop = query + strlen(query);
            const char *eq = (const char *)memchr(query, '=', stop - query);
            if (!eq)
                eq = stop;
            std::string name;
            for (const char *p = query; p < eq; ++p) {
                char c = *p;
                if (c == '%' && p + 2 < eq && hex(p[1]) >= 0 && hex(p[2]) >= 0) {
                    c = (hex(p[1]) * 16 + hex(p[2]));
                    p += 2;
                }
                name += (char)tolower((unsigned char)c);
            }
            const char *bad[] = {"token", "access_token",  "api_key",  "apikey", "key",
                                 "auth",  "authorization", "password", "secret", "signature",
                                 "sig"};
            for (auto b : bad)
                if (name == b)
                    return false;
            query = *stop ? stop + 1 : stop;
        }
    }
    return true;
}
static JsonObjectConst binding(JsonArrayConst bindings, const char *name) {
    for (JsonObjectConst b : bindings)
        if (name && strcmp(b["name"] | "", name) == 0)
            return b;
    return JsonObjectConst();
}
static bool color(JsonVariantConst v) {
    return v.is<unsigned>() && v.as<unsigned>() <= 0xffffff;
}
static bool node_valid(JsonObjectConst n, JsonArrayConst bindings, bool templ) {
    if (!keys(n, "|type|x|y|w|h|color|text|font|align|value|trackColor|visibleWhen|valueBinding|"))
        return false;
    for (auto k : {"x", "y", "w", "h"})
        if (!n[k].is<int>() || n[k].as<int>() < 0 || n[k].as<int>() > 1000)
            return false;
    int x = n["x"], y = n["y"], w = n["w"], h = n["h"];
    if (!w || !h || x + w > 1000 || y + h > 1000 || !color(n["color"]))
        return false;
    if (n["visibleWhen"].is<JsonObjectConst>()) {
        if (!templ)
            return false;
        auto v = n["visibleWhen"].as<JsonObjectConst>();
        if (v.size() != 2 || !keys(v, "|binding|equals|notEquals|") ||
            binding(bindings, v["binding"]).isNull())
            return false;
        if (v["equals"].is<const char *>() == v["notEquals"].is<const char *>())
            return false;
        if (!text(v[v["equals"].is<const char *>() ? "equals" : "notEquals"]))
            return false;
    } else if (!n["visibleWhen"].isUnbound())
        return false;
    const char *type = n["type"] | "";
    if (!strcmp(type, "text")) {
        if (!n["valueBinding"].isUnbound() || !text(n["text"], templ ? 512 : 64))
            return false;
        int f = n["font"] | 14;
        if (f != 12 && f != 14 && f != 16 && f != 20 && f != 24 && f != 36 && f != 48)
            return false;
        const char *a = n["align"] | "left";
        if (strcmp(a, "left") && strcmp(a, "center") && strcmp(a, "right"))
            return false;
        std::string s = n["text"].as<const char *>();
        size_t pos = 0;
        while ((pos = s.find("{{", pos)) != std::string::npos) {
            size_t end = s.find("}}", pos + 2);
            if (!templ || end == std::string::npos ||
                binding(bindings, s.substr(pos + 2, end - pos - 2).c_str()).isNull())
                return false;
            if (templ) {
                s.replace(pos, end + 2 - pos, "X");
                ++pos;
            } else
                pos = end + 2;
        }
        if (!text(s.c_str()))
            return false;
    } else if (!strcmp(type, "bar")) {
        if (!color(n["trackColor"]))
            return false;
        if (!n["valueBinding"].isUnbound()) {
            if (!templ || !n["value"].isUnbound())
                return false;
            auto b = binding(bindings, n["valueBinding"]);
            if (b.isNull() || strcmp(b["format"] | "", "integer") || strcmp(b["suffix"] | "", ""))
                return false;
            const char *fallback = b["fallback"] | "";
            if (*fallback == '+')
                ++fallback;
            if (!*fallback)
                return false;
            unsigned value = 0;
            for (; *fallback; ++fallback) {
                if (*fallback < '0' || *fallback > '9')
                    return false;
                value = value * 10 + *fallback - '0';
                if (value > 100)
                    return false;
            }
        } else if (!n["value"].is<int>() || n["value"].as<int>() < 0 || n["value"].as<int>() > 100)
            return false;
    } else if (strcmp(type, "rect") && strcmp(type, "circle"))
        return false;
    return true;
}
bool standalone_validate(JsonObjectConst p, const char **error) {
    if (p.isNull() || !keys(p, "|protocol|pluginId|name|pluginVersion|url|intervalSeconds|"
                               "usesLocation|theme|locale|layout|bindings|scene|"))
        return fail(error, "profile_fields");
    if (!p["protocol"].is<int>() || p["protocol"].as<int>() != 1 || !key(p["pluginId"], 40) ||
        !text(p["name"], 60) || !text(p["pluginVersion"], 32))
        return fail(error, "profile_identity");
    const char *id = p["pluginId"];
    if (*id < 'a' || *id > 'z' || !strncmp(id, "builtin.", 8) || !*p["name"].as<const char *>())
        return fail(error, "profile_identity");
    const char *version = p["pluginVersion"];
    unsigned parts = 0;
    uint64_t component = 0;
    bool digit_seen = false;
    for (const char *q = version;; ++q) {
        if (*q == '.' || !*q) {
            if (!digit_seen || ++parts > 3)
                return fail(error, "profile_identity");
            component = 0;
            digit_seen = false;
            if (!*q)
                break;
        } else {
            if (*q < '0' || *q > '9')
                return fail(error, "profile_identity");
            component = component * 10 + *q - '0';
            if (component > UINT32_MAX)
                return fail(error, "profile_identity");
            digit_seen = true;
        }
    }
    if (parts != 3)
        return fail(error, "profile_identity");
    if (!standalone_url_valid(p["url"]))
        return fail(error, "profile_url");
    if (!p["intervalSeconds"].is<unsigned>() || p["intervalSeconds"].as<unsigned>() < 60 ||
        p["intervalSeconds"].as<unsigned>() > 86400 || !p["usesLocation"].is<bool>())
        return fail(error, "profile_interval");
    const char *theme = p["theme"] | "", *locale = p["locale"] | "", *layout = p["layout"] | "";
    if ((strcmp(theme, "dark") && strcmp(theme, "light")) ||
        (strcmp(locale, "de") && strcmp(locale, "en")) ||
        (strcmp(layout, "portrait") && strcmp(layout, "landscape") && strcmp(layout, "square")))
        return fail(error, "profile_layout");
    auto bindings = p["bindings"].as<JsonArrayConst>();
    if (bindings.isNull() || bindings.size() > 16)
        return fail(error, "profile_bindings");
    unsigned index = 0;
    for (JsonObjectConst b : bindings) {
        if (b.isNull() ||
            !keys(b, "|name|path|format|suffix|map|fallback|scale|trim|constant|displayMap|"
                     "displayFallback|") ||
            !key(b["name"], 30) || !path(b["path"]) || !text(b["suffix"], 20) ||
            !text(b["fallback"]) || !text(b["displayFallback"]) || !b["trim"].is<bool>())
            return fail(error, "profile_binding");
        for (unsigned i = 0; i < index; ++i)
            if (strcmp(bindings[i]["name"] | "", b["name"] | "") == 0)
                return fail(error, "profile_duplicate");
        ++index;
        const char *f = b["format"] | "";
        bool numeric = !strcmp(f, "integer") || !strcmp(f, "decimal1");
        if (!numeric && strcmp(f, "text") && strcmp(f, "map"))
            return fail(error, "profile_format");
        if ((numeric && b["trim"].as<bool>()) ||
            (!b["scale"].isNull() &&
             (!numeric || !b["scale"].is<double>() || !std::isfinite(b["scale"].as<double>()) ||
              b["scale"].as<double>() == 0)))
            return fail(error, "profile_transform");
        if (b["constant"].is<JsonArrayConst>() || b["constant"].is<JsonObjectConst>())
            return fail(error, "profile_constant");
        if (b["constant"].is<const char *>() && !text(b["constant"]))
            return fail(error, "profile_constant");
        for (auto k : {"map", "displayMap"}) {
            auto m = b[k].as<JsonObjectConst>();
            if (m.isNull() || m.size() > 32)
                return fail(error, "profile_map");
            for (JsonPairConst item : m)
                if (!text(item.key().c_str(), !strcmp(k, "map") ? 30 : 64) || !text(item.value()))
                    return fail(error, "profile_map");
        }
    }
    auto scene = p["scene"].as<JsonObjectConst>();
    auto nodes = scene["nodes"].as<JsonArrayConst>();
    if (!keys(scene, "|background|nodes|") || !color(scene["background"]) || nodes.isNull() ||
        nodes.size() > 24)
        return fail(error, "profile_scene");
    for (JsonObjectConst n : nodes)
        if (!node_valid(n, bindings, true))
            return fail(error, "profile_node");
    if (measureJson(p) > STANDALONE_PROFILE_BYTES)
        return fail(error, "profile_size");
    return true;
}
static JsonVariantConst lookup(JsonVariantConst data, const char *path) {
    std::string p = path;
    size_t start = 0;
    while (start < p.size()) {
        size_t end = p.find('.', start);
        if (end == std::string::npos)
            end = p.size();
        std::string part = p.substr(start, end - start);
        bool digits = !part.empty();
        for (char c : part)
            digits = digits && c >= '0' && c <= '9';
        if (digits) {
            char *tail;
            unsigned long n = strtoul(part.c_str(), &tail, 10);
            data = n > 8192 ? JsonVariantConst() : data[(size_t)n];
        } else
            data = data[part];
        start = end + 1;
    }
    return data;
}
// Rust str::trim uses Unicode White_Space. Decode only the edges; arbitrary
// response UTF-8 still fails the display alphabet check after transformation.
static bool whitespace(uint32_t c) {
    return (c >= 9 && c <= 13) || c == 32 || c == 0x85 || c == 0xa0 || c == 0x1680 ||
           (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f ||
           c == 0x205f || c == 0x3000;
}
static std::string trim(const std::string &s) {
    size_t first = 0, last = 0;
    bool begun = false;
    for (size_t i = 0; i < s.size();) {
        size_t start = i;
        unsigned char c = s[i++];
        uint32_t cp = c;
        unsigned more = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : c >= 0xc0 ? 1 : 0;
        if (more)
            cp = c & ((1 << (6 - more)) - 1);
        while (more-- && i < s.size())
            cp = (cp << 6) | ((unsigned char)s[i++] & 63);
        if (!whitespace(cp)) {
            if (!begun)
                first = start;
            begun = true;
            last = i;
        }
    }
    return begun ? s.substr(first, last - first) : "";
}
// serde_json distinguishes integer 1 from floating 1.0 when building map keys.
// Find the shortest round-tripping decimal, then use its JSON exponent rules.
static std::string json_float(double n) {
    if (n == 0)
        return std::signbit(n) ? "-0.0" : "0.0";
    char buffer[40];
    for (int precision = 0; precision < 17; ++precision) {
        snprintf(buffer, sizeof(buffer), "%.*e", precision, n);
        if (strtod(buffer, nullptr) == n)
            break;
    }
    std::string raw = buffer, sign;
    if (raw[0] == '-') {
        sign = "-";
        raw.erase(0, 1);
    }
    size_t e = raw.find('e');
    int exponent = atoi(raw.c_str() + e + 1);
    std::string digits = raw.substr(0, e);
    size_t point = digits.find('.');
    if (point != std::string::npos)
        digits.erase(point, 1);
    while (digits.size() > 1 && digits.back() == '0')
        digits.pop_back();
    int kk = exponent + 1;
    if (kk > 0 && kk <= 16) {
        if ((int)digits.size() <= kk)
            return sign + digits + std::string(kk - digits.size(), '0') + ".0";
        return sign + digits.substr(0, kk) + "." + digits.substr(kk);
    }
    if (kk <= 0 && kk > -5)
        return sign + "0." + std::string(-kk, '0') + digits;
    return sign + digits.substr(0, 1) + (digits.size() > 1 ? "." + digits.substr(1) : "") + "e" +
           (exponent >= 0 ? "+" : "") + std::to_string(exponent);
}
static std::string json_key(JsonVariantConst v) {
    if (v.isNull())
        return "null";
    if (v.is<bool>())
        return v.as<bool>() ? "true" : "false";
    char buffer[32];
    if (v.is<int64_t>()) {
        snprintf(buffer, sizeof(buffer), "%lld", (long long)v.as<int64_t>());
        return buffer;
    }
    if (v.is<uint64_t>()) {
        snprintf(buffer, sizeof(buffer), "%llu", (unsigned long long)v.as<uint64_t>());
        return buffer;
    }
    if (v.is<double>())
        return json_float(v.as<double>());
    if (v.is<const char *>()) {
        std::string result;
        serializeJson(v, result);
        return result;
    }
    std::string out;
    if (v.is<JsonArrayConst>()) {
        out = "[";
        for (auto item : v.as<JsonArrayConst>()) {
            if (out.size() > 1)
                out += ",";
            out += json_key(item);
            if (out.size() > 30)
                return std::string(31, '!');
        }
        return out + "]";
    }
    if (v.is<JsonObjectConst>()) {
        out = "{";
        const char *previous = nullptr;
        auto object = v.as<JsonObjectConst>();
        for (size_t index = 0; index < object.size(); ++index) {
            const char *next = nullptr;
            JsonVariantConst value;
            for (JsonPairConst pair : object) {
                const char *name = pair.key().c_str();
                if ((!previous || strcmp(name, previous) > 0) &&
                    (!next || strcmp(name, next) < 0)) {
                    next = name;
                    value = pair.value();
                }
            }
            if (!next)
                break;
            if (out.size() > 1)
                out += ",";
            // Object keys require JSON escaping just as string values do.
            out += '"';
            for (const char *p = next; *p; ++p) {
                if (*p == '"' || *p == '\\')
                    out += '\\';
                if (*p == '\b')
                    out += "\\b";
                else if (*p == '\f')
                    out += "\\f";
                else if (*p == '\n')
                    out += "\\n";
                else if (*p == '\r')
                    out += "\\r";
                else if (*p == '\t')
                    out += "\\t";
                else if ((unsigned char)*p < 32) {
                    char escape[7];
                    snprintf(escape, sizeof(escape), "\\u%04x", (unsigned char)*p);
                    out += escape;
                } else
                    out += *p;
            }
            out += "\":";
            out += json_key(value);
            if (out.size() > 30)
                return std::string(31, '!');
            previous = next;
        }
        return out + "}";
    }
    return "null";
}
bool standalone_render(JsonObjectConst p, JsonVariantConst data, JsonDocument &out,
                       const char **error) {
    if (!standalone_validate(p, error))
        return false;
    auto bindings = p["bindings"].as<JsonArrayConst>();
    struct Value {
        std::string name, raw, display;
    };
    Value values[16];
    unsigned count = 0;
    for (JsonObjectConst b : bindings) {
        JsonVariantConst v = b["constant"].isUnbound() ? lookup(data, b["path"]) : b["constant"];
        std::string value;
        bool resolved = false;
        const char *format = b["format"];
        if (!v.isUnbound()) {
            if (!strcmp(format, "text")) {
                if (v.is<const char *>()) {
                    value = v.as<const char *>();
                    if (b["trim"].as<bool>())
                        value = trim(value);
                    resolved = !b["trim"].as<bool>() || !value.empty();
                } else if (v.is<int64_t>()) {
                    char buf[32];
                    snprintf(buf, sizeof(buf), "%lld", (long long)v.as<int64_t>());
                    value = buf;
                    resolved = true;
                }
            } else if (!strcmp(format, "map")) {
                std::string mapkey;
                if (v.is<const char *>()) {
                    mapkey = v.as<const char *>();
                    if (b["trim"].as<bool>())
                        mapkey = trim(mapkey);
                } else
                    mapkey = json_key(v);
                auto m = b["map"][mapkey];
                if (m.is<const char *>()) {
                    value = m.as<const char *>();
                    resolved = true;
                }
            } else if (v.is<double>() && !v.is<bool>()) {
                double n = v.as<double>() * (b["scale"].isNull() ? 1.0 : b["scale"].as<double>());
                if (!std::isfinite(n))
                    return fail(error, "binding_nonfinite");
                char buf[96];
                int written =
                    snprintf(buf, sizeof(buf), !strcmp(format, "integer") ? "%.0f" : "%.1f", n);
                if (written < 0 || (size_t)written >= sizeof(buf))
                    return fail(error, "binding_size");
                value = buf;
                resolved = true;
            }
        }
        auto &dest = values[count++];
        dest.name = b["name"].as<const char *>();
        dest.raw = resolved ? value + (b["suffix"] | "") : (b["fallback"] | "");
        dest.display = dest.raw;
        if (!resolved)
            dest.display = b["displayFallback"] | "";
        else if (!strcmp(format, "map")) {
            auto translated = b["displayMap"][value];
            dest.display =
                std::string(translated.is<const char *>() ? translated.as<const char *>() : value) +
                (b["suffix"] | "");
        }
        if (!text(dest.display.c_str()))
            return fail(error, "binding_text");
    }
    // The host substitutes in BTreeMap order, including placeholders introduced
    // by another binding value. Match that order rather than manifest order.
    for (unsigned i = 0; i < count; ++i)
        for (unsigned j = i + 1; j < count; ++j)
            if (values[j].name < values[i].name)
                std::swap(values[i], values[j]);
    out.clear();
    out["background"] = p["scene"]["background"];
    auto nodes = out["nodes"].to<JsonArray>();
    for (JsonObjectConst src : p["scene"]["nodes"].as<JsonArrayConst>()) {
        auto when = src["visibleWhen"].as<JsonObjectConst>();
        if (!when.isNull()) {
            bool visible = false;
            for (unsigned i = 0; i < count; ++i)
                if (values[i].name == (when["binding"] | ""))
                    visible = when["equals"].is<const char *>()
                                  ? values[i].raw == when["equals"].as<const char *>()
                                  : values[i].raw != when["notEquals"].as<const char *>();
            if (!visible)
                continue;
        }
        auto node = nodes.add<JsonObject>();
        node.set(src);
        node.remove("visibleWhen");
        if (src["text"].is<const char *>()) {
            std::string s = src["text"].as<const char *>();
            for (unsigned i = 0; i < count; ++i) {
                std::string token = "{{" + values[i].name + "}}";
                size_t offset = 0;
                while ((offset = s.find(token, offset)) != std::string::npos) {
                    s.replace(offset, token.size(), values[i].display);
                    offset += values[i].display.size();
                    if (s.size() > 2048)
                        return fail(error, "render_text");
                }
            }
            if (s.find("{{") != std::string::npos || !text(s.c_str()))
                return fail(error, "render_text");
            node["text"] = s;
        }
        if (src["valueBinding"].is<const char *>()) {
            const char *name = src["valueBinding"];
            bool found = false;
            for (unsigned i = 0; i < count; ++i)
                if (values[i].name == name) {
                    const auto &s = values[i].display;
                    size_t k = s.size() && s[0] == '+' ? 1 : 0;
                    if (k == s.size())
                        return fail(error, "render_bar");
                    unsigned n = 0;
                    for (; k < s.size(); ++k) {
                        if (s[k] < '0' || s[k] > '9')
                            return fail(error, "render_bar");
                        n = n * 10 + s[k] - '0';
                        if (n > 100)
                            return fail(error, "render_bar");
                    }
                    node["value"] = n;
                    found = true;
                }
            if (!found)
                return fail(error, "render_bar");
            node.remove("valueBinding");
        }
        if (!node_valid(node, bindings, false))
            return fail(error, "render_node");
    }
    if (out.overflowed() || measureJson(out) > 1536)
        return fail(error, "render_size");
    return true;
}
