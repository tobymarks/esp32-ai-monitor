#ifndef API_CLAUDE_H
#define API_CLAUDE_H

#include "api_common.h"

bool claude_refresh_token();
bool claude_fetch_usage(UsageData &data);

#endif
