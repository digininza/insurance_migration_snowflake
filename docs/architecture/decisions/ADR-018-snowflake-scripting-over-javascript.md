# ADR-018: Snowflake Scripting (SQL) procedures, not JavaScript/Python

**Status:** Accepted

## Context
Team skills are SQL; procedures are mostly MERGE/INSERT with control flow.

## Decision
LANGUAGE SQL (Snowflake Scripting) with EXCEPTION blocks and explicit transactions.

## Alternatives considered
JavaScript procs (rejected: string-built SQL, harder review); Snowpark Python (kept for recon utilities only).

## Consequences
Keep procs thin; logic in set-based SQL, not loops/cursors.
