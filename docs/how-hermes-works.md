# How Hermes Works

**Purpose:** High-level overview of Hermes architecture, design philosophy, and core concepts. Start here to understand the system before diving into specific components.

Hermes is a continuous data synchronization service with a CLI interface, similar to Kubernetes and kubectl.

## Architecture

**Hermes Service:**
- Runs continuously in the background
- Components:
  - **Receiver**: Handles write operations (add/update/delete sources)
  - **Viewer**: Handles read operations (list/get sources, view execution status)
  - **Scheduler**: Evaluates which sources should execute and queues work
  - **Worker**: Executes fetches from APIs and stores data
  - **RateLimiter**: Controls API request rates to prevent exceeding limits

**Hermes CLI:**
- `hermes add <file>` - Register a new SourceDefinition (Receiver)
- `hermes update <file>` - Update existing SourceDefinition (Receiver)
- `hermes delete <name>` - Remove definition and delete associated data (Receiver)
- `hermes list sources` - List source definitions (Viewer)
- `hermes get <name>` - Show details of a specific source (Viewer)

CLI communicates with the Hermes service via Unix domain sockets.

## Lifecycle

1. **Add**: User submits a SourceDefinition via `hermes add`
2. **Monitor**: Scheduler evaluates source and queues work when due
3. **Sync**: Workers fetch data and keep it up-to-date in the database
4. **Delete**: When definition is removed via `hermes delete`, stored data is also deleted

## Self-Recovering Processes

Hermes processes (scheduler, workers) don't maintain internal state. If a process crashes or the service restarts, it recovers automatically using minimal persistent data.

**How it works:**

- **Workers are stateless** - no internal state, just execute tasks and return
- **Scheduler is stateless** - loads everything from database on each evaluation cycle
- **Database stores minimal state** - source definitions, retry counters, and data timestamps
- **In-memory queue is ephemeral** - rebuilt from database after crash
- **No persistent jobs table** - execution state derived from data timestamps

**Recovery after crash:**
1. Scheduler loads all source definitions from database
2. Checks data tables to see when each source last ran (via `MAX(created_at)`)
3. Loads retry state from `retries` table
4. Rebuilds in-memory work queue for sources that should execute
5. Workers start processing

**Benefits:**
- Simpler process architecture (no state to serialize/deserialize)
- No metadata table growth (no job history)
- Execution history directly tied to data
- Automatic recovery without manual intervention

## SourceDefinition Files

Each SourceDefinition is a self-contained specification for what data to fetch. Files are stored in the configured sources directory.

One SourceDefinition = one data stream (e.g., `fmp-aapl-historical.yaml` fetches AAPL historical prices).

## Data Tables

All data tables must include required columns (see [Database Tables](database_tables.md)):
- `source_name` column: Links data back to source definition
- `created_at` column: Timestamp of when data was fetched

These columns serve dual purpose:
1. Track data provenance (which source fetched this)
2. Track execution state (when did this source last run)

The scheduler queries `MAX(created_at)` grouped by `source_name` to determine last execution time.
