# ADR-009: Streams + Tasks + stored procedures for STAGE/CORE

**Status:** Accepted

## Context
Ported Informatica logic includes SCD2, lookups with fallback, routers to error tables, per-step audit.

## Decision
Append-only streams on RAW, task DAG with WHEN conditions, Snowflake Scripting procedures with explicit transactions.

## Alternatives considered
Dynamic Tables for everything (rejected: one output per DT, no procedural SCD2/quarantine); external orchestrator calling SQL (rejected: coupling ADF to every step).

## Consequences
Procedures need unit tests (run in CI against a clone) and a finalizer task for audit.
