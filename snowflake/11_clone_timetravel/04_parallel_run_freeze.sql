/* =============================================================================
   04_parallel_run_freeze.sql — freeze new-platform state at the instant the
   legacy EDW month-end extract was taken, so reconciliation compares like with like
   while daily loads keep running.
   ============================================================================= */
USE ROLE PROD_SR_RECON;

CREATE OR REPLACE SCHEMA CV_PROD_CONTROL.RECON_SNAP_20260531
  CLONE CV_PROD_CORE.CLAIMS AT (TIMESTAMP => '2026-06-01 05:30:00 -04:00'::TIMESTAMP_TZ);

-- Point recon rules at the snapshot for the month-end run:
-- CALL CV_PROD_CONTROL.RECON.SP_RUN_RECON('2026-05-31');   (rules parameterised by schema in PROD)
-- Drop after sign-off; the snapshot is evidence attached to the cutover checklist.
