# Runbook — Snowpipe not loading

```sql
SELECT SYSTEM$PIPE_STATUS('CV_PROD_RAW.LANDING.PIPE_CLAIM_LINE');
SELECT * FROM TABLE(CV_PROD_RAW.INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME=>'CV_PROD_RAW.CLAIMS.CLAIM_LINE', START_TIME=>DATEADD(hour,-6,CURRENT_TIMESTAMP())));
SELECT * FROM TABLE(VALIDATE_PIPE_LOAD(PIPE_NAME=>'CV_PROD_RAW.LANDING.PIPE_CLAIM_LINE',
  START_TIME=>DATEADD(hour,-6,CURRENT_TIMESTAMP())));
```

| Finding | Action |
|---|---|
| `executionState = PAUSED` | `ALTER PIPE … SET PIPE_EXECUTION_PAUSED = FALSE;` |
| `pendingFileCount` 0 and no history | Event path broken: storage queue empty? Event Grid subscription filter? SP lost *Storage Queue Data Contributor*? |
| Files in COPY_HISTORY as `Load failed` | Read `FIRST_ERROR`; fix; re-land as a new file |
| Files older than 7 days never loaded | `REFRESH` can't reach them → `COPY INTO … FROM @STG_ADLS_RAW/incremental/… PATTERN=…` (COPY load metadata prevents duplicates of files already loaded within 64 days) |

Replay a day: `ALTER PIPE CV_PROD_RAW.LANDING.PIPE_CLAIM_LINE REFRESH PREFIX = 'load_date=2026-09-26/';`
