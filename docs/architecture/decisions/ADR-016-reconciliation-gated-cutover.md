# ADR-016: Reconciliation-gated cutover

**Status:** Accepted

## Context
Finance and actuarial will not accept a new platform without proof of parity.

## Decision
Six-level reconciliation (count, amount, key hash, type/schema, business rule, report KPI) run daily during parallel run; cutover only after 3 consecutive clean month-ends.

## Alternatives considered
Sample-based UAT only (rejected: misses systematic 1-cent and late-adjustment breaks).

## Consequences
Parallel run cost (both platforms for ~3 months); legacy extract feed must be maintained until cutover.
