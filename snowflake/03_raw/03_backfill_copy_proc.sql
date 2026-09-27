/* =============================================================================
   03_backfill_copy_proc.sql — bulk COPY for historical backfill (ADR-007)
   Called by ADF PL_20_Historical_Backfill (Script activity) after a wave of
   partitions has landed under raw/backfill/<system>/<object>/.
   - EXECUTE AS CALLER so it can USE WAREHOUSE WH_BACKFILL (owner's-rights
     procedures cannot change session state); the ADF service user's role
     has USAGE on WH_BACKFILL and INSERT on RAW.
   - VALIDATION_MODE dry-run option for first wave of each table.
   - Logs every file's result from the COPY result set into CTL_FILE_LOAD_LOG.
   - Idempotent: COPY load metadata (64 days) skips already-loaded files.
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;

CREATE OR REPLACE PROCEDURE CV_&{ENV}_CONTROL.CONTROL.SP_BACKFILL_COPY(
    P_TARGET_TABLE VARCHAR,     -- e.g. 'CV_PROD_RAW.CLAIMS.CLAIM_LINE'
    P_STAGE_PATH   VARCHAR,     -- e.g. 'backfill/claims/claim_line/'
    P_PATTERN      VARCHAR,     -- e.g. '.*load_date=2014-0[1-6].*[.]parquet'
    P_BATCH_ID     VARCHAR,     -- ADF run id
    P_DRY_RUN      BOOLEAN DEFAULT FALSE)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_sql        VARCHAR;
  v_files      NUMBER DEFAULT 0;
  v_rows       NUMBER DEFAULT 0;
  v_errors     NUMBER DEFAULT 0;
  v_qid        VARCHAR;
BEGIN
  USE WAREHOUSE &{ENV}_WH_BACKFILL;

  v_sql := 'COPY INTO ' || P_TARGET_TABLE ||
           ' FROM @CV_&{ENV}_RAW.LANDING.STG_ADLS_RAW/' || P_STAGE_PATH ||
           ' PATTERN = ''' || P_PATTERN || '''' ||
           ' FILE_FORMAT = (FORMAT_NAME = ''CV_&{ENV}_RAW.LANDING.FF_PARQUET'')' ||
           ' MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE' ||
           ' INCLUDE_METADATA = (_FILE_NAME = METADATA$FILENAME, _FILE_ROW = METADATA$FILE_ROW_NUMBER,' ||
           '   _FILE_LAST_MODIFIED = METADATA$FILE_LAST_MODIFIED, _LOAD_TS = METADATA$START_SCAN_TIME)' ||
           ' ON_ERROR = ''ABORT_STATEMENT''' ||
           IFF(P_DRY_RUN, ' VALIDATION_MODE = RETURN_ERRORS', '');

  EXECUTE IMMEDIATE :v_sql;
  v_qid := LAST_QUERY_ID();

  IF (NOT P_DRY_RUN) THEN
    -- COPY returns one row per file: file, status, rows_parsed, rows_loaded, errors_seen ...
    INSERT INTO CV_&{ENV}_CONTROL.CONTROL.CTL_FILE_LOAD_LOG
          (BATCH_ID, LOAD_PATH, TARGET_TABLE, FILE_NAME, STATUS, ROWS_PARSED, ROWS_LOADED, ERRORS_SEEN, FIRST_ERROR, LOAD_METHOD, QUERY_ID)
    SELECT :P_BATCH_ID, 'BACKFILL', :P_TARGET_TABLE, "file", "status", "rows_parsed", "rows_loaded", "errors_seen", "first_error", 'COPY', :v_qid
    FROM TABLE(RESULT_SCAN(:v_qid));

    SELECT COUNT(*), COALESCE(SUM(ROWS_LOADED),0), COALESCE(SUM(ERRORS_SEEN),0)
      INTO :v_files, :v_rows, :v_errors
      FROM CV_&{ENV}_CONTROL.CONTROL.CTL_FILE_LOAD_LOG WHERE QUERY_ID = :v_qid;
  END IF;

  CALL CV_&{ENV}_CONTROL.AUDIT.SP_LOG_BATCH(:P_BATCH_ID, 'SP_BACKFILL_COPY', :P_TARGET_TABLE, 'SUCCESS',
                                            :v_rows, 0, :v_errors, NULL);
  RETURN OBJECT_CONSTRUCT('files', v_files, 'rows_loaded', v_rows, 'errors', v_errors, 'query_id', v_qid, 'dry_run', P_DRY_RUN);
EXCEPTION
  WHEN OTHER THEN
    CALL CV_&{ENV}_CONTROL.AUDIT.SP_LOG_BATCH(:P_BATCH_ID, 'SP_BACKFILL_COPY', :P_TARGET_TABLE, 'FAILED',
                                              0, 0, 0, :SQLERRM);
    RAISE;
END;
$$;
