#ifndef API_ANTHROPIC_H
#define API_ANTHROPIC_H

#include "api_common.h"

// Fetch Anthropic usage (tokens per model) for today + this month
// Populates token fields and model breakdown in data
// Returns true on success
bool anthropic_fetch_usage(UsageData &data);

// Fetch Anthropic costs (USD) for today + this month
// Populates today_cost and month_cost in data
// Returns true on success
bool anthropic_fetch_costs(UsageData &data);

#endif // API_ANTHROPIC_H
