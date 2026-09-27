# ADR-013: Key Vault for secrets, integrations instead of keys

**Status:** Accepted

## Context
Legacy parameter files held plain-text DB passwords.

## Decision
ADF uses managed identity + Key Vault references; Snowflake uses storage/notification integrations; ADF→Snowflake key-pair auth with private key in Key Vault; Tri-Secret Secure CMK in Key Vault.

## Alternatives considered
SAS tokens on stages (rejected: long-lived secrets); password auth for service users (rejected: being deprecated for service users, weaker).

## Consequences
Key rotation runbook; account-level params REQUIRE_STORAGE_INTEGRATION_FOR_STAGE_CREATION.
