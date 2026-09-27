# ADR-003: Separate PROD and NONPROD accounts

**Status:** Accepted

## Context
Blast radius of a mis-grant in a single account includes PROD PHI.

## Decision
Two accounts in one Snowflake organisation: NONPROD (DEV, QA databases) and PROD. Account-level objects (integrations, roles) deployed to both via CI.

## Alternatives considered
Single account with env-prefixed databases (rejected for PROD PHI isolation); account per env (rejected: 3x admin overhead).

## Consequences
Cloning PROD → QA crosses accounts → uses database replication of a masked subset, or QA clone is created inside PROD account in a restricted QA database; we chose replication of CORE to NONPROD with policies.
