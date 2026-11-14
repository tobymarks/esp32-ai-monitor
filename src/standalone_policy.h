#pragma once
#include <stdint.h>
// Every network stage shares one monotonic deadline. A generation change
// cancels work without asking a worker to touch display objects or flash.
inline bool standalone_request_current(uint32_t expected_generation, uint32_t generation,
                                       uint32_t started, uint32_t now) {
    return expected_generation == generation && uint32_t(now - started) < 12000;
}
inline bool standalone_result_current(uint32_t expected_generation, uint32_t generation,
                                      bool owns_display) {
    return expected_generation == generation && owns_display;
}
inline uint32_t standalone_retry_ms(unsigned &failures, uint32_t entropy) {
    const uint32_t seconds[] = {60, 120, 240, 480, 900};
    unsigned index = failures > 4 ? 4 : failures;
    if (failures < 5)
        ++failures;
    // Jitter is capped by the 900s retry ceiling as well as the 5s window.
    uint32_t delay = seconds[index] * 1000, extra = entropy % 5000;
    return delay > 900000 - extra ? 900000 : delay + extra;
}
