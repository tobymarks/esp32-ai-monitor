#include "display_owner.h"
#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    DisplayOwner owner;
    assert(!owner.host_active(0));
    owner.accept_host(0);
    assert(owner.host_active(0));
    assert(owner.host_active(299999));
    assert(!owner.host_active(300000));
    owner.accept_host(300001);
    assert(owner.host_active(300002));
    owner.relinquish(); // clean quit takes effect immediately
    assert(!owner.host_active(300002));
    owner.accept_host(UINT32_MAX - 100);
    assert(owner.host_active(100)); // millis wraparound
    assert(!owner.host_active(300000));
    owner.accept_host(301000); // reconnect after timeout
    assert(owner.host_active(301000));
    // Arbitrary diagnostic reads and malformed frames have no mutating API.
    for (int i = 0; i < 10; ++i)
        assert(owner.host_active(301000 + i));
    assert(!owner.host_active(601000));
    std::puts("display ownership: boot, USB, timeout, standby, reconnect, wrap passed");
}
