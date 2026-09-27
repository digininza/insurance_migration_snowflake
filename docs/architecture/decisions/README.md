# Architecture Decision Records

| ADR | Decision |
|---|---|
| [ADR-001](ADR-001-snowflake-as-target-warehouse.md) | Snowflake as the target warehouse |
| [ADR-002](ADR-002-business-critical-edition.md) | Business Critical edition |
| [ADR-003](ADR-003-separate-prod-account.md) | Separate PROD and NONPROD accounts |
| [ADR-004](ADR-004-elt-not-etl.md) | ELT instead of ETL |
| [ADR-005](ADR-005-adf-metadata-driven.md) | Metadata-driven ADF framework |
| [ADR-006](ADR-006-parquet-landing.md) | Parquet (Snappy) as landing format |
| [ADR-007](ADR-007-snowpipe-incremental-copy-backfill.md) | Snowpipe for incremental, bulk COPY for backfill |
| [ADR-008](ADR-008-kimball-core-plus-marts.md) | Kimball CORE + subject marts + legacy compat views |
| [ADR-009](ADR-009-streams-tasks-procs-for-core.md) | Streams + Tasks + stored procedures for STAGE/CORE |
| [ADR-010](ADR-010-dynamic-tables-for-marts.md) | Dynamic Tables for marts |
| [ADR-011](ADR-011-workload-isolated-warehouses.md) | Workload-isolated warehouses |
| [ADR-012](ADR-012-clustering-fact-claim-line.md) | Clustering key on FACT_CLAIM_LINE only |
| [ADR-013](ADR-013-key-vault-and-keyless-integrations.md) | Key Vault for secrets, integrations instead of keys |
| [ADR-014](ADR-014-tag-based-masking-row-access.md) | Tag-based masking + LOB row access |
| [ADR-015](ADR-015-dr-replication.md) | DR with account replication and failover groups |
| [ADR-016](ADR-016-reconciliation-gated-cutover.md) | Reconciliation-gated cutover |
| [ADR-017](ADR-017-wave-based-migration.md) | Wave-based migration by subject area |
| [ADR-018](ADR-018-snowflake-scripting-over-javascript.md) | Snowflake Scripting (SQL) procedures, not JavaScript/Python |
