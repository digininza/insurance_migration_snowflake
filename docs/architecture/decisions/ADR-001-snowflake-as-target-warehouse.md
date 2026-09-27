# ADR-001: Snowflake as the target warehouse

**Status:** Accepted

## Context
Oracle Exadata EDW at 92% capacity; licence renewal due; 12 years of claims needed online; Azure is the corporate cloud.

## Decision
Snowflake on Azure (East US 2) replaces the Oracle EDW.

## Alternatives considered
Azure Synapse dedicated pools (rejected: manual scaling/pausing, concurrency slots, weaker workload isolation); Databricks SQL (rejected: team is SQL/ETL-skilled, not Spark; PHI governance simpler in one SQL engine); lift-and-shift Oracle to Azure VM (rejected: keeps the scaling problem).

## Consequences
Separation of storage/compute, per-workload warehouses, zero-copy clones, Time Travel. Team needed Snowflake training; cost must be governed actively (resource monitors).
