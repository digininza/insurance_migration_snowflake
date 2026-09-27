/* =============================================================================
   03_sp_run_recon.sql — generic reconciliation engine
   For each active rule: run NEW_SQL for the business date → FULL OUTER JOIN
   with LEGACY_METRIC on GRAIN_KEY → classify → RECON_RESULT.
   L4 (types) compares LEGACY_SCHEMA with the LEGACY_COMPAT views' columns.
   Returns summary; ADF PL_40 fails the pipeline when critical_breaks > 0.
   Runs on WH_RECON (isolated from ELT) — caller's USE WAREHOUSE applies.
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;

CREATE OR REPLACE PROCEDURE CV_&{ENV}_CONTROL.RECON.SP_RUN_RECON(P_BUSINESS_DATE DATE)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_run_id   VARCHAR DEFAULT UUID_STRING();
  v_rules    NUMBER DEFAULT 0;
  v_breaks   NUMBER DEFAULT 0;
  v_critical NUMBER DEFAULT 0;
BEGIN
  CREATE OR REPLACE TEMPORARY TABLE TMP_NEW_METRIC (GRAIN_KEY VARCHAR, METRIC_VALUE VARCHAR);

  LET rs_rules RESULTSET := (SELECT RULE_ID, RECON_LEVEL, TABLE_NAME, METRIC_NAME, NEW_SQL, TOLERANCE, CRITICALITY
                             FROM CV_&{ENV}_CONTROL.RECON.RECON_RULE
                             WHERE IS_ACTIVE AND RECON_LEVEL <> 'L4' ORDER BY RULE_ID);
  LET c_rules CURSOR FOR rs_rules;
  FOR r IN c_rules DO
    LET v_rule_id VARCHAR := r.RULE_ID;
    LET v_level   VARCHAR := r.RECON_LEVEL;
    LET v_table   VARCHAR := r.TABLE_NAME;
    LET v_metric  VARCHAR := r.METRIC_NAME;
    LET v_tol     NUMBER(18,4) := r.TOLERANCE;
    LET v_crit    VARCHAR := r.CRITICALITY;
    LET v_sql     VARCHAR := REPLACE(r.NEW_SQL, ':BD', '''' || TO_VARCHAR(:P_BUSINESS_DATE) || '''::DATE');

    TRUNCATE TABLE TMP_NEW_METRIC;
    EXECUTE IMMEDIATE 'INSERT INTO TMP_NEW_METRIC ' || :v_sql;

    INSERT INTO CV_&{ENV}_CONTROL.RECON.RECON_RESULT
          (RUN_ID, BUSINESS_DATE, RULE_ID, RECON_LEVEL, GRAIN_KEY, LEGACY_VALUE, NEW_VALUE, DIFF, STATUS, CRITICALITY)
    SELECT :v_run_id, :P_BUSINESS_DATE, :v_rule_id, :v_level,
           COALESCE(n.GRAIN_KEY, l.GRAIN_KEY), l.METRIC_VALUE, n.METRIC_VALUE,
           TRY_TO_NUMBER(n.METRIC_VALUE, 38, 4) - TRY_TO_NUMBER(l.METRIC_VALUE, 38, 4),
           CASE
             WHEN l.GRAIN_KEY IS NULL THEN 'MISSING_IN_LEGACY'
             WHEN n.GRAIN_KEY IS NULL THEN 'MISSING_IN_NEW'
             WHEN :v_tol IS NULL AND n.METRIC_VALUE = l.METRIC_VALUE THEN 'MATCH'
             WHEN :v_tol IS NOT NULL
                  AND ABS(TRY_TO_NUMBER(n.METRIC_VALUE, 38, 4) - TRY_TO_NUMBER(l.METRIC_VALUE, 38, 4)) <= :v_tol THEN 'MATCH'
             ELSE 'VALUE_MISMATCH'
           END,
           :v_crit
    FROM TMP_NEW_METRIC n
    FULL OUTER JOIN (SELECT GRAIN_KEY, METRIC_VALUE FROM CV_&{ENV}_CONTROL.RECON.LEGACY_METRIC
                     WHERE BUSINESS_DATE = :P_BUSINESS_DATE AND TABLE_NAME = :v_table AND METRIC_NAME = :v_metric) l
      ON l.GRAIN_KEY = n.GRAIN_KEY;
    v_rules := v_rules + 1;
  END FOR;

  -- L4: data type / precision parity, legacy EDW column vs LEGACY_COMPAT view column
  INSERT INTO CV_&{ENV}_CONTROL.RECON.RECON_RESULT
        (RUN_ID, BUSINESS_DATE, RULE_ID, RECON_LEVEL, GRAIN_KEY, LEGACY_VALUE, NEW_VALUE, STATUS, CRITICALITY)
  SELECT :v_run_id, :P_BUSINESS_DATE, 'RC-L4-ALL', 'L4',
         COALESCE(l.TABLE_NAME, REPLACE(c.TABLE_NAME,'EDW_','')) || '.' || COALESCE(l.COLUMN_NAME, c.COLUMN_NAME),
         l.DATA_TYPE || '(' || COALESCE(l.DATA_PRECISION::VARCHAR,'') || ',' || COALESCE(l.DATA_SCALE::VARCHAR,'') || ')',
         c.DATA_TYPE || '(' || COALESCE(c.NUMERIC_PRECISION::VARCHAR, c.CHARACTER_MAXIMUM_LENGTH::VARCHAR, '') || ','
                     || COALESCE(c.NUMERIC_SCALE::VARCHAR,'') || ')',
         CASE WHEN c.COLUMN_NAME IS NULL THEN 'MISSING_IN_NEW'
              WHEN l.COLUMN_NAME IS NULL THEN 'MISSING_IN_LEGACY'
              -- numbers: new precision/scale must be >= legacy (widening OK, narrowing = break)
              WHEN l.DATA_TYPE = 'NUMBER' AND (c.DATA_TYPE <> 'NUMBER' OR c.NUMERIC_SCALE < l.DATA_SCALE
                                               OR c.NUMERIC_PRECISION < l.DATA_PRECISION) THEN 'TYPE_MISMATCH'
              WHEN l.DATA_TYPE IN ('VARCHAR2','CHAR') AND c.DATA_TYPE <> 'TEXT' THEN 'TYPE_MISMATCH'
              WHEN l.DATA_TYPE = 'DATE' AND c.DATA_TYPE NOT IN ('DATE','TIMESTAMP_NTZ') THEN 'TYPE_MISMATCH'
              ELSE 'MATCH' END,
         'CRITICAL'
  FROM CV_&{ENV}_CONTROL.RECON.LEGACY_SCHEMA l
  FULL OUTER JOIN (SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, NUMERIC_PRECISION, NUMERIC_SCALE, CHARACTER_MAXIMUM_LENGTH
                   FROM CV_&{ENV}_MART.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'LEGACY_COMPAT') c
    ON 'EDW_' || l.TABLE_NAME = c.TABLE_NAME AND l.COLUMN_NAME = c.COLUMN_NAME;

  SELECT COUNT_IF(STATUS <> 'MATCH'), COUNT_IF(STATUS <> 'MATCH' AND CRITICALITY = 'CRITICAL')
    INTO :v_breaks, :v_critical
    FROM CV_&{ENV}_CONTROL.RECON.RECON_RESULT WHERE RUN_ID = :v_run_id;

  RETURN OBJECT_CONSTRUCT('run_id', v_run_id, 'business_date', P_BUSINESS_DATE, 'rules', v_rules,
                          'breaks', v_breaks, 'critical_breaks', v_critical,
                          'status', IFF(v_critical = 0, 'GREEN', 'RED'));
END;
$$;
