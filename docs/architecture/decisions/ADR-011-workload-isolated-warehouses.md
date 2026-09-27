# ADR-011: Workload-isolated warehouses

**Status:** Accepted

## Context
Backfill, MERGE, BI and recon have different shapes and priorities.

## Decision
BACKFILL (XL temp), INGEST (XS), TRANSFORM (M→L month-end), RECON (S), BI (S, 1–4 clusters + QAS), DATASCIENCE, ADHOC, CICD. Auto-suspend 60 s except BI 300 s.

## Alternatives considered
One shared warehouse (rejected: contention, no cost attribution); per-team warehouses (rejected: same workload spread across many idle warehouses).

## Consequences
Resource monitors per warehouse; monthly right-sizing review.
