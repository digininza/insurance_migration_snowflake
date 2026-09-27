/* =============================================================================
   01_qa_refresh_from_prod_replica.sql — weekly QA/UAT refresh (NONPROD account)
   PROD → NONPROD via database replication (clones can't cross accounts),
   then zero-copy CLONE the replica → QA. Masking/row access policies travel
   with the objects (policies live in the replicated CONTROL.GOVERNANCE).
   ============================================================================= */
-- In PROD account (one-time): enable replication of CORE + CONTROL to NONPROD
-- CREATE FAILOVER GROUP / REPLICATION GROUP FG_CV_CORE_TO_NONPROD
--   OBJECT_TYPES = DATABASES ALLOWED_DATABASES = CV_PROD_CORE, CV_PROD_CONTROL
--   ALLOWED_ACCOUNTS = CAREVISTA.NONPROD REPLICATION_SCHEDULE = 'USING CRON 0 6 * * SUN UTC';

-- In NONPROD account (weekly, after replication refresh):
USE ROLE SYSADMIN;
ALTER REPLICATION GROUP RG_CV_CORE_FROM_PROD REFRESH;             -- secondary replica databases updated

CREATE OR REPLACE DATABASE CV_QA_CORE    CLONE CV_PROD_CORE;       -- seconds; storage shared until changed
CREATE OR REPLACE DATABASE CV_QA_CONTROL CLONE CV_PROD_CONTROL;

-- Post-clone fix-ups
GRANT OWNERSHIP ON DATABASE CV_QA_CORE TO ROLE QA_SR_CICD COPY CURRENT GRANTS;   -- db-level grants aren't cloned
GRANT USAGE ON DATABASE CV_QA_CORE TO ROLE QA_AR_CORE_R;
-- Tasks in cloned schemas come up SUSPENDED; QA DAG resumed explicitly by the QA deploy:
-- SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('CV_QA_CONTROL.ORCHESTRATION.T_ROOT_CV_HOURLY');

-- Proof that PHI is still masked for testers (run as QA_FR_DATA_ENGINEER):
-- SELECT MEMBER_ID, FIRST_NAME, BIRTH_DT FROM CV_QA_CORE.MEMBER.DIM_MEMBER LIMIT 5;   → TKN_…, ***MASKED***, NULL
