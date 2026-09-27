# RUNBOOK — deploy, load, reconcile, cut over, operate

Detailed incident procedures live in [`docs/runbooks/`](docs/runbooks/); this
file is the end-to-end operating guide.

## 0. Prerequisites

| Item | Where |
|---|---|
| Azure: resource group, ADLS Gen2 `stcvlake<env>` (HNS on, public access off), Key Vault `kv-cv-data-<env>`, Azure SQL `sqldb-cv-adfctl`, ADF `adf-cv-dataplatform-<env>` with system MI, SHIR installed on 2 on-prem nodes | Landing-zone IaC (separate repo) |
| Snowflake: Business Critical account per tier, Private Link endpoint approved, ACCOUNTADMIN break-glass | Snowflake org admin |
| Secrets in Key Vault: source DB passwords, `snowflake-adf-loader-private-key` (+ passphrase), `sftp-pbm-private-key`, `logicapp-alert-url`, `snowflake-cicd-private-key` | Security team |
| Local: Python 3.9+, SnowSQL 1.3+ | — |

## 1. Verify locally (no cloud)

```bash
make venv && make all          # ruff + ADF validation + SQL lint + 30 tests
make assess                    # PowerCenter XML → assessment.csv
make recon                     # synthetic legacy vs new → data/recon_report.md (RED on purpose: seeded legacy defects)
```

## 2. Snowflake first-time setup (per environment)

1. Account objects (admin connection): run manifest entries `00_account/*`,
   `02_databases/*`, `01_integration/*` via
   `snowflake/deploy/deploy.sh <ENV>` (stop after `01_integration/03_file_formats_stages.sql`).
2. **Azure consent for integrations**
   ```sql
   DESC INTEGRATION SI_CV_PROD_ADLS;                 -- AZURE_CONSENT_URL, AZURE_MULTI_TENANT_APP_NAME
   DESC NOTIFICATION INTEGRATION NI_CV_PROD_ADLS_EVENTS;
   ```
   - Tenant admin opens both consent URLs.
   - Grant the Snowflake service principal **Storage Blob Data Reader** on containers `raw`, `recon`
     and **Storage Queue Data Contributor** on queue `snowpipe-raw-incremental`.
   - Create the Event Grid subscription (BlobCreated, subject prefix `/blobServices/default/containers/raw/blobs/incremental/`, suffix `.parquet` → storage queue). PBM `.txt` files use a second subscription filter.
   - Smoke test: `LIST @CV_PROD_RAW.LANDING.STG_ADLS_RAW/incremental/;`
3. Everything else: `snowflake/deploy/deploy.sh PROD --from 04_control/01_control_tables.sql`
   (CI does this on release — `.github/workflows/deploy.yml`).
4. Upload key-pair public keys: `ALTER USER SVC_PROD_ADF_LOADER SET RSA_PUBLIC_KEY='…';`

## 3. ADF setup

1. Deploy `metadata/adf_control_db.sql` to Azure SQL; load `metadata/source_object_seed.csv`
   into `ctl.source_object`; initialise `ctl.watermark` per object (backfill end point — see §4.5).
2. Deploy factory via CI (ARM export + pre/post trigger script) with `adf/params/<ENV>.json`.
3. Test connections for each linked service (SHIR online, Key Vault secrets resolve).

## 4. Historical backfill (one-time, per wave)

1. Generate partitions: `python -m src.tools.backfill_plan --object-id 2 --from 2014-01 --to 2025-12 --estimates counts.csv`
   and bulk insert into `ctl.backfill_partition`.
2. Scale out SHIR to 4 nodes; confirm ExpressRoute burst; `ALTER WAREHOUSE PROD_WH_BACKFILL SET WAREHOUSE_SIZE='XLARGE';`
3. Trigger `PL_20_Historical_Backfill` per yearly wave (`wave_from_month=2014-01-01`, `wave_to_month=2014-12-01`).
   - Re-run the same wave after any failure — only `PENDING/FAILED` partitions copy again.
   - First wave per table: run `CALL SP_BACKFILL_COPY(..., P_DRY_RUN => TRUE)` to validate files.
4. After all waves: validate `FACT_CLAIM_LINE_BF` with recon L1–L3 by month, then
   run [`11_clone_timetravel/03_backfill_swap.sql`](snowflake/11_clone_timetravel/03_backfill_swap.sql).
5. **Hand-over to incremental:** set `ctl.watermark.last_watermark` = the max rowversion/timestamp
   captured at backfill extract time (recorded in `ctl.backfill_partition` run log) so no
   window is skipped; overlap is harmless (dedupe on version key + rowversion).
6. Scale `WH_BACKFILL` to XSMALL, SHIR back to 2 nodes, disable RM_BACKFILL.

## 5. Daily operations

| Time (ET) | What happens | Check |
|---|---|---|
| 01:30 | `TR_Daily_0130_ET` → `PL_00_Master_Orchestrator` | ADF monitor / Log Analytics workbook |
| 01:30–04:30 | Parallel extracts → ADLS → Snowpipe | `V_PIPE_LOADS_24H`, `SYSTEM$PIPE_STATUS` |
| hourly :05 | Task DAG `T_ROOT_CV_HOURLY` | `V_TASK_FAILURES_7D` |
| ~05:00 | Publish gate PASSED → PMPM DT resumes | `CTL_PUBLISH_STATUS`, `V_DAILY_SLA` |
| after gate | `PL_40_Reconciliation` | `CONTROL.RECON.V_RECON_SCORECARD` |
| 05:45 | `ALR_PUBLISH_BLOCKED` fires if gate not passed | on-call |

## 6. Parallel run & cutover

- Daily: `PL_40` with `parallel_run_active=true` → `PL_41` extracts legacy metrics from Oracle.
- Break triage: [`docs/runbooks/recon_break_triage.md`](docs/runbooks/recon_break_triage.md).
- Exit criteria: `SELECT * FROM CV_PROD_CONTROL.RECON.V_CUTOVER_GREEN_DAYS;` ≥ 10 plus
  3 clean month-ends + sign-offs in `CONTROL.CUTOVER_CHECKLIST`.
- Weekend plan and rollback: [`docs/migration/CUTOVER_PLAN.md`](docs/migration/CUTOVER_PLAN.md).

## 7. Releases

1. PR → CI (lint, ADF validate, SQL lint, tests).
2. Merge → DEV deploy. Manual dispatch → QA (weekly refreshed clone of PROD, masked) → PROD with approval.
3. PROD deploy takes a pre-release schema clone automatically; rollback =
   [`docs/runbooks/release_rollback.md`](docs/runbooks/release_rollback.md).
4. Task DAG is suspended during deploy by `03_task_dag.sql` and re-enabled at its end.

## 8. Onboarding a new source table

1. Row in `ctl.source_object` (+ `target_path` `<system>/<object>`).
2. RAW table + pipe in `snowflake/03_raw/` (pipe prefix = `incremental/<target_path>/`), stream in `07_streams_tasks/01_streams.sql`.
3. STAGE/CORE logic + task, DQ rules, recon rules; add files to `manifest.txt`.
4. `make validate` must pass (it fails if the pipe prefix and metadata disagree).
