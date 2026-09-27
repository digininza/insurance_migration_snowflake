/* =============================================================================
   05_month_end_scaling.sql — scale UP transform compute for month-end close,
   then back down. Month-end MERGE volume ~5x (premium billing + claims runout).
   ============================================================================= */
USE ROLE &{ENV}_SR_TRANSFORM;
USE SCHEMA CV_&{ENV}_CONTROL.ORCHESTRATION;

CREATE OR REPLACE TASK T_MONTH_END_SCALE_UP
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  SCHEDULE = 'USING CRON 0 4 1 * * UTC'
AS ALTER WAREHOUSE &{ENV}_WH_TRANSFORM SET WAREHOUSE_SIZE = 'LARGE';

CREATE OR REPLACE TASK T_MONTH_END_SCALE_DOWN
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  SCHEDULE = 'USING CRON 0 13 2 * * UTC'
AS ALTER WAREHOUSE &{ENV}_WH_TRANSFORM SET WAREHOUSE_SIZE = 'MEDIUM';

ALTER TASK T_MONTH_END_SCALE_UP RESUME;
ALTER TASK T_MONTH_END_SCALE_DOWN RESUME;
