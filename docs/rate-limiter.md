# RateLimiter

**Purpose:** Centralized gate-keeper for API requests. Prevents exceeding API rate limits when multiple sources use the same API endpoint.

The RateLimiter maintains in-memory counters for permission checks and persists state periodically for crash recovery.

## Responsibilities

- Load API configurations from config file at startup
- Grant or deny permission for API requests based on rate limits
- Maintain in-memory request counters per API endpoint
- Persist state periodically to database for crash recovery
- Clean up old request timestamps in background loop
- Validate that source definitions reference existing API configs

## Provider Configuration Files

API rate limits and credentials are defined in separate configuration files per provider (not stored in database or hermes).

**One file per provider:**

```yaml
# fmp.yaml
domain: financialmodelingprep.com
limit: 300
period: 1m
api_key: your_fmp_api_key_here
```

```yaml
# alphavantage.yaml
domain: alphavantage.co
limit: 5
period: 1m
api_key: your_alphavantage_key_here
```

```yaml
# yahoo.yaml
domain: finance.yahoo.com
limit: 2000
period: 1h
# api_key is optional - not all providers need it
```

**Configuration fields:**
- `domain`: API domain extracted from URL (e.g., "financialmodelingprep.com" from "https://financialmodelingprep.com/api/...")
- `limit`: Maximum requests allowed per period
- `period`: Time window for the limit. Supported values:
  - `Ns` - N seconds (e.g., `30s` = 30 seconds)
  - `Nm` - N minutes (e.g., `5m` = 5 minutes, `1m` = 1 minute)
  - `Nh` - N hours (e.g., `1h` = 1 hour, `6h` = 6 hours)
  - `Nd` - N days (e.g., `1d` = 1 day)
- `api_key`: (Optional) API key for this provider

**Loading provider configs at startup:**

```bash
# Option 1: Specify individual provider files
hermes start --provider fmp.yaml --provider alphavantage.yaml

# Option 2: Specify directory containing provider yamls
hermes start --provider-dir /path/to/providers

# Option 3: Mix both
hermes start --provider-dir /etc/hermes --provider ~/custom/special.yaml
```

**Security:**
- Provider configs are loaded at startup and kept in memory only
- API keys are never persisted to the database
- File permissions control access (e.g., `chmod 600 fmp.yaml`)
- Each provider is isolated in its own file for easier key rotation

The domain is automatically extracted from the source definition's `url` field. No need to specify API separately.

## Source Definition Integration

Source definitions only need a URL - the domain is extracted automatically:

```yaml
name: fmp-aapl-prices
url: https://financialmodelingprep.com/api/v3/historical-price-full/AAPL
```

**How it works:**
- Hermes extracts the domain from the URL: `financialmodelingprep.com`
- Looks up the domain in the loaded provider configurations
- If found, applies rate limiting for that domain
- If not found, the source executes without rate limiting (useful for APIs without limits)

**Validation:**
- When a source definition is added via `hermes add`, the Receiver extracts the domain from the URL
- If the domain exists in the loaded provider configs, rate limiting will be enforced
- If the domain doesn't exist, the source is still accepted but runs without rate limiting

## Request Permission Flow

**Before making HTTP request:**

1. **Scheduler evaluates source** and checks if API has capacity via RateLimiter
2. If RateLimiter indicates API is rate-limited, **skip this source** this cycle (will retry next cycle)
3. If API has capacity, scheduler queues the task
4. **Worker receives task** and requests permission again: `RateLimiter.Acquire(api_name)`
   - **Why check twice?** Time passes between scheduler's check and worker execution. Other workers may have consumed the rate limit budget during this window.
5. If approved, worker proceeds with HTTP request
6. If denied (rate limit reached between queue and execution), worker returns `RateLimitExceeded` status
7. Scheduler receives `RateLimitExceeded` and **re-queues the task** for next cycle (does not count as failure)

**This double-check prevents:**
- Race conditions where multiple tasks exhaust the rate limit simultaneously
- Wasting retry budget on rate limit errors
- Getting temporarily banned by APIs
- Exceeding API quotas

## In-Memory State

RateLimiter maintains in-memory counters with mutex locks per domain:

- Counter of requests in current minute window
- Window start timestamp
- O(1) lookup per domain

**Example internal state:**
```
{
  "financialmodelingprep.com": {
    counter: 45,
    window_start: 2025-01-15 10:23:00
  },
  "alphavantage.co": {
    counter: 3,
    window_start: 2025-01-15 10:23:00
  }
}
```

**How counting works:**
- When permission requested, check if `NOW() - window_start >= period`
- If elapsed, reset: `counter = 0`, `window_start = NOW()`
- If `counter < limit`, approve and increment counter
- If `counter >= limit`, deny

## Database Persistence

State is persisted periodically (every 10 seconds) for crash recovery.

**Why persistence exists:**
Many free APIs have daily rate limits (e.g., 1000 requests/day). If Hermes crashes after making 995 requests and loses the in-memory counter, it could immediately make 1000 more requests on restart, exceeding the limit and potentially getting the API key banned. Persisting rate limiter state prevents this - after a crash, Hermes resumes with the correct counter and doesn't spam the API.

```sql
CREATE TABLE rate_limiter_state (
  domain TEXT PRIMARY KEY,
  request_count INT NOT NULL,
  window_start TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);
```

**Key columns:**
- `domain` - API domain (e.g., "financialmodelingprep.com")
- `request_count` - Number of requests in current time window
- `window_start` - When the current time window started
- `updated_at` - When this state was last persisted

**Bounded:** Exactly 1 row per domain (does not grow over time)

## Background Loop

RateLimiter runs a background event loop that:

1. **Every 10 seconds:** Persist in-memory state to `rate_limiter_state` table
2. **Continuously:** Respond to permission requests from workers (check/reset counters as needed)

## Startup and Recovery

**On service start:**
1. Load provider configuration files (via `--provider` or `--provider-dir` flags)
2. Load persisted state from `rate_limiter_state` table
3. Rebuild in-memory counters from persisted state
4. Start background loop

**After crash:**
- RateLimiter recovers using last persisted state (up to 10 seconds old)
- Worst case: Counter may be slightly outdated if crash happened right before persist
- Minute window resets naturally when `NOW() - window_start >= 1 minute`
- Accurate tracking resumes immediately

## Integration with Other Components

**Receiver:**
- Extracts domain from source definition URL
- No validation needed - sources without matching domain in config run without rate limiting

**Scheduler:**
- Checks RateLimiter capacity before queuing tasks
- Skips sources whose APIs are currently rate-limited
- Re-queues tasks that return `RateLimitExceeded` status

**Worker:**
- Requests permission via `RateLimiter.Acquire(api_name)` before HTTP request
- If denied, returns `RateLimitExceeded` (not counted as failure)
- If approved, proceeds with fetch

## Rate Limit Algorithm

Uses a simple time-bucket approach:

1. Maintain counter and window start timestamp per domain
2. When permission requested:
   - Check if `NOW() - window_start >= period` (configured period duration)
   - If yes, reset: `counter = 0`, `window_start = NOW()`
   - If `counter < limit`, approve and increment counter
   - If `counter >= limit`, deny
3. Counter automatically resets when period elapses

Works the same for any period (seconds, minutes, hours, days).

## Example Scenarios

**Scenario 1: Multiple sources, one domain**
- 3 sources all use financialmodelingprep.com (limit: 300/min)
- Window starts at 10:23:00, counter = 0
- Source A requests → RateLimiter: counter = 1, approved
- Source B requests → RateLimiter: counter = 2, approved
- Source C requests → RateLimiter: counter = 3, approved
- All sources execute without hitting rate limit

**Scenario 2: Approaching limit**
- financialmodelingprep.com has counter = 295 (limit: 300/min)
- 10 sources all scheduled to execute
- Scheduler checks RateLimiter before queuing each:
  - First 5 sources: approved and queued (counter: 296, 297, 298, 299, 300)
  - Next 5 sources: denied, skipped this cycle
- At next minute boundary, counter resets to 0
- Skipped sources execute in next scheduler cycle

**Scenario 3: Window reset (any period)**
- At 10:23:00, window starts, counter = 0
- Throughout the period, counter increases to limit
- When period elapses, next request checks: `NOW() - window_start >= period`
- Counter resets to 0, window_start = NOW()
- Fresh batch of requests allowed

**Example with hourly limit:**
- Domain: finance.yahoo.com (limit: 2000/hour)
- At 10:00:00, window starts, counter = 0
- Counter increases throughout the hour
- At 11:00:05, next request checks elapsed time >= 1 hour
- Counter resets, new window begins

**Scenario 4: Service crash and recovery**
- At 10:23:00, RateLimiter persists state: counter = 45, window_start = 10:23:00
- At 10:23:05, service crashes
- At 10:23:10, service restarts
- RateLimiter loads persisted state (counter = 45)
- May be slightly outdated (lost 5 seconds of requests)
- Resumes accurate tracking immediately
