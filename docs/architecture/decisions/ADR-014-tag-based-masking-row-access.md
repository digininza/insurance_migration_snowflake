# ADR-014: Tag-based masking + LOB row access

**Status:** Accepted

## Context
HIPAA minimum necessary; Medicaid contracts require state-level separation.

## Decision
PHI_CLASS tag with masking policies attached to the tag; row access policy driven by a role→LOB mapping table.

## Alternatives considered
Column-by-column masking policies (rejected: new columns unprotected by default); separate databases per LOB (rejected: duplicates model).

## Consequences
Policy evaluation adds small overhead; mapping-table changes are access changes → go through access review.
