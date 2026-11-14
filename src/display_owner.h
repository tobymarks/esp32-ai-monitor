#pragma once
#include <stdint.h>

// Monotonic USB lease. Diagnostics and standalone refreshes never renew it.
// The separate `seen` bit makes a valid frame at millis()==0 unambiguous.
class DisplayOwner {
  public:
    static constexpr uint32_t timeout_ms = 300000;
    void accept_host(uint32_t now) {
        seen_ = true;
        last_ = now;
    }
    void relinquish() { seen_ = false; }
    bool host_active(uint32_t now) const { return seen_ && uint32_t(now - last_) < timeout_ms; }

  private:
    bool seen_ = false;
    uint32_t last_ = 0;
};
