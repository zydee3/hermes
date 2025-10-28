# Database Tables

**Purpose:** Database schema reference. Understand the table structure, required columns, and how Hermes maintains bounded metadata growth.

Hermes uses a bounded set of database tables. All metadata tables have exactly 1 row per source definition, preventing unbounded growth.

## source_definitions

Stores source definition configurations.

```sql
CREATE TABLE source_definitions (
  name TEXT PRIMARY KEY,
  description TEXT,
  url TEXT NOT NULL,
  table_name TEXT NOT NULL,
  schedule TEXT NOT NULL DEFAULT 'daily',
  execution_timeout INT NOT NULL DEFAULT 300,
  execution_max_retries INT NOT NULL DEFAULT 5,
  execution_retry_reset_period TEXT NOT NULL DEFAULT '1d',
  params JSONB,
  response_config JSONB,
  pagination_config JSONB,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Key columns:**
- `name` - Unique identifier for the source
- `url` - API endpoint to fetch from
- `table_name` - Which data table to insert into
- `schedule` - How often to execute (daily, hourly, interval:30m)
- `execution_timeout` - Max seconds per execution
- `execution_max_retries` - Max retry attempts per reset period
- `execution_retry_reset_period` - How often to reset retry counter (1h, 1d, 7d)
- `status` - Controls whether scheduler will execute this source. "active" = scheduler will execute, any other value (e.g., "banned") = scheduler skips

**Bounded:** Exactly 1 row per source definition

## retries

Tracks retry state for each source definition.

```sql
CREATE TABLE retries (
  source_name TEXT PRIMARY KEY REFERENCES source_definitions(name) ON DELETE CASCADE,
  retry_count INT NOT NULL DEFAULT 0,
  period_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  next_retry_at TIMESTAMPTZ
);
```

**Key columns:**
- `source_name` - References source_definitions.name
- `retry_count` - Number of failures within current retry period
- `period_start` - When the current retry period started
- `next_retry_at` - When to retry next (NULL if not in backoff)

**Bounded:** Exactly 1 row per source definition

**Lifecycle:**
- Row created on first failure
- `retry_count` increments with each failure
- `period_start` resets when `NOW() - period_start >= retryResetPeriod`
- When period resets, `retry_count` resets to 0
- Deleted when source definition is deleted (CASCADE)

## Data Tables

User-defined tables that store fetched data. Examples: `prices`, `news`, `company_info`.

**Required columns:**
```sql
CREATE TABLE {table_name} (
  id SERIAL PRIMARY KEY,
  source_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- ... other columns specific to data type ...
  UNIQUE(...) -- Constraint to prevent duplicates
);
```

**Key columns:**
- `source_name` - Provenance metadata tracking which source fetched this data (references source_definitions.name)
- `created_at` - Provenance metadata tracking when data was fetched

**Purpose:**
1. Store actual fetched data (primary purpose)
2. Track data lineage (which source provided this data)
3. Track last execution time via `MAX(created_at) WHERE source_name = ?`

**Design note:**
The `source_name` and `created_at` columns serve dual purposes: data provenance and execution state tracking. This means the same data fetched from different sources will result in separate rows with different `source_name` values. This is intentional - it allows you to compare data quality across sources and maintain a complete audit trail of where your data came from.

**Not bounded:** Grows with actual data fetched (this is the point of the system)

**Example:**
```sql
CREATE TABLE prices (
  id SERIAL PRIMARY KEY,
  source_name TEXT NOT NULL,
  symbol TEXT NOT NULL,
  price DECIMAL NOT NULL,
  timestamp TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(source_name, symbol, timestamp)  -- Unique per source, allows comparing data across sources
);
```

**Handling Multiple Sources for Same Data:**

If you have multiple sources providing the same data (e.g., Yahoo Finance and Alpha Vantage both provide AAPL prices), the UNIQUE constraint must include `source_name`:

```sql
UNIQUE(source_name, symbol, timestamp)  -- Allows same data from different sources
```

This allows you to:
- Compare data quality across sources
- Identify discrepancies between providers
- Switch sources without losing historical attribution
- Maintain complete audit trail

If you only want one source to "win" and don't care about provenance comparison:

```sql
UNIQUE(symbol, timestamp)  -- Only one source can provide this data point
```

With this constraint, if two sources try to insert the same `(symbol, timestamp)`, the second insert will be ignored via `ON CONFLICT DO NOTHING`.

## rate_limiter_state

Tracks API rate limiter state for crash recovery.

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

**Bounded:** Exactly 1 row per domain (defined in provider configuration files)

**Lifecycle:**
- Rows are created when RateLimiter starts and detects new APIs
- Updated every 10 seconds by RateLimiter background loop
- Used for crash recovery (rebuild in-memory state)

See [RateLimiter](rate-limiter.md) for details on rate limiting behavior.

## Summary

**Bounded tables (1 row per source):**
- `source_definitions` - Configuration
- `retries` - Retry state

**Bounded tables (1 row per domain):**
- `rate_limiter_state` - Rate limiting state

**Unbounded tables:**
- Data tables - Actual fetched data

Total metadata overhead: 2 rows per source definition + 1 row per unique domain (fixed cost)
