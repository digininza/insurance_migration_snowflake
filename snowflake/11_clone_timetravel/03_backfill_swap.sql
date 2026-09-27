/* =============================================================================
   03_backfill_swap.sql — promote the history built in FACT_CLAIM_LINE_BF
   Preconditions (RUNBOOK §5): recon L1–L3 green on _BF for all backfilled months.
   ============================================================================= */
USE ROLE PROD_SR_CICD;

ALTER TASK CV_PROD_CONTROL.ORCHESTRATION.T_ROOT_CV_HOURLY SUSPEND;       -- no MERGE mid-swap

-- incremental rows that landed in the live table during the backfill weeks → copy into _BF first
INSERT INTO CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE_BF
SELECT * FROM CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE live
WHERE NOT EXISTS (SELECT 1 FROM CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE_BF bf
                  WHERE bf.CLAIM_ID = live.CLAIM_ID AND bf.LINE_NO = live.LINE_NO
                    AND bf.CLAIM_LINE_VERSION = live.CLAIM_LINE_VERSION);

ALTER TABLE CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE SWAP WITH CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE_BF;   -- atomic
ALTER TABLE CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE RESUME RECLUSTER;

-- Policies/tags: re-attach if the _BF clone predates policy attachment (check POLICY_REFERENCES)
-- Dynamic tables downstream: full refresh once after the swap
ALTER DYNAMIC TABLE CV_PROD_MART.CLAIMS.DT_CLAIMS_COST_MONTHLY REFRESH;
ALTER DYNAMIC TABLE CV_PROD_MART.CLAIMS.DT_CLAIMS_LAG_TRIANGLE REFRESH;

SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('CV_PROD_CONTROL.ORCHESTRATION.T_ROOT_CV_HOURLY');
-- Keep the swapped-out table (now named _BF) for 7 days as rollback, then DROP.
