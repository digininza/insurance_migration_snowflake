/* =============================================================================
   02_logging_procs.sql — uniform audit logging + ADF run-log sink + feed status
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;

CREATE OR REPLACE PROCEDURE CV_&{ENV}_CONTROL.AUDIT.SP_LOG_BATCH(
    P_BATCH_ID VARCHAR, P_STEP VARCHAR, P_TARGET VARCHAR, P_STATUS VARCHAR,
    P_ROWS_INSERTED NUMBER, P_ROWS_UPDATED NUMBER, P_ROWS_REJECTED NUMBER, P_ERROR VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  INSERT INTO CV_&{ENV}_CONTROL.AUDIT.AUDIT_BATCH_LOG
        (BATCH_ID, STEP_NAME, TARGET_OBJECT, STATUS, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED, ERROR_MESSAGE, TASK_NAME)
  VALUES (:P_BATCH_ID, :P_STEP, :P_TARGET, :P_STATUS, :P_ROWS_INSERTED, :P_ROWS_UPDATED, :P_ROWS_REJECTED,
          LEFT(:P_ERROR, 4000), SYSTEM$CURRENT_USER_TASK_NAME());
  RETURN 'logged';
END;
$$;

-- Called by ADF (Script activity) at the end of PL_11 for each object.
CREATE OR REPLACE PROCEDURE CV_&{ENV}_CONTROL.CONTROL.SP_ADF_LOG_RUN(P_RUN VARIANT)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  INSERT INTO CV_&{ENV}_CONTROL.CONTROL.CTL_ADF_RUN_LOG
  SELECT :P_RUN:adf_run_id::VARCHAR, :P_RUN:pipeline_name::VARCHAR, :P_RUN:object_id::NUMBER,
         :P_RUN:source_object::VARCHAR, :P_RUN:business_date::DATE,
         :P_RUN:old_watermark::VARCHAR, :P_RUN:new_watermark::VARCHAR,
         :P_RUN:rows_read::NUMBER, :P_RUN:rows_written::NUMBER, :P_RUN:files_written::NUMBER,
         :P_RUN:bytes_written::NUMBER, :P_RUN:status::VARCHAR, :P_RUN:error_message::VARCHAR,
         :P_RUN:start_ts::TIMESTAMP_NTZ, :P_RUN:end_ts::TIMESTAMP_NTZ;

  MERGE INTO CV_&{ENV}_CONTROL.CONTROL.CTL_FEED_STATUS t
  USING (SELECT :P_RUN:business_date::DATE AS BUSINESS_DATE, :P_RUN:feed_code::VARCHAR AS FEED_CODE,
                IFF(:P_RUN:status::VARCHAR = 'SUCCEEDED', 'EXTRACTED', 'FAILED') AS STATUS,
                :P_RUN:adf_run_id::VARCHAR AS ADF_RUN_ID, :P_RUN:rows_written::NUMBER AS ROWS_EXTRACTED) s
  ON t.BUSINESS_DATE = s.BUSINESS_DATE AND t.FEED_CODE = s.FEED_CODE
  WHEN MATCHED THEN UPDATE SET STATUS = s.STATUS, ADF_RUN_ID = s.ADF_RUN_ID,
                               ROWS_EXTRACTED = COALESCE(t.ROWS_EXTRACTED,0) + s.ROWS_EXTRACTED,
                               UPDATED_AT = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (BUSINESS_DATE, FEED_CODE, STATUS, ADF_RUN_ID, ROWS_EXTRACTED)
                        VALUES (s.BUSINESS_DATE, s.FEED_CODE, s.STATUS, s.ADF_RUN_ID, s.ROWS_EXTRACTED);
  RETURN 'ok';
END;
$$;

-- Generic DQ runner: executes every active rule for a target table, records results,
-- returns number of CRITICAL failures (callers decide to stop or continue).
CREATE OR REPLACE PROCEDURE CV_&{ENV}_CONTROL.DQ.SP_RUN_DQ(P_TARGET_TABLE VARCHAR, P_BATCH_ID VARCHAR, P_BUSINESS_DATE DATE)
RETURNS NUMBER
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_critical_failures NUMBER DEFAULT 0;
  v_cnt NUMBER;
BEGIN
  LET rs_rules RESULTSET := (SELECT RULE_ID, RULE_SQL, SEVERITY FROM CV_&{ENV}_CONTROL.DQ.DQ_RULE
                             WHERE TARGET_TABLE = :P_TARGET_TABLE AND IS_ACTIVE ORDER BY RULE_ID);
  LET c_rules CURSOR FOR rs_rules;
  FOR r IN c_rules DO
    LET v_rule_id  VARCHAR := r.RULE_ID;
    LET v_rule_sql VARCHAR := r.RULE_SQL;
    LET v_severity VARCHAR := r.SEVERITY;
    LET rs RESULTSET := (EXECUTE IMMEDIATE :v_rule_sql);
    LET c1 CURSOR FOR rs;
    OPEN c1; FETCH c1 INTO v_cnt; CLOSE c1;
    INSERT INTO CV_&{ENV}_CONTROL.DQ.DQ_RESULT (BATCH_ID, RULE_ID, BUSINESS_DATE, VIOLATIONS, STATUS)
      VALUES (:P_BATCH_ID, :v_rule_id, :P_BUSINESS_DATE, :v_cnt, IFF(:v_cnt = 0, 'PASS', 'FAIL'));
    IF (v_cnt > 0 AND v_severity = 'CRITICAL') THEN
      v_critical_failures := v_critical_failures + 1;
    END IF;
  END FOR;
  RETURN v_critical_failures;
END;
$$;
