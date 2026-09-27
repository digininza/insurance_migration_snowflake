# ADR-008: Kimball CORE + subject marts + legacy compat views

**Status:** Accepted

## Context
Consumers: actuaries (atomic grain), BI (aggregates), 180 legacy reports (legacy table names).

## Decision
CORE = conformed star (SCD2 dims, versioned facts). MART = Dynamic Tables and secure views. LEGACY_COMPAT = views with old EDW shapes.

## Alternatives considered
Data Vault 2.0 (rejected: few, stable sources; extra layer without benefit); marts only (rejected: duplicated logic, no atomic history for actuarial).

## Consequences
Compat views need owners and sunset dates; tracked via ACCESS_HISTORY.
