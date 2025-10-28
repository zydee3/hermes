# Viewer

**Purpose:** Reference for CLI read operations. Learn how to query and inspect source definitions and system state.

The viewer provides read-only views of system state. It handles all query operations from the CLI.

## Responsibility

Query and display current state of source definitions and data.

## Operations

### List Source Definitions

```bash
hermes list sources
```

Shows all registered source definitions and their headers.

### Get Source Details

```bash
hermes get fmp-articles
```

Shows full details of a specific source definition:

## Response Format

All operations return immediately with data from database. No interaction with scheduler or workers.
