# Hermes

A personal financial data aggregator that is intended to run locally on minimal hardware.

## Problem

I need historical price, fundamental, and news data for several stocks. 
- Commercial providers are expensive. 
- Free APIs exist but each has different formats, rate limits, and field names. 
- Writing custom parsers for each different API is repetitive.
- Maintaining database completeness is difficult.

## Solution

Hermes fetches data from multiple free financial APIs and stores it in a common schema database. It uses declarative Source Definitions (YAML files) where each API endpoint is configured without writing code. The goal is to avoid tightly coupled API code that may become unmaintainable and unextendable.

**Source Definitions:**
- Declare API endpoint URL and parameters
- Define field mappings from source to common schema
- Configure pagination and authentication

**Hermes responsibilities:**
- Execute source definitions to fetch data
- Store data in common schema with provenance metadata
- Coordinate rate limits and retries
- Gap detection, self recovery, and backfill

## Documentation

### Getting Started

Start with these docs in order:

1. **[How Hermes Works](docs/how-hermes-works.md)** - High-level architecture and design philosophy
2. **[Source Definition](docs/source-definition.md)** - Learn how to configure data sources
3. **[Workflow](docs/workflow.md)** - Step-by-step walkthrough of the complete execution flow

### Component Reference

Deep dives into each system component:

- **[Receiver](docs/receiver.md)** - CLI write operations (add, update, delete)
- **[Viewer](docs/viewer.md)** - CLI read operations (list, get)
- **[Scheduler](docs/scheduler.md)** - Determines when to execute sources and manages retries
- **[Worker](docs/worker.md)** - Fetches data from APIs and stores results
- **[RateLimiter](docs/rate-limiter.md)** - Controls API request rates to prevent exceeding limits

### Schema Reference

- **[Database Tables](docs/database_tables.md)** - Schema, required columns, and bounded metadata design

### Quick Reference

**Register a new source:**
```bash
hermes add my-source.yaml
```

**View all sources:**
```bash
hermes list sources
```

**View source details:**
```bash
hermes get my-source
```

**Update a source:**
```bash
hermes update my-source.yaml
```

**Remove a source:**
```bash
hermes delete my-source
```
