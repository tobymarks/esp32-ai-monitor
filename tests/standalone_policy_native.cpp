#include <initializer_list>

#include "standalone_policy.h"
#include <assert.h>
#include <stdio.h>
#include <limits.h>
int main() {
    unsigned checked = 0;
    for (uint32_t start : {0u, 100u, UINT32_MAX - 100u}) {
        for (uint32_t elapsed : {0u, 1u, 11999u, 12000u, 12001u, 60000u}) {
            assert(standalone_request_current(7, 7, start, start + elapsed) == (elapsed < 12000));
            ++checked;
            assert(!standalone_request_current(7, 8, start, start + elapsed));
            ++checked;
        }
    }
    assert(standalone_result_current(1, 1, true));
    ++checked;
    assert(!standalone_result_current(1, 1, false));
    ++checked;
    assert(!standalone_result_current(1, 2, true));
    ++checked;
    unsigned failures = 0;
    const unsigned expected[] = {60000, 120000, 240000, 480000, 900000};
    for (unsigned n : expected) {
        assert(standalone_retry_ms(failures, 0) == n);
        ++checked;
    }
    for (unsigned i = 0; i < 100000; ++i) {
        assert(standalone_retry_ms(failures, UINT32_MAX) == 900000);
        assert(failures == 5);
        ++checked;
    }
    failures = 0;
    assert(standalone_retry_ms(failures, 4999) == 64999);
    ++checked;
    failures = UINT_MAX;
    assert(standalone_retry_ms(failures, 4999) == 900000);
    ++checked;
    printf("Standalone deadline/cancellation/backoff: %u checks passed\n", checked);
}
