# ADR-005: Metadata-driven ADF framework

**Status:** Accepted

## Context
420 PowerCenter workflows, mostly 'copy table X with filter Y'.

## Decision
Generic pipelines driven by ctl.source_object rows in Azure SQL DB; watermark and backfill partitions in control tables.

## Alternatives considered
One ADF pipeline per table (rejected: 420 pipelines to maintain); ADF Copy Data Tool metadata template as-is (used as starting point, extended with backfill partitions, priorities, criticality).

## Consequences
Onboarding = one row + DDL. Framework bugs affect all objects → framework has its own tests and a canary object.
