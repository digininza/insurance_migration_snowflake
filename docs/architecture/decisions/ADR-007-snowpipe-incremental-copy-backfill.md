# ADR-007: Snowpipe for incremental, bulk COPY for backfill

**Status:** Accepted

## Context
Incremental files arrive throughout the extract window; history is ~60 000 large files.

## Decision
Snowpipe AUTO_INGEST via Event Grid + Storage Queue + notification integration for incremental; COPY INTO on a dedicated XL warehouse, triggered by ADF, for backfill.

## Alternatives considered
Snowpipe for everything (rejected for backfill: unpredictable latency and cost at burst, no control over timing); scheduled COPY for incremental (rejected: needs warehouse, polling, higher latency); Snowpipe Streaming (not needed: sources are batch extracts).

## Consequences
Two load paths to document; both land into the same RAW tables with the same file format and metadata columns.
