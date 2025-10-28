# Worker

**Purpose:** Technical reference for the worker component. Understand how Hermes fetches data from APIs, handles pagination, and ensures idempotent data storage.

Workers execute data fetches from APIs and store results. They operate statelessly, executing tasks from an in-memory queue.

## Responsibilities

- Receive fetch tasks from scheduler (via in-memory queue)
- Execute HTTP request using provided context
- Parse response
- Insert data into target table
- Return completion status

## Architecture

Workers are **stateless executors**:
- No job claiming or locking
- No persistent state tracking
- Receive work from in-memory queue
- Execute and return result
- Scheduler decides when to retry on failure

## Execution Flow

Workers receive tasks from the in-memory queue containing all necessary context (URL, parameters, field mappings, target table, execution timeout). They execute the HTTP fetch with the provided context, check for cancellation throughout, parse the response using the provided configuration, store data in the target table, and return the result (success/failure) to the scheduler.

## Data Fetch

Workers use the URL and parameters provided by the scheduler, make an HTTP GET request, parse the JSON response, extract fields using the field mappings, standardize the data, and insert it into the database.

## Data Storage

Workers insert each record from the response into the target table with the `source_name` field, which tracks which source definition collected the data.

## Pagination Handling

Workers handle both offset-based (page numbers) and cursor-based (tokens) pagination. All pagination happens within a single worker execution - the worker fetches all pages, then returns.

**How it works:**
- Worker fetches page 1, inserts records immediately (one by one or in small batches)
- Worker fetches page 2, inserts records immediately
- Continues until no more pages remain
- Each insert uses `ON CONFLICT DO NOTHING` for idempotency

**Timeout considerations:**
- The configured timeout should accommodate fetching all pages
- If timeout is exceeded mid-pagination, the execution is cancelled
- Records inserted before cancellation remain in the database (partial progress is saved)
- On retry, the worker starts from page 1 again
- Idempotent inserts ensure previously fetched records are skipped (no duplicates)

This means large historical fetches can make incremental progress across multiple attempts if timeout is too short. Each retry adds more data until the full dataset is complete.

Users should configure timeout values appropriate for their expected data volume to minimize unnecessary retries. For large historical fetches spanning many pages, set timeout to hours rather than minutes.

## Error Handling

Workers return success/failure status to scheduler. Scheduler handles retry logic with exponential backoff.

Worker checks context throughout execution and aborts immediately if cancelled (timeout exceeded or service shutting down). For transient errors (network timeout, API rate limit, 5xx server errors), worker returns failure and scheduler retries with exponential backoff. For permanent errors (invalid response format, source definition not found, database constraint violation), worker returns failure with error details and scheduler retries with backoff until max retries is reached.

## Idempotency

All inserts use conflict handling to ignore duplicates using unique fields to form an unique tuple for hashing. The same fetch can execute multiple times safely (retry after failure, crash recovery, race conditions) - duplicate data is ignored by the database.

## Concurrency

Multiple workers can execute concurrently, each processing tasks from a shared in-memory queue. No coordination between workers is needed - the scheduler prevents duplicate queueing via its in-flight index, ensuring each source is queued at most once at a time. Workers process different sources simultaneously without race conditions.

## No Persistent State

Workers maintain zero persistent state and don't read from the database - they only write data. No job records, no claim tracking, no execution history. All execution context is provided by the scheduler in each task. On service restart, the in-memory queue is cleared, scheduler re-evaluates all sources, rebuilds the queue for sources that should execute, and workers start processing the fresh queue.
