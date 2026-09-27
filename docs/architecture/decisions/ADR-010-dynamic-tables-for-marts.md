# ADR-010: Dynamic Tables for marts

**Status:** Accepted

## Context
~60 legacy aggregate mappings rebuilt summaries nightly with full truncate/insert.

## Decision
Dynamic Tables with target lag (DOWNSTREAM for intermediates, 1h/6h/1d for leaves), incremental refresh verified.

## Alternatives considered
Materialized views (rejected: no joins); tasks + MERGE per aggregate (rejected: more code, same result).

## Consequences
Watch refresh mode (FULL fallback) and refresh cost; lags sized to consumer need, not 'as fresh as possible'.
