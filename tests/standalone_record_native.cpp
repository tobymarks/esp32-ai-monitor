#include "standalone_record.h"
#include <cassert>
#include <cstdio>
#include <string>
// This deterministic callback tests integrity plumbing; firmware supplies
// mbedTLS SHA-256. Its cryptographic implementation is not reimplemented here.
static std::string hash(const std::string &s) {
    std::string result;
    for (unsigned lane = 0; lane < 8; ++lane) {
        uint32_t n = 2166136261u + lane;
        for (unsigned char c : s)
            n = (n ^ c) * 16777619u;
        char h[9];
        snprintf(h, sizeof(h), "%08x", n);
        result += h;
    }
    return result;
}
static bool validate(const std::string &s) {
    return s == "{\"valid\":true}" || s == std::string(8192, 'x');
}
static bool decode(const std::string &bytes, StandaloneRecord &record) {
    return standalone_record_decode(bytes, record, hash, validate);
}
static unsigned checks = 0;
static void check(bool b) {
    ++checks;
    assert(b);
}
int main() {
    StandaloneRecord old;
    old.version = 1;
    old.enabled = true;
    old.body = "{\"valid\":true}";
    StandaloneRecord next = old;
    next.version = 2;
    next.body = std::string(8192, 'x');
    const std::string previous = standalone_record_encode(old, hash),
                      full = standalone_record_encode(next, hash);
    for (size_t cutoff = 0; cutoff < full.size(); ++cutoff) {
        StandaloneRecord a, b;
        check(decode(previous, a));
        check(!decode(full.substr(0, cutoff), b));
        check(a.version == 1 && a.enabled && a.body == old.body);
    }
    StandaloneRecord decoded;
    check(decode(full, decoded));
    check(decoded.version == 2 && decoded.body == next.body);
    // A bad newer slot never masks the retained older valid committed slot.
    for (size_t offset = 0; offset < full.size(); ++offset) {
        auto corrupt = full;
        corrupt[offset] ^= 1;
        check(!decode(corrupt, decoded));
    }
    StandaloneRecord disabled = next;
    disabled.version = 3;
    disabled.enabled = false;
    check(decode(standalone_record_encode(disabled, hash), decoded));
    check(!decoded.enabled && !decoded.body.empty());
    StandaloneRecord removed;
    removed.version = 4;
    check(decode(standalone_record_encode(removed, hash), decoded));
    check(!decoded.enabled && decoded.body.empty());
    removed.enabled = true;
    check(!decode(standalone_record_encode(removed, hash), decoded));
    removed.enabled = false;
    removed.version = 0;
    check(!decode(standalone_record_encode(removed, hash), decoded));
    removed.version = UINT32_MAX;
    check(decode(standalone_record_encode(removed, hash), decoded));
    removed.body = "invalid";
    check(!decode(standalone_record_encode(removed, hash), decoded));
    check(!decode(full + "garbage", decoded));
    auto malicious = previous;
    malicious.replace(7, 1, "4294967296");
    check(!decode(malicious, decoded));
    std::printf(
        "standalone record codec: %u truncation, corruption, tombstone and bounds checks passed\n",
        checks);
}
