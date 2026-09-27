# Runbook — task DAG failure

1. `SELECT * FROM CV_PROD_CONTROL.MONITORING.V_TASK_FAILURES_7D ORDER BY SCHEDULED_TIME DESC;`
2. Find the failing proc's message in `AUDIT_BATCH_LOG` (`STATUS='FAILED'`, same `BATCH_ID` = graph run id).
3. Because each proc consumes its stream inside a transaction and ROLLBACKs on error, **no data was consumed**.
   Fix and either wait for the next hourly run or `EXECUTE TASK CV_PROD_CONTROL.ORCHESTRATION.T_ROOT_CV_HOURLY;`
4. If the DAG auto-suspended (3 failures): `SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('CV_PROD_CONTROL.ORCHESTRATION.T_ROOT_CV_HOURLY');`

## Stale stream
1. `SHOW STREAMS IN SCHEMA CV_PROD_RAW.CLAIMS;` → `stale = true`.
2. Note the last successful `_LOAD_TS` processed (`MAX(_STAGED_AT)` in STAGE / audit log).
3. `CREATE OR REPLACE STREAM … ON TABLE … APPEND_ONLY = TRUE;` (starts empty, from now).
4. Replay the gap: `INSERT INTO STAGE…` via the stage proc logic reading `RAW` `WHERE _LOAD_TS > :last` (proc variant `SP_STAGE_CLAIM_LINE_REPLAY`).
5. Recon L1 for affected dates.
