/* =============================================================================
   03_row_access_policy.sql — LOB separation (Medicaid contract requirement)
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;
USE SCHEMA CV_&{ENV}_CONTROL.GOVERNANCE;

CREATE OR REPLACE ROW ACCESS POLICY RAP_LOB AS (lob_code VARCHAR) RETURNS BOOLEAN ->
     IS_ROLE_IN_SESSION('&{ENV}_FR_PHI_STEWARD')
  OR IS_ROLE_IN_SESSION('&{ENV}_SR_CICD')                    -- owner's-rights ELT procs
  OR IS_ROLE_IN_SESSION('&{ENV}_SR_TRANSFORM')
  OR IS_ROLE_IN_SESSION('&{ENV}_SR_RECON')
  OR IS_ROLE_IN_SESSION('&{ENV}_FR_DATA_ENGINEER')           -- engineers see all rows; PHI still masked
  OR EXISTS (SELECT 1 FROM CV_&{ENV}_CONTROL.GOVERNANCE.LOB_ROLE_MAP m
             WHERE m.LOB_CODE = lob_code AND IS_ROLE_IN_SESSION(m.ROLE_NAME))
  COMMENT = 'Rows visible only for LOBs mapped to a role in session';

ALTER TABLE CV_&{ENV}_CORE.CLAIMS.FACT_CLAIM_LINE        ADD ROW ACCESS POLICY RAP_LOB ON (LOB_CODE);
ALTER TABLE CV_&{ENV}_CORE.MEMBER.DIM_MEMBER             ADD ROW ACCESS POLICY RAP_LOB ON (LOB_CODE);
ALTER TABLE CV_&{ENV}_CORE.MEMBER.FACT_ELIGIBILITY_MONTH ADD ROW ACCESS POLICY RAP_LOB ON (LOB_CODE);
-- (re-running ADD on an already-protected table errors: deploy wraps these in a
--  POLICY_REFERENCES check — see snowflake/deploy/deploy.sh)
