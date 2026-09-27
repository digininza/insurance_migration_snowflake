# Low-Level Design — Snowflake

All SQL is in [`/snowflake`](../../snowflake), numbered in deploy order and
listed in [`snowflake/deploy/manifest.txt`](../../snowflake/deploy/manifest.txt).
Scripts use `&{ENV}` SnowSQL variables (`DEV`/`QA`/`PROD`) and are idempotent
(`CREATE … IF NOT EXISTS` / `CREATE OR ALTER` / `CREATE OR REPLACE` for stateless objects).

## 1. Account & edition

- **Business Critical on Azure (East US 2)** — required for PHI under the Snowflake
  BAA; enables **Tri-Secret Secure** (customer-managed key in Azure Key Vault)
  and **Azure Private Link**. Replication to Central US for DR (ADR-015).
- One account per environment tier: `NONPROD` (DEV+QA databases) and `PROD` (ADR-003).

## 2. Object inventory

| Folder | Objects |
|---|---|
| `00_account` | Roles (access + functional + service), warehouses, resource monitors, network policy, service user (key-pair) |
| `01_integration` | **Storage integration** (Azure), **notification integration** (Azure Storage Queue / Event Grid), file formats, external stages |
| `02_databases` | `CV_<ENV>_RAW`, `_STAGE` (transient), `_CORE`, `_MART`, `_CONTROL` + schemas per source system/subject |
| `03_raw` | RAW tables (typed via `MATCH_BY_COLUMN_NAME` from Parquet + load metadata), **Snowpipes**, backfill COPY procs |
| `04_control` | `CTL_BATCH_RUN`, `CTL_FILE_LOAD_LOG`, `CTL_FEED_STATUS`, `CTL_DQ_RULE`/`CTL_DQ_RESULT`, `AUDIT_LOG`, logging proc |
| `05_staging` | Transient STAGE tables + `SP_STAGE_*` (type, trim, dedupe, DQ, quarantine) |
| `06_core` | Dims (SCD2) + facts DDL, `SP_MERGE_DIM_MEMBER` (SCD2), `SP_MERGE_FACT_CLAIM_LINE` (versioned) |
| `07_streams_tasks` | Streams on RAW/STAGE, Task DAG (root schedule + `AFTER` children + finalizer), `SP_PUBLISH_GATE` |
| `08_marts` | **Dynamic Tables** (member months, PMPM, lag triangle, provider scorecard), secure views, LEGACY_COMPAT views |
| `09_governance` | Tags, tag-based masking, row access policy by LOB, object tagging |
| `10_reconciliation` | Recon tables, legacy extract external table, `SP_RUN_RECON` |
| `11_clone_timetravel` | Clone recipes: QA refresh, pre-release snapshot, backfill-and-swap, parallel-run freeze, UNDROP |
| `12_monitoring` | Pipe/task/copy/credit monitoring views, **Snowflake Alerts**, email integration |

## 3. Ingestion objects (Azure)

```sql
CREATE STORAGE INTEGRATION SI_CV_ADLS
  TYPE = EXTERNAL_STAGE  STORAGE_PROVIDER = 'AZURE'  ENABLED = TRUE
  AZURE_TENANT_ID = '<tenant-guid>'
  STORAGE_ALLOWED_LOCATIONS = ('azure://stcvlakeprod.blob.core.windows.net/raw/');
-- DESC INTEGRATION → AZURE_CONSENT_URL (admin consents) + AZURE_MULTI_TENANT_APP_NAME
--   → grant that service principal "Storage Blob Data Reader" on container raw.

CREATE NOTIFICATION INTEGRATION NI_CV_ADLS_EVENTS
  ENABLED = TRUE  TYPE = QUEUE  NOTIFICATION_PROVIDER = AZURE_STORAGE_QUEUE
  AZURE_STORAGE_QUEUE_PRIMARY_URI = 'https://stcvlakeprod.queue.core.windows.net/snowpipe-raw'
  AZURE_TENANT_ID = '<tenant-guid>';
-- Event Grid subscription on the storage account: BlobCreated,
--   subject begins with /blobServices/default/containers/raw/blobs/incremental/
--   → Storage Queue snowpipe-raw.  Service principal gets "Storage Queue Data Contributor".
```

**Why a storage integration** (not SAS tokens on the stage): no secret to
rotate or leak; access is an Entra ID service principal scoped to allowed
locations; revocable centrally; stages can be created by `SR_INGEST` without
ever seeing credentials.

**Snowpipe:**
```sql
CREATE PIPE RAW.CLAIMS.PIPE_CLAIM_LINE
  AUTO_INGEST = TRUE  INTEGRATION = 'NI_CV_ADLS_EVENTS'
AS COPY INTO RAW.CLAIMS.CLAIM_LINE
   FROM @RAW.LANDING.STG_ADLS_RAW/incremental/claims/claim_line/
   FILE_FORMAT = (FORMAT_NAME = RAW.LANDING.FF_PARQUET)
   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
   INCLUDE_METADATA = (_FILE_NAME = METADATA$FILENAME, _FILE_ROW = METADATA$FILE_ROW_NUMBER,
                       _FILE_LAST_MODIFIED = METADATA$FILE_LAST_MODIFIED, _LOAD_TS = METADATA$START_SCAN_TIME);
```
One pipe per RAW table; each pipe's path prefix is unique so one event never
routes to two pipes. Snowpipe keeps **14 days** of file load history (dedupe);
bulk `COPY` keeps **64 days**. Replays use `ALTER PIPE … REFRESH PREFIX=` (≤ 7 days)
or `COPY INTO … FORCE=FALSE` from the replay procedure.

## 4. Stream → Task DAG

```
T_ROOT_CV_HOURLY  (SCHEDULE='USING CRON 5 * * * * UTC', WAREHOUSE=WH_TRANSFORM, ALLOW_OVERLAPPING_EXECUTION=FALSE)
 ├─ T_STAGE_CLAIM_HEADER  WHEN SYSTEM$STREAM_HAS_DATA(RAW.CLAIMS.STRM_CLAIM_HEADER_STAGE) → SP_MERGE_CLAIM_HEADER
 │    ├─ T_STAGE_CLAIM_LINE  WHEN stream has data → SP_STAGE_CLAIM_LINE  (valid → STAGE, invalid → QUARANTINE)
 │    └─ T_REPLAY_ORPHANS    → SP_REPLAY_ORPHAN_LINES (lines whose header arrived late)
 ├─ T_STAGE_MEMBER        → SP_STAGE_MEMBER
 │    └─ T_CORE_DIM_MEMBER (SCD2) → SP_MERGE_DIM_MEMBER
 ├─ T_STAGE_ELIGIBILITY   → SP_STAGE_ELIGIBILITY
 │    └─ T_CORE_FACT_ELIG_MONTH (AFTER stage elig + dim member)
 ├─ T_CORE_DIM_PROVIDER (SCD2) → SP_MERGE_DIM_PROVIDER
 ├─ T_CORE_FACT_CLAIM_LINE (AFTER stage line + dim member + dim provider) → SP_MERGE_FACT_CLAIM_LINE
 └─ T_DQ_AND_PUBLISH_GATE (AFTER facts) → SP_RUN_DQ + SP_PUBLISH_GATE → CTL_PUBLISH_STATUS, resume/suspend PMPM DT
 FINALIZE: T_FINALIZER_AUDIT  (always runs → TASK_HISTORY of this graph run into AUDIT_BATCH_LOG)
```

- Tasks run on **user-managed** `WH_TRANSFORM` (predictable MERGE workload,
  can scale to L at month-end). Small control tasks use **serverless** tasks
  (`USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE='XSMALL'`).
- `SUSPEND_TASK_AFTER_NUM_FAILURES = 3`, `TASK_AUTO_RETRY_ATTEMPTS = 2`.
- Streams are **append-only** on RAW (insert-only tables; cheaper). Stream
  staleness is guarded by `MAX_DATA_EXTENSION_TIME_IN_DAYS = 14` + an alert on
  `STALE_AFTER`.
- **Each stored proc consumes the stream inside an explicit transaction**, so
  the stream offset advances only if the MERGE commits.

## 5. Stored procedures (Snowflake Scripting)

| Procedure | Pattern | Replaces (Informatica) |
|---|---|---|
| `SP_STAGE_CLAIM_LINE` | `INSERT … SELECT` with `QUALIFY ROW_NUMBER()` dedupe, `TRY_TO_*` typing, DQ flags, quarantine insert | Source Qualifier + Expression + Filter + Router(error) |
| `SP_MERGE_DIM_MEMBER` | SCD2: close changed rows via `MERGE` on hash diff, insert new versions | SCD Type 2 wizard mapping + Lookup + Update Strategy |
| `SP_MERGE_FACT_CLAIM_LINE` | Versioned fact: surrogate-key lookups with inferred-member fallback, `MERGE` on (claim_id, line_no, version) | Lookup (connected/unconnected) + Update Strategy DD_INSERT/DD_UPDATE |
| `SP_PUBLISH_GATE` | Check critical feed status + DQ criticals + recon for business date | Workflow decision task + event-wait |
| `SP_RUN_RECON` | Legacy vs new count/amount/hash/type/rule/KPI comparison | (new — no legacy equivalent) |
| `SP_LOG_BATCH` | Uniform audit logging | Session log / repository tables |
| `SP_BACKFILL_COPY` | Bulk `COPY INTO` for a path pattern, logs `COPY_HISTORY` | Bulk mode sessions |

Every proc: `EXECUTE AS OWNER`, parameterised business date/batch id, writes
`CTL_BATCH_RUN`, `EXCEPTION WHEN OTHER THEN` → log + `RAISE` (so the task fails
visibly).

## 6. Dynamic Tables (marts)

| DT | Lag | Refresh mode | Why DT |
|---|---|---|---|
| `DT_MEMBER_MONTHS` | `DOWNSTREAM` | incremental | Derived from eligibility facts; only needed when downstream refreshes |
| `DT_PMPM_BY_LOB_MONTH` | `1 hour` | incremental | Joins member months + claims; exec dashboard freshness |
| `DT_CLAIMS_LAG_TRIANGLE` | `6 hours` | auto | Actuarial, not intraday |
| `DT_PROVIDER_SCORECARD` | `1 day` | auto (COUNT DISTINCT) | Network management weekly |
| `DT_DENIAL_RATE_DAILY` | `1 hour` | incremental | Operations |

Rules: DTs run on `WH_TRANSFORM`; we check `REFRESH_MODE` after creation
(`SHOW DYNAMIC TABLES`) because non-deterministic functions or some window
patterns silently force `FULL` refresh.

## 7. Performance features used

- **Clustering**: `FACT_CLAIM_LINE` clustered by `(service_month, lob_code)`
  (~2.4 B rows; filters always by date range + LOB). Other tables rely on natural
  load-order clustering. See [TB_SCALE_PERFORMANCE.md](TB_SCALE_PERFORMANCE.md).
- **Search Optimization** on `FACT_CLAIM_LINE(claim_id)` and `DIM_MEMBER(member_id)`
  — call-centre and SIU point lookups.
- **Query Acceleration Service** on `WH_BI` (scale factor 8) for outlier scans.
- **Result cache** for dashboards; **warehouse cache** preserved by
  `AUTO_SUSPEND=300` on BI only.
