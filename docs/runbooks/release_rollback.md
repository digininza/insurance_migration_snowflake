# Runbook — release rollback

1. Suspend DAG: `ALTER TASK CV_PROD_CONTROL.ORCHESTRATION.T_ROOT_CV_HOURLY SUSPEND;`
2. Swap schema back to the pre-release clone taken by CI:
   `ALTER SCHEMA CV_PROD_CORE.CLAIMS SWAP WITH CV_PROD_CORE.CLAIMS_PRE_<sha>;`
3. Redeploy previous git tag (procs/tasks/DTs) via `deploy.yml` dispatch.
4. Replay batches processed by the bad release: STAGE keeps 3 days — re-insert those `_BATCH_ID`s into the
   STAGE stream path (or re-run CORE procs against STAGE filtered by batch).
5. Re-enable DAG; run recon for affected business dates; refresh DTs.
