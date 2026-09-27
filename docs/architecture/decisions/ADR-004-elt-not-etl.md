# ADR-004: ELT instead of ETL

**Status:** Accepted

## Context
PowerCenter transformed rows in the Integration Service; scaling meant more PowerCenter nodes and licences.

## Decision
Extract-Load with ADF (no business transformation), Transform in Snowflake with SQL/stored procedures/Dynamic Tables.

## Alternatives considered
ADF Mapping Data Flows (rejected: second engine, Spark cluster cost and start-up, split lineage); keep Informatica on cloud IDMC (rejected: licence cost was the main driver); dbt (considered; team standardised on Snowflake-native procs/DTs at the time — dbt is a documented future option).

## Consequences
Raw data retained → rules re-runnable; single lineage; SQL in Git. Requires strong SQL engineering standards and tests.
