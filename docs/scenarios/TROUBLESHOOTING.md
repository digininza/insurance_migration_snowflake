# Production troubleshooting — 20 scenarios

Format: **Symptom → Diagnose → Fix → Prevent.**

### 1. Files in ADLS but nothing loaded in RAW
- **Diagnose:** `SELECT SYSTEM$PIPE_STATUS('CV_PROD_RAW.LANDING.PIPE_CLAIM_LINE');` → `pendingFileCount`, `lastIngestedTimestamp`, `notificationChannelName`. Check the storage queue has messages; check the Event Grid subscription filter (prefix/suffix) and the Snowflake SP role on the queue.
- **Fix:** `ALTER PIPE … REFRESH PREFIX='load_date=2026-09-26/';` (files staged < 7 days). Older → `COPY INTO` via replay.
- **Prevent:** `ALR_PIPE_STALLED`; `adf_validate` pipe-prefix check.

### 2. Snowpipe skipped a file (`ON_ERROR=SKIP_FILE`)
- **Diagnose:** `COPY_HISTORY` → `STATUS='Load failed'`, `FIRST_ERROR`. Typical: Parquet schema drift with incompatible type.
- **Fix:** correct the source/ADF mapping; re-land to a new `run_id=` folder (Snowpipe dedupes by path+ETag, so a *new* file loads).
- **Prevent:** `ALR_COPY_ERRORS`; `typeConversionSettings.allowDataTruncation=false` in ADF.

### 3. Duplicate rows after an ADF retry
- **Cause:** Copy partially wrote files then retried into the same run folder, or watermark not advanced after failure → window re-read.
- **Why it's safe:** STAGE dedupes (`QUALIFY ROW_NUMBER()` on version key + rowversion); CORE MERGE on version key.
- **Verify:** DQ-CLM-002 = 0; recon L1 unchanged.

### 4. Watermark gap — rows missing in Snowflake
- **Diagnose:** compare source `COUNT(*)` for the window with `CTL_ADF_RUN_LOG.rows_written`. Look for Oracle rows committed with an older `LAST_UPDATE_TS` than the watermark (long transactions).
- **Fix:** move watermark back (`ctl.watermark_hist`) and re-run PL_11 for the object.
- **Prevent:** rowversion watermarks on SQL Server; 15-min look-back overlap on Oracle; recon L1.

### 5. Task DAG suspended itself
- **Diagnose:** `V_TASK_FAILURES_7D`; `SUSPEND_TASK_AFTER_NUM_FAILURES=3` reached.
- **Fix:** fix root cause; `SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('…T_ROOT_CV_HOURLY');` Streams still hold the unconsumed changes (transactional consumption) → nothing lost.

### 6. Stream went stale
- **Diagnose:** `SHOW STREAMS` → `stale = true` (DAG down longer than retention + `MAX_DATA_EXTENSION_TIME_IN_DAYS`).
- **Fix:** `CREATE OR REPLACE STREAM …`; replay from RAW by `_LOAD_TS` window into STAGE (runbook `task_failure.md` §stale).
- **Prevent:** 14-day extension; alert on `STALE_AFTER` < 2 days.

### 7. Publish gate BLOCKED at 05:45
- **Diagnose:** `SELECT BLOCK_REASONS FROM CTL_PUBLISH_STATUS WHERE BUSINESS_DATE = …`. `FEED_NOT_LOADED:MEMBERSHIP_ELIG:FAILED` → ADF object failure; `DQ_CRITICAL:ELG-R-004` → overlapping spans.
- **Fix:** resolve feed; gate re-evaluates next hourly DAG run; PMPM DT resumes automatically.
- **Comms:** Finance told "yesterday's PMPM is still showing" — correct but stale beats wrong.

### 8. Orphan claim lines piling up in quarantine
- **Cause:** header file late or header extract failed.
- **Fix:** header lands → `T_REPLAY_ORPHANS` re-drives lines automatically. If header never arrives: raise with claims system team.

### 9. Many claims mapped to inferred members
- **Diagnose:** `SELECT COUNT(*) FROM DIM_MEMBER WHERE IS_INFERRED AND IS_CURRENT`. Spike = eligibility feed late.
- **Fix:** none needed once membership lands (inferred rows upgraded in place, SK preserved). Escalate if > 24 h.

### 10. Daily claim MERGE suddenly slow (7 min → 45 min)
- **Diagnose:** Query Profile: partitions scanned ≈ total → the batch contained a very old service month (e.g. 2014 adjustment) widening `SERVICE_MONTH BETWEEN min AND max`. Also check spilling.
- **Fix:** split MERGE by month buckets when range > 24 months (proc option); or scale WH_TRANSFORM to L for the run.
- **Prevent:** `V_POOR_PRUNING_FACT_CLAIM`; clustering depth monitor.

### 11. Warehouse spilling to remote storage
- **Fix:** scale up one size (memory), not out. Check for exploding joins (lookup duplicates — the Informatica "first value" issue).

### 12. BI dashboards queueing at 09:00
- **Diagnose:** `WAREHOUSE_LOAD_HISTORY.AVG_QUEUED_LOAD` on WH_BI.
- **Fix:** max clusters 4 → 6 temporarily; ensure dashboards hit DTs not CORE; QAS already on.

### 13. Dynamic Table refresh fell back to FULL / cost spike
- **Diagnose:** `SHOW DYNAMIC TABLES` → `refresh_mode`, `refresh_mode_reason`; `DYNAMIC_TABLE_REFRESH_HISTORY`.
- **Fix:** remove non-deterministic functions; declare `REFRESH_MODE=INCREMENTAL` so deploy fails loudly.

### 14. Recon RED: 1-cent VALUE_MISMATCH on L2
- **Cause (seen in parallel run):** legacy EXP port truncated 3-decimal amounts; new platform rounds.
- **Action:** disposition `LEGACY_DEFECT`, finance sign-off; or reproduce legacy truncation under a `LEGACY_PARITY` flag until cutover.

### 15. Recon RED: MISSING_IN_LEGACY rows
- **Cause:** legacy Router default group dropped `'PAID '` (trailing space) lines; new platform trims.
- **Action:** confirm with business which is correct (new is); `LEGACY_DEFECT` + report owners informed of the number change.

### 16. TYPE_MISMATCH on L4
- **Cause:** compat view column `NUMBER(38,0)` vs legacy `NUMBER(15,2)` (an unrounded SUM) or a source query that cast `DECIMAL` → `FLOAT` in ADF.
- **Fix:** explicit cast in view / fix ADF mapping. `sql_manifest.py` blocks FLOAT in DDL.

### 17. Storage integration "access denied" after Azure change
- **Diagnose:** `LIST @STG_ADLS_RAW;` error; someone removed the RBAC assignment or enabled a firewall rule without the Snowflake resource instance rule.
- **Fix:** re-grant *Storage Blob Data Reader* to the Snowflake SP; re-add resource instance rule/private endpoint.

### 18. ADF can't connect to Snowflake after key rotation
- **Cause:** new private key in Key Vault but `RSA_PUBLIC_KEY` not updated (or old key unset too early).
- **Fix/Prevent:** rotation runbook uses `RSA_PUBLIC_KEY_2` overlap: set key 2 → update KV → verify → unset key 1.

### 19. Someone ran a bad UPDATE on CORE
- **Fix:** Time Travel: `CREATE TABLE … CLONE … BEFORE(STATEMENT=>'<qid>')` then `SWAP WITH`; replay later batches from STAGE. See `time_travel_recovery.md`.
- **Prevent:** only `SR_TRANSFORM`/`SR_CICD` have DML on CORE; humans read-only.

### 20. Open enrollment: membership volume 8×
- **Symptoms:** eligibility copy exceeds window; `SP_MERGE_FACT_ELIGIBILITY_MONTH` slow (recomputes all months per touched member).
- **Fix:** raise `max_parallel_copies` for MEMBERSHIP via metadata; temporarily size WH_TRANSFORM to L; members-touched-driven recompute keeps work proportional to changes.
