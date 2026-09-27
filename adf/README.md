# Azure Data Factory — factory as code

Git-integrated factory (`repoConfiguration` → `/adf`). CI builds ARM templates with
`@microsoft/azure-data-factory-utilities` and deploys with per-environment
parameter files in `params/` (triggers stopped/started around deployment).

| Folder | Contents |
|---|---|
| `factory/` | Factory with system-assigned managed identity, public network access disabled, global parameters |
| `integrationRuntime/` | `IR_SelfHosted_OnPrem` (SQL Server/Oracle/SFTP), `IR_Azure_ManagedVNet` (private endpoints) |
| `linkedService/` | Key Vault, ADLS (MI), Azure SQL control DB (MI), SQL Server ×2, Oracle ×3 (incl. legacy EDW for recon), SFTP, Snowflake V2 (key-pair) — **all secrets are Key Vault references** |
| `dataset/` | Parameterised generic datasets (one per connector/format, not per table) |
| `pipeline/` | `PL_00` master · `PL_10/11` incremental (watermark) · `PL_12` SFTP + trailer check · `PL_20` restartable backfill · `PL_30` wait for Snowflake publish gate · `PL_40/41` reconciliation · `PL_90` alerting |
| `trigger/` | Daily schedule 01:30 ET, hourly tumbling window for claims (self-dependent), PBM polling window |
| `params/` | ARM parameter overrides per environment |

Validation (`python -m src.tools.adf_validate`, runs in CI): all references resolve,
no inline secrets, and every metadata `target_path` has a matching Snowpipe prefix.

Simplifications vs the real factory (stated honestly):
- Snowflake object names inside Script/Lookup activity text are written for PROD (`CV_PROD_…`);
  the real factory builds them from the `gp_env` global parameter.
- `PL_11` shows the CLAIMS (SQL Server) and MEMBERSHIP (Oracle) branches; the other systems follow the same pattern.
- `PL_20` shows the SQL Server `DynamicRange` variant; Oracle backfills use `PhysicalPartitionsOfTable`.
