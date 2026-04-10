#ifndef API_CLAUDE_H
#define API_CLAUDE_H

#include "api_common.h"

bool claude_refresh_token();
bool claude_fetch_usage(UsageData &data);

// Returns true if the last fetch attempt received a 429 (rate limited)
bool claude_was_rate_limited();

#endif
