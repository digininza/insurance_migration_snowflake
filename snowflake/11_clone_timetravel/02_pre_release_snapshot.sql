/* =============================================================================
   02_pre_release_snapshot.sql — rollback point before any release touching CORE
   ============================================================================= */
USE ROLE PROD_SR_CICD;
SET REL = 'R27';

-- 1. Snapshot (metadata only)
CREATE OR REPLACE SCHEMA IDENTIFIER('CV_PROD_CORE.CLAIMS_PRE_' || $REL) CLONE CV_PROD_CORE.CLAIMS;
CREATE OR REPLACE SCHEMA IDENTIFIER('CV_PROD_CORE.MEMBER_PRE_' || $REL) CLONE CV_PROD_CORE.MEMBER;

-- 2. Deploy release …

-- 3a. Success → drop snapshots after 7 days (T_DROP_OLD_SNAPSHOTS job)
-- 3b. Failure → atomic swap back, then replay streams from RAW for the gap:
--   ALTER SCHEMA CV_PROD_CORE.CLAIMS SWAP WITH IDENTIFIER('CV_PROD_CORE.CLAIMS_PRE_' || $REL);
--   (STAGE streams were not consumed by the bad release if the DAG was suspended during deploy)
