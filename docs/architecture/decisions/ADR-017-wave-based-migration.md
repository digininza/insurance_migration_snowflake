# ADR-017: Wave-based migration by subject area

**Status:** Accepted

## Context
Big-bang of 420 workflows was too risky.

## Decision
Waves: 0 foundation → 1 reference + provider → 2 membership/eligibility → 3 claims (largest) → 4 premium billing + MLR → 5 pharmacy + regulatory → decommission. Dependencies drive order (claims need member + provider dims).

## Alternatives considered
Big bang (rejected); table-by-table (rejected: breaks conformed dims across platforms).

## Consequences
Bridges needed while legacy and new co-exist: LEGACY_COMPAT views and a reverse feed of new dims to legacy for one wave.
