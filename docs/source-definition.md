# Source Definition

**Purpose:** Complete YAML configuration reference. Learn all available fields, their meanings, and how to configure sources for different APIs and schedules.

A Source Definition is a YAML file that declares how to fetch data from an API endpoint.

## Structure

```yaml
name: string
description: string
url: string
table: string
schedule: string
execution:
  timeout: int
  maxRetries: int
  retryResetPeriod: string
params:
  - name: string
    value: string
response:
  dataPath: string
  fields:
    - source: string
      target: string
offsetPagination:
  pageParam: string
  limitParam: string
  limit: int
  hasMorePath: string
cursorPagination:
  cursorParam: string
  nextCursorPath: string
```

## Fields

### name
Unique identifier for this source definition.

### description
Human-readable description of what this source provides.

### url
Complete API endpoint URL. The domain is automatically extracted for rate limiting purposes.

If the domain matches an entry in `api-limits.yaml`, rate limiting will be enforced. If not, the source executes without rate limiting.

See [RateLimiter](rate-limiter.md) for rate limit configuration.

### schedule
How often this source should execute. Options:
- `daily` - Execute once per day
- `hourly` - Execute once per hour
- `interval:30m` - Execute every 30 minutes (supports: s, m, h)

Default: `daily`

### execution
Execution behavior and retry configuration.

- `timeout`: Maximum seconds allowed per execution. If exceeded, execution is cancelled and retried. Default: 300 (5 minutes)
- `maxRetries`: Maximum retry attempts per reset period. After this, source is skipped until period resets. Default: 5
- `retryResetPeriod`: How often to reset the retry counter. Supports: `1h`, `6h`, `1d`, `7d`. Default: `1d`

Example:
```yaml
execution:
  timeout: 600            # 10 minutes max per execution
  maxRetries: 3           # Try up to 3 times per day
  retryResetPeriod: 1d    # Reset retry counter daily
```

**Configuring timeout for paginated sources:**

When a source uses pagination, the timeout should be long enough to fetch **all pages** to avoid unnecessary retries. If pagination exceeds the timeout:
- The execution is cancelled mid-pagination
- Records inserted before cancellation are saved (partial progress)
- The source is retried from page 1
- On retry, idempotent inserts (`ON CONFLICT DO NOTHING`) skip already-inserted records
- New records continue being added until the full dataset is complete

**Example:** Fetching 5 years of historical daily prices:
- 1,825 days of data
- If paginated at 100 records per page = 19 pages
- If each page takes 2 seconds = 38 seconds total
- Set timeout to at least 60 seconds (2x expected time for safety margin)

If timeout is too short, the source will make incremental progress across multiple retry attempts. While this eventually completes the fetch, it wastes API calls and retry budget.

For large historical fetches, increase timeout accordingly:
```yaml
execution:
  timeout: 3600  # 1 hour for large historical data fetches
```

**Retry behavior:**
- Retries use exponential backoff: 2 minutes, 4 minutes, 8 minutes, etc. (2^attempt minutes)
- After `maxRetries` failures within a period, source is skipped until the period resets
- When `retryResetPeriod` elapses, retry counter resets to 0 and source can be attempted again
- Retry state persists in `retries` table (1 row per source, not per execution)
- Each retry starts from the beginning (page 1), but idempotent inserts prevent duplicates

### table
Database table name where fetched data will be inserted.

### params
Array of query parameters to append to the URL. Parameters are URL-encoded in the order they appear.
- `name`: Parameter name
- `value`: Parameter value

### response
Configuration for parsing the API response.

- `dataPath`: Dot-notation path to the array of data records (e.g., `"historical"` or `"data.items"`)
- `fields`: Array of field mappings
  - `source`: Field name in the API response
  - `target`: Database column name in the target table

### offsetPagination
Optional. Configuration for offset-based pagination (page numbers).

- `pageParam`: Query parameter name for page number
- `limitParam`: Query parameter name for page size
- `limit`: Number of items per page
- `hasMorePath`: Dot-notation path to boolean in response indicating more pages exist

### cursorPagination
Optional. Configuration for cursor-based pagination (tokens).

- `cursorParam`: Query parameter name for cursor token
- `nextCursorPath`: Dot-notation path to next cursor value in response

## Example

See `examples/sources/fmp-news.yaml` for a complete example fetching news articles from Financial Modeling Prep.

API response example:
```json
[
  {
    "title": "WEC Energy Group, Inc. (NYSE: WEC) Sees Positive Outlook...",
    "date": "2025-10-27 19:10:17",
    "content": "<ul>...</ul>",
    "tickers": "NYSE:WEC",
    "image": "https://portal.financialmodelingprep.com/...",
    "link": "https://financialmodelingprep.com/market-news/...",
    "author": "Gordon Thompson",
    "site": "Financial Modeling Prep"
  }
]
```

Data inserted into `news` table:
```
headline: "WEC Energy Group, Inc. (NYSE: WEC) Sees Positive Outlook..."
timestamp: "2025-10-27 19:10:17"
url: "https://financialmodelingprep.com/market-news/..."
source: "Financial Modeling Prep"
tickers: "NYSE:WEC"
content: "<ul>...</ul>"
```
