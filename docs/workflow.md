# Workflow

**Purpose:** Complete walkthrough showing how data flows through Hermes from user command to database storage. Follow this step-by-step guide to understand the full execution lifecycle with concrete examples.

## Components

1. **Receiver**: Accepts and persists source definitions (write operations)
2. **Viewer**: Queries system state (read operations)
3. **Scheduler**: Evaluates sources and delegates work to workers
4. **Worker**: Fetches data from APIs and stores results

## Architecture

```
User → Receiver → [source_definitions table]
  ↓                       ↓
Viewer ← [data tables] ← Scheduler → [in-memory queue] → Workers
                          ↑                                  ↓
                          └──────────[data tables]───────────┘
```

**Write path**: User → Receiver → Database
**Read path**: User → Viewer ← Database
**Execution path**: Scheduler → Workers → Data tables → Scheduler (checks timestamps)

## Complete Flow

### 1. User Adds Source Definition

```bash
hermes add fmp-articles.yaml
```

**Receiver**:
- Parses YAML
- Validates structure
- Inserts into `source_definitions` table
- Sets `status = 'active'`
- Returns immediately

### 2. Scheduler Evaluates Sources

**Scheduler** (runs every minute):
- Queries: `SELECT * FROM source_definitions WHERE status = 'active'`
- For each source:
  1. Check if already in-flight (skip if executing)
  2. Check if in backoff period (skip if retrying)
  3. Check schedule:
     ```sql
     SELECT MAX(created_at) as last_run
     FROM {source.table}
     WHERE source_name = '{source.name}'
     ```
  4. If should execute:
     - Create context with timeout from source definition
     - Add to in-flight index
     - Queue task with context

### 3. Worker Executes Task

**Worker** (pulls from in-memory queue):
- Receives task containing source name and context (with timeout)
- Loads source definition from database:
  ```sql
  SELECT * FROM source_definitions WHERE name = 'fmp-articles'
  ```
- Gets: URL, params, field mappings, table name, execution config

### 4. Worker Fetches Data

**Worker**:
- Constructs URL: `https://financialmodelingprep.com/stable/fmp-articles?page=0&limit=20&apikey=...`
- Makes HTTP GET request
- Receives JSON array response
- Parses using `dataPath` and `fields` from source definition

### 5. Worker Stores Data

**Worker**:
- Checks context (abort if cancelled)
- For each record in response:
  ```sql
  INSERT INTO news (source_name, headline, timestamp, url, source, tickers, content, created_at)
  VALUES ('fmp-articles', ..., NOW())
  ON CONFLICT DO NOTHING
  ```
- Returns success to scheduler

**Scheduler**:
- Removes source from in-flight index
- Resets retry state for current period:
  ```sql
  UPDATE retries
  SET retry_count = 0, next_retry_at = NULL
  WHERE source_name = 'fmp-articles'
  ```

### 6. Scheduler Repeats

**Scheduler** (next run):
- Checks `fmp-articles` again
- Sees recent `created_at` timestamp in `news` table
- Skips execution (already ran recently)
- Next day, timestamp is old, executes again

## Data Tables as State

Each data table includes required columns (see [Database Tables](database_tables.md)):
- `source_name` column: Links data to source definition
- `created_at` column: Timestamp of fetch (doubles as execution state)

Scheduler uses `MAX(created_at)` grouped by `source_name` to determine last execution time.

No separate jobs table needed - data tables track their own freshness.

## Failure Flow

### Worker Failure

**Worker**:
- HTTP request fails or crashes mid-execution
- Returns failure to scheduler

**Scheduler**:
- Receives failure notification
- Increments `retry_count` in `retries` table
- Calculates next retry time with exponential backoff (2^retry_count minutes)
- Updates `retries` table:
  ```sql
  INSERT INTO retries (source_name, retry_count, period_start)
  VALUES ('fmp-articles', 1, NOW())
  ON CONFLICT (source_name) DO UPDATE
  SET retry_count = retries.retry_count + 1
  ```
- If `retry_count < maxRetries`, schedule retry with backoff
- If `retry_count >= maxRetries`, skip source until retry period resets

**Example retry timeline (maxRetries: 5, retryResetPeriod: 1d):**
```
Day 1 10:00: Attempt 1 fails → retry_count = 1, retry in 2 minutes
Day 1 10:02: Attempt 2 fails → retry_count = 2, retry in 4 minutes
Day 1 10:06: Attempt 3 fails → retry_count = 3, retry in 8 minutes
Day 1 10:14: Attempt 4 fails → retry_count = 4, retry in 16 minutes
Day 1 10:30: Attempt 5 fails → retry_count = 5, exhausted for the day
Day 1 11:00: Skipped (retry_count >= maxRetries)
Day 2 00:00: Period resets → retry_count = 0, fresh budget
Day 2 00:01: Execute normally
```

### Timeout

**Scheduler** (checks every minute):
- Detects execution exceeded timeout (from source definition)
- Cancels worker context
- Handles as failure (increments retry attempt)

**Worker**:
- Context cancelled mid-execution
- Aborts HTTP request
- Returns failure

### Retry Budget Exhausted

**After max retries exceeded within retry period:**
- Source skipped until retry period resets
- No manual intervention needed
- Each time the scheduler evaluates sources (every minute), it checks if the retry period has elapsed: `NOW() - period_start >= retryResetPeriod`
- If elapsed, scheduler resets `retry_count` to 0 via SQL
- Source gets fresh retry budget and executes normally

The reset happens automatically during the scheduler's normal evaluation cycle - no separate background process needed.

### Service Crash

**On Restart**:
1. In-memory queue is cleared
2. Scheduler evaluates all sources from database
3. Checks data tables for last execution times
4. Rebuilds work queue for sources that should execute
5. Workers start processing

**Incomplete fetches** (crashed mid-execution):
- Partial data was inserted (records inserted before crash remain in database)
- `MAX(created_at)` reflects last inserted record (may be mid-pagination)
- Source will execute again on next scheduler run
- On retry, idempotent inserts skip already-inserted records
- Fetch continues making progress until complete

## Delete Source

```bash
hermes delete fmp-articles
```

**Receiver**:
- Deletes from `source_definitions`: `DELETE FROM source_definitions WHERE name = 'fmp-articles'`
- Deletes data: `DELETE FROM news WHERE source_name = 'fmp-articles'`

**Scheduler**:
- Will not create new tasks (source no longer exists in database)

**In-memory tasks** (if delete happens while task is queued):
- Worker attempts to load source definition
- Source not found → worker returns error
- Task discarded

## Key Principles

**Stateless execution**: Workers don't track state, just execute and return

**Data tables as state**: Execution history derived from `created_at` timestamps

**In-memory work queue**: Exists only while service runs, rebuilt on restart

**Database as source of truth**:
- Source definitions define what to fetch
- Data tables show what was fetched and when
- No intermediate job/task tables

**Idempotency**: All inserts use `ON CONFLICT DO NOTHING` to handle retries/duplicates

**Simple crash recovery**: Check data tables, re-execute anything that's due

## Update Behavior

When a source definition is updated:

```bash
hermes update fmp-articles.yaml
```

**Receiver**: Updates record in `source_definitions` table

**Scheduler**:
- Loads fresh source definitions each cycle
- Next task for this source uses updated definition

**In-memory tasks** (if update happens while task is queued):
- Worker loads source definition when it executes
- Gets updated definition from database
- Uses new configuration

**Timing**: Updates take effect on next execution (minutes to hours depending on schedule)
