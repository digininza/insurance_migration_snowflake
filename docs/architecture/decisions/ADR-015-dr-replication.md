# ADR-015: DR with account replication and failover groups

**Status:** Accepted

## Context
RPO 1 h / RTO 4 h for claims ops reporting.

## Decision
Failover group replicating CORE, MART, CONTROL, roles and integrations to Central US every 30 min; ADLS GZRS.

## Alternatives considered
Rebuild from ADLS on disaster (rejected: 48 TB reload exceeds RTO).

## Consequences
Replication credits + storage in secondary; semi-annual failover test.
