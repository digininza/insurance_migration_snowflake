# Cloud-native services used (and what each replaced)

## Azure

| Service | Role in the platform | Replaced (legacy) |
|---|---|---|
| **Azure Data Factory** | Metadata-driven extraction, backfill, SFTP ingest, orchestration of recon/alerts | PowerCenter Workflow Manager + Integration Service (extract part) |
| **Self-hosted Integration Runtime** | Secure bridge to on-prem SQL Server/Oracle (HA 2 nodes) | PowerCenter nodes' direct DB connectivity |
| **Managed VNet Azure IR + managed private endpoints** | Private access to ADLS, Key Vault, Snowflake | — |
| **ADLS Gen2** (hierarchical namespace) | Immutable Parquet landing, replay source, archive, recon extracts | NAS file shares + Oracle staging tables |
| **Event Grid** (system topic on storage) | `BlobCreated` → Storage Queue for Snowpipe auto-ingest | PowerCenter file-watcher / Event-Wait tasks |
| **Azure Storage Queue** | Durable notification channel read by Snowflake notification integration | — |
| **Azure Key Vault** (Premium/HSM) | Secrets for ADF, Snowflake key-pair, **CMK for Tri-Secret Secure** | Parameter files with passwords |
| **Azure SQL Database** | ADF control/metadata DB (`ctl` schema) | PowerCenter repository tables for parameters |
| **Managed identities / Entra ID** | ADF → ADLS/KV/SQL; SSO + SCIM into Snowflake | Shared service accounts |
| **Azure Monitor + Log Analytics** | ADF diagnostic logs (pipeline/activity runs), KQL alerts, workbook dashboards; Snowflake audit logs forwarded | Workflow Monitor |
| **Logic Apps** | Alert fan-out (Teams, email, ServiceNow incident) | Email tasks |
| **Microsoft Purview** | Catalog + lineage scans of ADLS and Snowflake; glossary of healthcare terms | Metadata Manager |
| **Microsoft Sentinel** | SIEM for Snowflake login/access history | — |
| **Azure DevOps / GitHub Actions** | CI/CD of ADF ARM templates and Snowflake SQL | Manual deployment groups |
| **ExpressRoute** | Private on-prem ↔ Azure bandwidth for 48 TB backfill | — |
| **Power BI + VNet data gateway** | Reporting over Private Link | Cognos (gradually) |

## Snowflake-native features

| Feature | Why it's here |
|---|---|
| **Storage integration** | Keyless, revocable access to ADLS |
| **Notification integration + Snowpipe auto-ingest** | Event-driven, serverless incremental loads |
| **`COPY INTO`** (bulk) | Historical backfill with predictable throughput |
| `MATCH_BY_COLUMN_NAME`, `INCLUDE_METADATA`, schema evolution on RAW | Drift-tolerant Parquet loads with lineage columns |
| **Streams** (append-only + standard) | CDC inside Snowflake, only process changed rows |
| **Tasks** (DAG, `AFTER`, `WHEN`, finalizer, serverless) | In-database orchestration of ELT steps |
| **Stored procedures (Snowflake Scripting)** | Ported Informatica mapping logic, transactional MERGE, error handling |
| **Dynamic Tables** | Declarative marts with target lag; replace ~60 aggregate mappings |
| **Zero-copy cloning** | QA/UAT, parallel run freeze, backfill-and-swap, release rollback |
| **Time Travel / UNDROP / Fail-safe** | Recovery from bad loads; point-in-time recon |
| **Tag-based masking, row access policies, object tagging** | HIPAA minimum-necessary |
| **Tri-Secret Secure, Private Link** (Business Critical) | PHI requirements |
| **Search Optimization, clustering, Query Acceleration** | TB-scale performance |
| **Resource monitors, budgets** | Cost guard-rails |
| **Alerts + email notification integration** | Pipe/task failure and SLA alerts from inside Snowflake |
| **ACCESS_HISTORY / ACCOUNT_USAGE** | Audit, compat-view sunset, cost attribution |
| **Account replication + failover groups** | DR to paired region |
| **Secure views / secure data sharing** | Regulatory extracts and a share to the actuarial consulting partner (no file copies) |
