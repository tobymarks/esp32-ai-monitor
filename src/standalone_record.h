#ifndef STANDALONE_RECORD_H
#define STANDALONE_RECORD_H
#include <stdint.h>
#include <string>
// Portable record codec. Production supplies SHA-256 and the complete profile
// validator; tests inject deterministic functions without touching flash.
struct StandaloneRecord {
    uint32_t version = 0;
    bool enabled = false;
    std::string body;
};
inline std::string standalone_record_integrity(const StandaloneRecord &r) {
    return std::to_string(r.version) + ":" + (r.enabled ? "1" : "0") + ":" +
           std::to_string(r.body.size()) + ":" + r.body;
}
template <class Hash> std::string standalone_record_encode(const StandaloneRecord &r, Hash hash) {
    return "AIMSP1 " + std::to_string(r.version) + " " + (r.enabled ? "1" : "0") + " " +
           std::to_string(r.body.size()) + " " + hash(standalone_record_integrity(r)) + "\n" +
           r.body + "\nCOMMIT\n";
}
template <class Hash, class Validate>
bool standalone_record_decode(const std::string &bytes, StandaloneRecord &record, Hash hash,
                              Validate validate) {
    if (bytes.size() < 80 || bytes.size() > 8192 + 256 || bytes.compare(0, 7, "AIMSP1 "))
        return false;
    size_t cursor = 7;
    auto decimal = [&](uint32_t limit, uint32_t &out) {
        size_t start = cursor;
        out = 0;
        while (cursor < bytes.size() && bytes[cursor] >= '0' && bytes[cursor] <= '9') {
            unsigned digit = bytes[cursor++] - '0';
            if (out > limit / 10 || (out == limit / 10 && digit > limit % 10))
                return false;
            out = out * 10 + digit;
        }
        if (cursor == start || cursor >= bytes.size() || bytes[cursor++] != ' ')
            return false;
        return true;
    };
    uint32_t generation = 0, enabled = 0, length = 0;
    if (!decimal(UINT32_MAX, generation) || !generation || !decimal(1, enabled) ||
        !decimal(8192, length))
        return false;
    if (bytes.size() - cursor < 65)
        return false;
    std::string digest = bytes.substr(cursor, 64);
    for (char c : digest)
        if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f'))
            return false;
    cursor += 64;
    if (bytes[cursor++] != '\n' || bytes.size() - cursor != length + 8 ||
        bytes.compare(cursor + length, 8, "\nCOMMIT\n"))
        return false;
    StandaloneRecord candidate;
    candidate.version = generation;
    candidate.enabled = enabled;
    candidate.body = bytes.substr(cursor, length);
    if ((length == 0 && enabled) || hash(standalone_record_integrity(candidate)) != digest ||
        (length && !validate(candidate.body)))
        return false;
    record = std::move(candidate);
    return true;
}
#endif
