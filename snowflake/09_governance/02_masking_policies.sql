/* =============================================================================
   02_masking_policies.sql — tag-based masking: attach policies to PHI_CLASS so
   ANY column tagged later is protected automatically (no per-column drift).
   Policies read the tag value on the column via SYSTEM$GET_TAG_ON_CURRENT_COLUMN.
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;
USE SCHEMA CV_&{ENV}_CONTROL.GOVERNANCE;

CREATE OR REPLACE MASKING POLICY MP_PHI_STRING AS (val STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('&{ENV}_FR_PHI_STEWARD') THEN val
    -- pipelines (owner's-rights procs run as SR_CICD, tasks as SR_TRANSFORM) and recon hashing need real values
    WHEN IS_ROLE_IN_SESSION('&{ENV}_SR_CICD') OR IS_ROLE_IN_SESSION('&{ENV}_SR_TRANSFORM')
         OR IS_ROLE_IN_SESSION('&{ENV}_SR_RECON') THEN val
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('CV_&{ENV}_CONTROL.GOVERNANCE.PHI_CLASS') = 'DIRECT_ID'
         THEN IFF(val IS NULL, NULL, 'TKN_' || LEFT(SHA2(val || '&{PHI_SALT_REF}', 256), 16))   -- deterministic token: joinable, not reversible
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('CV_&{ENV}_CONTROL.GOVERNANCE.PHI_CLASS') = 'QUASI_ID'
         THEN IFF(val IS NULL, NULL, LEFT(val, 3) || '**')                                        -- e.g. ZIP5 → ZIP3
    ELSE '***MASKED***'
  END
  COMMENT = 'PHI strings: steward sees clear text; others see token/partial';

CREATE OR REPLACE MASKING POLICY MP_PHI_DATE AS (val DATE) RETURNS DATE ->
  CASE
    WHEN IS_ROLE_IN_SESSION('&{ENV}_FR_PHI_STEWARD') OR IS_ROLE_IN_SESSION('&{ENV}_SR_CICD')
         OR IS_ROLE_IN_SESSION('&{ENV}_SR_TRANSFORM') OR IS_ROLE_IN_SESSION('&{ENV}_SR_RECON') THEN val
    WHEN IS_ROLE_IN_SESSION('&{ENV}_FR_ACTUARY') THEN DATE_FROM_PARTS(YEAR(val), 1, 1)   -- age bands without exact DOB
    ELSE NULL
  END;

ALTER TAG PHI_CLASS SET MASKING POLICY MP_PHI_STRING, MASKING POLICY MP_PHI_DATE;
