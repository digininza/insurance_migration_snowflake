# ADR-002: Business Critical edition

**Status:** Accepted

## Context
PHI under HIPAA; Snowflake signs a BAA only for Business Critical (or higher); security wants customer-managed keys and private connectivity.

## Decision
Business Critical edition in PROD and NONPROD (NONPROD holds masked clones of PHI).

## Alternatives considered
Enterprise (rejected: no BAA for PHI, no Tri-Secret Secure, no Private Link).

## Consequences
Higher credit price (~1.5x of Standard, illustrative); enables Tri-Secret Secure, Private Link, failover groups.
