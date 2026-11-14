#include "standalone_transfer.h"
#include <cassert>
#include <string>
#include <cstdio>
int main() {
    const char *e = nullptr;
    const std::string hash(64, 'a');
    StandaloneTransfer t;
    assert(!t.active());
    assert(!t.begin("tx", 8193, hash.c_str(), 0, &e));
    assert(!t.begin("tx", 0, hash.c_str(), 0, &e));
    assert(!t.begin("bad id", 8, hash.c_str(), 0, &e));
    assert(!t.begin("tx", 8, "abcd", 0, &e));
    assert(t.begin("tx", 8, hash.c_str(), 0, &e));
    assert(!t.begin("other", 8, hash.c_str(), 1, &e));
    assert(!t.chunk("other", 0, "abcd", 4, 1, &e));
    assert(!t.chunk("tx", 1, "abcd", 4, 1, &e));
    assert(t.chunk("tx", 0, "abcd", 4, 2, &e));
    assert(!t.complete("tx", 3, &e));
    assert(t.chunk("tx", 0, "abcd", 4, 4, &e));
    assert(t.received() == 4);
    assert(!t.chunk("tx", 0, "abce", 4, 5, &e));
    assert(!t.chunk("tx", 3, "defg", 4, 5, &e));
    assert(!t.chunk("tx", SIZE_MAX, "abcd", 4, 5, &e));
    assert(!t.chunk("tx", 4, "abcde", 5, 5, &e));
    assert(t.chunk("tx", 4, "efgh", 4, 5, &e));
    assert(t.complete("tx", 6, &e));
    assert(t.size() == 8 && t.received() == 8 && !strcmp(t.data(), "abcdefgh"));
    assert(!strcmp(t.digest(), hash.c_str()));
    t.expire(60004);
    assert(t.active());
    t.expire(60005);
    assert(!t.active());
    assert(t.begin("next", 8192, hash.c_str(), UINT32_MAX - 10, &e));
    const std::string chunk(1024, 'a');
    for (size_t i = 0; i < 8192; i += 1024)
        assert(t.chunk("next", i, chunk.data(), chunk.size(), 10, &e));
    assert(t.complete("next", 11, &e));
    t.reset();
    assert(!t.active());
    assert(t.begin("wrap", 1, hash.c_str(), UINT32_MAX - 100, &e));
    t.expire(1);
    assert(t.active());
    t.expire(60000);
    assert(!t.active());
    puts("standalone transfer: sequence, duplicate integrity, bounds, expiry, wrap passed");
}
