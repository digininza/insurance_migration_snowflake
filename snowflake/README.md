# Snowflake objects

Numbered folders = logical layers; **deploy order is `deploy/manifest.txt`**
(checked by `src/tools/sql_manifest.py`). Scripts use SnowSQL variables
`&{ENV}`, `&{AZURE_TENANT_ID}`, `&{ADLS_ACCOUNT}`, `&{PHI_SALT_REF}` and are idempotent.

| Folder | What |
|---|---|
| `00_account` | Roles (access/functional/service), 8 workload warehouses, resource monitors, network policy + key-pair service users |
| `01_integration` | Storage integration (ADLS), notification integration (Event Grid queue) + email, file formats, external stages |
| `02_databases` | RAW / STAGE (transient) / CORE / MART / CONTROL + managed-access schemas, future grants |
| `03_raw` | RAW tables (schema evolution + lineage columns), 11 Snowpipes, bulk backfill COPY proc |
| `04_control` | Feed registry/status, file load log, ADF run log, audit, DQ rules + runner |
| `05_staging` | STAGE tables, claim/member/eligibility stage procs, quarantine, orphan replay |
| `06_core` | Sequences, dims (SCD2), facts (versioned claims, member months, premium, pharmacy), MERGE procs |
| `07_streams_tasks` | Streams, publish gate, hourly Task DAG with finalizer, backfill DAG, month-end scaling |
| `08_marts` | Dynamic Tables, secure views, LEGACY_COMPAT views |
| `09_governance` | PHI tags, tag-based masking, LOB row access policy, column tagging |
| `10_reconciliation` | Rule-driven legacy-vs-new recon engine, scorecard, cutover green-day view |
| `11_clone_timetravel` | **Manual runbook scripts**: QA refresh, pre-release snapshot, backfill swap, parallel-run freeze, recovery |
| `12_monitoring` | Pipe/task/DT/credit/pruning/SLA views, Snowflake Alerts |
| `deploy` | `manifest.txt`, `deploy.sh` |
