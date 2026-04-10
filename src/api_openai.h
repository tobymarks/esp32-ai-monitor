#ifndef API_OPENAI_H
#define API_OPENAI_H

#include "api_common.h"

// Fetch OpenAI usage (tokens per model) for today + this month
// Populates token fields and model breakdown in data
// Returns true on success
bool openai_fetch_usage(UsageData &data);

// Fetch OpenAI costs (USD) for today + this month
// Populates today_cost and month_cost in data
// Returns true on success
bool openai_fetch_costs(UsageData &data);

#endif // API_OPENAI_H
