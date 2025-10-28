# Receiver

**Purpose:** Reference for CLI write operations (add, update, delete). Learn how to register and manage source definitions.

The receiver accepts and persists source definition changes. It handles all write operations from the CLI.

## Responsibility

Accept, validate, and persist source definitions and their changes.

## Operations

### Add

```bash
hermes add fmp-articles.yaml
```

1. Parse YAML file
2. Validate required fields (name, url, table)
3. Insert into database
4. Set status to `active`

### Update

```bash
hermes update fmp-articles.yaml
```

1. Parse YAML file
2. Check if source with same name exists
3. Update existing record
4. Preserve status unless explicitly changed

### Delete

```bash
hermes delete fmp-articles
```

Remove source definition and all associated data:

1. Delete from `source_definitions` table
2. Delete all data from data tables where `source_name` matches

This is a permanent operation. The source definition and all data it collected are removed.

## Validation

Required fields:
- `name`: Must be unique
- `url`: Must be valid URL
- `table`: Must be non-empty and valid

Optional fields:
- `description`
- `params`: Defaults to empty array
- Pagination configs: Defaults to null

**Rate limiting:**
The domain is automatically extracted from the URL. If the domain matches an entry in the provider configuration files, rate limiting is enforced. If not, the source executes without rate limiting.

See [RateLimiter](rate-limiter.md) for rate limit configuration details.

## Response

Returns success/failure immediately. Does not wait for jobs to be created or executed.

## Update Timing

Updates to source definitions are applied to future job executions only.
If a job is currently executing when you run `hermes update`, that job
will complete using its already-loaded definition. The next scheduled
job will use the updated definition.

For most sources (daily/hourly schedules), updates take effect within
minutes to hours. For high-frequency sources, updates take effect on
the next job (typically within minutes).
