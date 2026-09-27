/* =============================================================================
   02_sp_publish_gate.sql — "don't publish wrong numbers"
   Replaces the PowerCenter workflow Decision task + Event-Wait on files.
   PASSED only if, for the business date:
     - every CRITICAL feed is LOADED (not EXPECTED/FAILED/LATE)
     - no CRITICAL DQ failures in today's batches
     - no nothing-loaded surprise (row counts > 0 for claims + eligibility)
   Marts are Dynamic Tables with TARGET_LAG; when BLOCKED we SUSPEND the finance
   leaf DTs so stale-but-correct numbers stay visible instead of wrong ones.
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;

CREATE OR REPLACE PROCEDURE CV_&{ENV}_CONTROL.ORCHESTRATION.SP_PUBLISH_GATE(P_BUSINESS_DATE DATE)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_reasons ARRAY;
  v_status  VARCHAR;
BEGIN
  -- mark feeds LOADED where RAW actually received rows for this business date's ADF run
  UPDATE CV_&{ENV}_CONTROL.CONTROL.CTL_FEED_STATUS fs
     SET STATUS = 'LOADED', UPDATED_AT = CURRENT_TIMESTAMP()
   WHERE fs.BUSINESS_DATE = :P_BUSINESS_DATE AND fs.STATUS = 'EXTRACTED'
     AND EXISTS (SELECT 1 FROM CV_&{ENV}_CONTROL.CONTROL.CTL_FILE_LOAD_LOG fl
                 JOIN CV_&{ENV}_CONTROL.CONTROL.CTL_FEED f ON f.RAW_TABLE = fl.TARGET_TABLE
                 WHERE f.FEED_CODE = fs.FEED_CODE AND fl.BATCH_ID = fs.ADF_RUN_ID AND fl.STATUS = 'LOADED');

  SELECT ARRAY_AGG(REASON) INTO :v_reasons FROM (
      SELECT 'FEED_NOT_LOADED:' || f.FEED_CODE || ':' || COALESCE(fs.STATUS, 'MISSING') AS REASON
      FROM CV_&{ENV}_CONTROL.CONTROL.CTL_FEED f
      LEFT JOIN CV_&{ENV}_CONTROL.CONTROL.CTL_FEED_STATUS fs
        ON fs.FEED_CODE = f.FEED_CODE AND fs.BUSINESS_DATE = :P_BUSINESS_DATE
      WHERE f.IS_ACTIVE AND f.CRITICALITY = 'CRITICAL' AND COALESCE(fs.STATUS, 'MISSING') <> 'LOADED'
      UNION ALL
      SELECT 'DQ_CRITICAL:' || r.RULE_ID
      FROM CV_&{ENV}_CONTROL.DQ.DQ_RESULT r
      JOIN CV_&{ENV}_CONTROL.DQ.DQ_RULE d ON d.RULE_ID = r.RULE_ID
      WHERE r.BUSINESS_DATE = :P_BUSINESS_DATE AND r.STATUS = 'FAIL' AND d.SEVERITY = 'CRITICAL'
      UNION ALL
      SELECT 'ZERO_ROWS:' || FEED_CODE
      FROM CV_&{ENV}_CONTROL.CONTROL.CTL_FEED_STATUS
      WHERE BUSINESS_DATE = :P_BUSINESS_DATE AND FEED_CODE IN ('CLAIMS_CLAIM_LINE','MEMBERSHIP_ELIG')
        AND COALESCE(ROWS_EXTRACTED, 0) = 0
  );

  v_status := IFF(ARRAY_SIZE(COALESCE(v_reasons, ARRAY_CONSTRUCT())) = 0, 'PASSED', 'BLOCKED');

  MERGE INTO CV_&{ENV}_CONTROL.CONTROL.CTL_PUBLISH_STATUS t
  USING (SELECT :P_BUSINESS_DATE AS BUSINESS_DATE) s ON t.BUSINESS_DATE = s.BUSINESS_DATE
  WHEN MATCHED THEN UPDATE SET GATE_STATUS = :v_status, BLOCK_REASONS = :v_reasons, EVALUATED_AT = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (BUSINESS_DATE, GATE_STATUS, BLOCK_REASONS) VALUES (s.BUSINESS_DATE, :v_status, :v_reasons);

  IF (v_status = 'BLOCKED') THEN
    ALTER DYNAMIC TABLE CV_&{ENV}_MART.FINANCE.DT_PMPM_BY_LOB_MONTH SUSPEND;
  ELSE
    ALTER DYNAMIC TABLE CV_&{ENV}_MART.FINANCE.DT_PMPM_BY_LOB_MONTH RESUME;
  END IF;

  RETURN OBJECT_CONSTRUCT('business_date', P_BUSINESS_DATE, 'gate', v_status, 'reasons', v_reasons);
END;
$$;
