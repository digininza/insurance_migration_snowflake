# ADR-012: Clustering key on FACT_CLAIM_LINE only

**Status:** Accepted

## Context
2.4 B rows; queries filter service month + LOB; incremental MERGE touched most partitions.

## Decision
CLUSTER BY (service_month, lob_code); history inserted pre-sorted; MERGE bounded by service_month range.

## Alternatives considered
Cluster every large table (rejected: auto-clustering credits without query benefit); cluster by claim_id (rejected: high cardinality, point lookups served by Search Optimization instead).

## Consequences
Monitor clustering depth and AUTOMATIC_CLUSTERING_HISTORY credits.
