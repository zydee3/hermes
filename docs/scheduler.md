# Scheduler

**Purpose:** Technical reference for the scheduler component. Understand how Hermes determines when to execute sources, manages retries, and handles failures.

The scheduler executes data fetches from active source definitions at the appropriate times.

## Responsibilities

- Load active source definitions from database
- Determine if each source should execute now based on schedule
- Package source definition into complete execution context for workers
- Maintain in-flight execution index (bounded: 1 entry per source)
- Track retry state in `retries` table (bounded: 1 entry per source)
- Handle timeouts and retry logic with exponential backoff
- Reset retry counters when retry period elapses

## In-Flight Execution Index

The scheduler maintains an in-memory index tracking which sources have queued work.

**Why this exists:**
With the scheduler evaluating sources every minute, a long-running job (2+ minutes) could be queued multiple times before completion. Without tracking, the same source would be added to the queue repeatedly, wasting queue slots and potentially executing duplicate fetches.

**How it works:**
- When scheduler determines a source should execute, it checks the in-flight index
- If the source is already in the index, skip it (work already queued)
- If not in the index, add source to index immediately, then queue the task
- When worker completes (success or failure), scheduler removes source from index

**Key properties:**
- At most 1 entry per source definition (bounded size)
- Entry created at queue time (not execution time)
- Prevents duplicate queueing between scheduler evaluation cycles
- Cleared on service restart (ephemeral state)

**Example timeline:**
```
10:00:00 - Scheduler evaluates source A → should execute
10:00:00 - Check in-flight index → not present
10:00:00 - Add source A to in-flight index
10:00:00 - Queue task for source A
10:00:30 - Scheduler runs again, evaluates source A → should execute
10:00:30 - Check in-flight index → already present, skip
10:01:00 - Worker starts executing source A
10:02:00 - Worker completes
10:02:00 - Scheduler removes source A from in-flight index
```

## Retries Table

The `retries` table tracks retry state per source definition. See [Database Tables](database_tables.md) for schema.

**Key properties:**
- Exactly 1 row per source definition (bounded)
- `period_start`: When the current retry period started
- `retry_count`: Number of failures within current period
- `next_retry_at`: When to retry next (NULL if not in backoff)

## Schedule Logic

The scheduler evaluates all sources every minute to determine which should execute:

1. Load all active source definitions from the database (`status = 'active'`)
2. For each source, query its data table: `SELECT MAX(created_at) FROM {table} WHERE source_name = '{name}'`
3. Determine if source should execute based on:
   - Never run before (no data in table), OR
   - Enough time has elapsed since last execution (based on schedule config)
4. If should execute, package the complete execution context:
   - URL and parameters
   - Field mappings
   - Target table name
   - Timeout value
5. Queue the task for workers to process

## Queue Backpressure

The scheduler manages a bounded in-memory queue to prevent unlimited memory growth.

**Why this exists:**
Hermes is designed to run on minimal hardware. An unbounded queue could grow indefinitely if sources are added faster than workers can process them, consuming all available memory. A bounded queue provides a fixed memory footprint regardless of how many sources are configured.

**How it works:**
- Queue has a fixed maximum size (configurable, typically 5-10 items)
- Every minute, scheduler loads all active sources from database
- For each source that should execute (passes schedule, in-flight, rate limit, and retry checks):
  - If queue has space: add to queue and mark in-flight
  - If queue is full: skip (will try again next minute)
- Workers pull tasks from the queue in FIFO order
- Source execution order is determined by database query order - first N sources that pass all checks fill the queue

This provides natural backpressure - if workers can't keep up with the scheduled load, the queue fills and the scheduler automatically throttles new work.

**Example:** With 1 worker, queue size 5, and 20 daily sources:
- Scheduler run 1: Adds 5 sources to queue (15 skipped)
- After 1 minute: Worker completes 1, queue has 4 items
- Scheduler run 2: Adds 1 more source to queue (14 remaining skipped)
- Over ~20 minutes: All sources eventually execute

## Timeout Handling

On each scheduler evaluation cycle, the scheduler checks all in-flight executions for timeouts.

**How it works:**
- Scheduler checks each in-flight job's elapsed time
- If elapsed time exceeds the source's configured timeout, cancel the worker's execution context
- In-flight HTTP requests are cancelled
- Worker sees cancellation and aborts execution
- Workers check for cancellation between pagination pages and write one batch per page
- Records from completed pages are saved; records from the current page in progress are lost
- Scheduler handles the cancellation as a failure (triggers retry logic)

Users should configure timeout values that accommodate the full fetch duration, especially for paginated sources.

## Retry Period Reset

When the retry period elapses, the source gets a fresh retry budget. The scheduler checks this during each evaluation cycle.

**Why configurable periods exist:**
Different APIs have different rate limit windows and failure characteristics:
- Some APIs have per-minute limits (100 requests/minute) - short retry periods make sense
- Some APIs have per-day limits (1000 requests/day) - if you exhaust retries, waiting 23.5 hours before resetting is wasteful
- Some APIs are flaky during certain hours but reliable otherwise - daily reset periods allow fresh attempts the next day

Each source can configure `retryResetPeriod` to match the API's actual behavior and limits.

**How it works:**
- On each scheduler run, check if `NOW() - period_start >= retryResetPeriod` for each source
- If the period has elapsed, reset the retry state:
  ```sql
  UPDATE retries
  SET retry_count = 0, period_start = NOW()
  WHERE source_name = ? AND NOW() - period_start >= ?
  ```
- The source can now execute normally with a fresh retry budget

**Example:** With `retryResetPeriod: 1d` and `maxRetries: 5`:
- Day 1 10:00: Source exhausts all 5 retries
- Day 1 11:00-23:59: Scheduler skips source (retry budget exhausted)
- Day 2 00:01: Scheduler detects period elapsed (24+ hours since period_start)
- Day 2 00:01: Scheduler resets retry_count to 0 via SQL
- Day 2 00:01: Source executes normally

No background jobs or separate reset process needed - the scheduler handles this during normal evaluation.

## Crash Recovery

On service restart, the in-flight index is cleared (all ephemeral state lost). Scheduler loads all sources from database and loads retry state from `retries` table. Retry state persists across restarts - the scheduler continues retry logic where it left off, and period resets happen on the next scheduler run after restart.

