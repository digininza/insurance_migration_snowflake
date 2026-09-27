/* =============================================================================
   02_alerts.sql — Snowflake Alerts (serverless) → email integration; the same
   events are also forwarded to Azure Monitor via the ADF/Logic App path.
   ============================================================================= */
USE ROLE &{ENV}_SR_TRANSFORM;
USE SCHEMA CV_&{ENV}_CONTROL.MONITORING;

CREATE OR REPLACE ALERT ALR_TASK_FAILED
  SCHEDULE = '15 MINUTE'
  IF (EXISTS (
      SELECT 1 FROM TABLE(CV_&{ENV}_CONTROL.INFORMATION_SCHEMA.TASK_HISTORY(
               SCHEDULED_TIME_RANGE_START => DATEADD(minute, -15, CURRENT_TIMESTAMP())))
      WHERE STATE = 'FAILED'))
  THEN CALL SYSTEM$SEND_EMAIL('NI_CV_&{ENV}_EMAIL', 'data-platform-oncall@carevista.example',
         '[&{ENV}] Snowflake task failure', 'A task in CV_&{ENV}_CONTROL.ORCHESTRATION failed in the last 15 min. See V_TASK_FAILURES_7D.');

CREATE OR REPLACE ALERT ALR_PIPE_STALLED
  SCHEDULE = 'USING CRON */30 1-6 * * * America/New_York'      -- during the load window only
  IF (EXISTS (
      SELECT 1 FROM TABLE(CV_&{ENV}_RAW.INFORMATION_SCHEMA.COPY_HISTORY(
               TABLE_NAME => 'CV_&{ENV}_RAW.CLAIMS.CLAIM_LINE', START_TIME => DATEADD(hour, -2, CURRENT_TIMESTAMP())))
      HAVING COUNT(*) = 0))
  THEN CALL SYSTEM$SEND_EMAIL('NI_CV_&{ENV}_EMAIL', 'data-platform-oncall@carevista.example',
         '[&{ENV}] No claim_line files loaded in 2h', 'Check SYSTEM$PIPE_STATUS, Event Grid subscription and ADF PL_11 runs. Runbook: snowpipe_troubleshooting.md');

CREATE OR REPLACE ALERT ALR_COPY_ERRORS
  SCHEDULE = '30 MINUTE'
  IF (EXISTS (
      SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
      WHERE LAST_LOAD_TIME > DATEADD(minute, -90, CURRENT_TIMESTAMP())
        AND TABLE_CATALOG_NAME = 'CV_&{ENV}_RAW' AND STATUS IN ('Load failed', 'Partially loaded')))
  THEN CALL SYSTEM$SEND_EMAIL('NI_CV_&{ENV}_EMAIL', 'data-platform-oncall@carevista.example',
         '[&{ENV}] Snowpipe/COPY file errors', 'Files skipped (ON_ERROR=SKIP_FILE). Inspect COPY_HISTORY.first_error and replay after fix.');

CREATE OR REPLACE ALERT ALR_PUBLISH_BLOCKED
  SCHEDULE = 'USING CRON 45 5 * * * America/New_York'
  IF (EXISTS (
      SELECT 1 FROM CV_&{ENV}_CONTROL.CONTROL.CTL_PUBLISH_STATUS
      WHERE BUSINESS_DATE = DATEADD(day, -1, CURRENT_DATE()) AND GATE_STATUS <> 'PASSED'))
  THEN CALL SYSTEM$SEND_EMAIL('NI_CV_&{ENV}_EMAIL', 'data-platform-oncall@carevista.example',
         '[&{ENV}] SLA risk: publish gate BLOCKED at 05:45 ET', 'See CTL_PUBLISH_STATUS.BLOCK_REASONS.');

CREATE OR REPLACE ALERT ALR_DT_REFRESH_FAILED
  SCHEDULE = '30 MINUTE'
  IF (EXISTS (
      SELECT 1 FROM TABLE(CV_&{ENV}_MART.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
               DATA_TIMESTAMP_START => DATEADD(hour, -1, CURRENT_TIMESTAMP()), ERROR_ONLY => TRUE))))
  THEN CALL SYSTEM$SEND_EMAIL('NI_CV_&{ENV}_EMAIL', 'data-platform-oncall@carevista.example',
         '[&{ENV}] Dynamic Table refresh failed', 'See V_DT_REFRESH_HEALTH.');

ALTER ALERT ALR_TASK_FAILED RESUME;
ALTER ALERT ALR_PIPE_STALLED RESUME;
ALTER ALERT ALR_COPY_ERRORS RESUME;
ALTER ALERT ALR_PUBLISH_BLOCKED RESUME;
ALTER ALERT ALR_DT_REFRESH_FAILED RESUME;
