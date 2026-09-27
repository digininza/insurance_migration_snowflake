# Runbook — secret and key rotation

## Snowflake key-pair (ADF loader, CI/CD) — every 180 days, zero downtime
1. Generate new RSA 2048 key (encrypted PKCS#8) on a secure workstation.
2. `ALTER USER SVC_PROD_ADF_LOADER SET RSA_PUBLIC_KEY_2 = '<new public key>';`
3. Store new private key + passphrase as new **versions** of the Key Vault secrets (ADF resolves latest version).
4. Run a test pipeline (PL_30 read). Check `LOGIN_HISTORY` shows successful key-pair logins.
5. `ALTER USER SVC_PROD_ADF_LOADER UNSET RSA_PUBLIC_KEY;` (key 1 retired). Next rotation uses slot 1.

## Source DB passwords — every 90 days
Dual-account swap (`svc_adf_reader_a` / `_b`): update KV secret + linked service user in metadata, then disable the old account.

## Tri-Secret Secure CMK — annual
Rotate key version in Key Vault (Managed HSM); Snowflake re-keys automatically. **Never delete/disable the
key** — revoking it makes the account unreadable (that is the kill switch, used only by the CISO process).
