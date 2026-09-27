/* =============================================================================
   05_time_travel_recovery.sql — recovery recipes (runbook: time_travel_recovery.md)
   ============================================================================= */
-- What changed in the last hour?
SELECT COUNT(*) FROM CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE AT (OFFSET => -3600);

-- Rows the bad MERGE touched (by batch id from AUDIT_BATCH_LOG)
SELECT * FROM CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE WHERE _BATCH_ID = '<bad_batch_id>';

-- Restore table to the state just before a specific statement
CREATE OR REPLACE TABLE CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE_RESTORE
  CLONE CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE BEFORE (STATEMENT => '<query_id_of_bad_merge>');
ALTER TABLE CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE SWAP WITH CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE_RESTORE;

-- Accidentally dropped
UNDROP TABLE CV_PROD_CORE.MEMBER.DIM_MEMBER;
UNDROP SCHEMA CV_PROD_MART.FINANCE;

-- After restore: re-run the corrected logic for the affected window by replaying STAGE
-- (STAGE is kept 3 days) or RAW by _LOAD_TS window (runbook step 4).
