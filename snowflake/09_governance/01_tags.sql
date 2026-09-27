/* =============================================================================
   01_tags.sql — classification tags (ADR-014)
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;
USE SCHEMA CV_&{ENV}_CONTROL.GOVERNANCE;

CREATE TAG IF NOT EXISTS PHI_CLASS
  ALLOWED_VALUES 'DIRECT_ID', 'QUASI_ID', 'CLINICAL', 'NONE'
  COMMENT = 'HIPAA PHI classification; masking policies are attached to this tag';
CREATE TAG IF NOT EXISTS DATA_OWNER    COMMENT = 'Accountable business owner (for access reviews)';
CREATE TAG IF NOT EXISTS SOURCE_SYSTEM COMMENT = 'Originating system';
CREATE TAG IF NOT EXISTS LEGACY_OBJECT COMMENT = 'Legacy EDW table / Informatica mapping this object replaces';

-- role → LOB entitlement map used by the row access policy
CREATE TABLE IF NOT EXISTS LOB_ROLE_MAP (
    ROLE_NAME VARCHAR(100), LOB_CODE VARCHAR(4), GRANTED_BY VARCHAR(100), GRANTED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Changes are access changes: PR + access review required';

MERGE INTO LOB_ROLE_MAP t USING (SELECT * FROM VALUES
    ('&{ENV}_FR_CLAIMS_OPS','COM'), ('&{ENV}_FR_CLAIMS_OPS','MA'),
    ('&{ENV}_FR_MEDICAID_ANALYST','MCD'),
    ('&{ENV}_FR_FINANCE','COM'), ('&{ENV}_FR_FINANCE','MA'), ('&{ENV}_FR_FINANCE','MCD'),
    ('&{ENV}_FR_ACTUARY','COM'), ('&{ENV}_FR_ACTUARY','MA'), ('&{ENV}_FR_ACTUARY','MCD'),
    ('&{ENV}_FR_BI_SERVICE','COM'), ('&{ENV}_FR_BI_SERVICE','MA'), ('&{ENV}_FR_BI_SERVICE','MCD')
  AS s(ROLE_NAME, LOB_CODE)) s
ON t.ROLE_NAME = s.ROLE_NAME AND t.LOB_CODE = s.LOB_CODE
WHEN NOT MATCHED THEN INSERT (ROLE_NAME, LOB_CODE, GRANTED_BY) VALUES (s.ROLE_NAME, s.LOB_CODE, 'bootstrap');
