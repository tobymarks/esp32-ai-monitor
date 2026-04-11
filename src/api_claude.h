#ifndef API_CLAUDE_H
#define API_CLAUDE_H

#include "api_common.h"

// Fetch usage data via OAuth /api/oauth/usage (read-only, no token refresh)
bool claude_fetch_usage(UsageData &data);

// Returns true if the last fetch attempt received a 429
bool claude_was_rate_limited();

#endif
