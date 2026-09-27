/* =============================================================================
   04_network_policy_users.sql — private-only access + key-pair service users.
   Public keys are placeholders; private keys live ONLY in Azure Key Vault.
   ============================================================================= */
USE ROLE SECURITYADMIN;

CREATE NETWORK RULE IF NOT EXISTS CV_&{ENV}_CONTROL.GOVERNANCE.NR_PRIVATE_LINK
  TYPE = AZURELINKID MODE = INGRESS
  VALUE_LIST = ('<azure-private-endpoint-link-id>');
CREATE NETWORK RULE IF NOT EXISTS CV_&{ENV}_CONTROL.GOVERNANCE.NR_CORP_EGRESS
  TYPE = IPV4 MODE = INGRESS VALUE_LIST = ('203.0.113.0/24');   -- documentation range placeholder

CREATE NETWORK POLICY IF NOT EXISTS NP_CV_&{ENV}_PRIVATE
  ALLOWED_NETWORK_RULE_LIST = ('CV_&{ENV}_CONTROL.GOVERNANCE.NR_PRIVATE_LINK',
                               'CV_&{ENV}_CONTROL.GOVERNANCE.NR_CORP_EGRESS')
  COMMENT = 'PHI account: Private Link + corporate egress only';

-- ADF loader: key-pair auth, private key in Key Vault secret kv-cv-data-&{ENV}/snowflake-adf-loader-pk
CREATE USER IF NOT EXISTS SVC_&{ENV}_ADF_LOADER
  TYPE = SERVICE
  DEFAULT_ROLE = &{ENV}_SR_INGEST DEFAULT_WAREHOUSE = &{ENV}_WH_INGEST
  RSA_PUBLIC_KEY = '<public-key-placeholder>'
  NETWORK_POLICY = NP_CV_&{ENV}_PRIVATE
  COMMENT = 'Azure Data Factory Snowflake V2 linked service';
GRANT ROLE &{ENV}_SR_INGEST TO USER SVC_&{ENV}_ADF_LOADER;
GRANT ROLE &{ENV}_SR_RECON  TO USER SVC_&{ENV}_ADF_LOADER;   -- ADF calls SP_RUN_RECON

CREATE USER IF NOT EXISTS SVC_&{ENV}_CICD
  TYPE = SERVICE DEFAULT_ROLE = &{ENV}_SR_CICD DEFAULT_WAREHOUSE = &{ENV}_WH_CICD
  RSA_PUBLIC_KEY = '<public-key-placeholder>' COMMENT = 'GitHub Actions deployer';
GRANT ROLE &{ENV}_SR_CICD TO USER SVC_&{ENV}_CICD;

CREATE USER IF NOT EXISTS SVC_&{ENV}_POWERBI
  TYPE = SERVICE DEFAULT_ROLE = &{ENV}_FR_BI_SERVICE DEFAULT_WAREHOUSE = &{ENV}_WH_BI
  RSA_PUBLIC_KEY = '<public-key-placeholder>' COMMENT = 'Power BI scheduled refresh (SSO for interactive users)';
GRANT ROLE &{ENV}_FR_BI_SERVICE TO USER SVC_&{ENV}_POWERBI;

-- Account-level hardening (anti-exfiltration)
USE ROLE ACCOUNTADMIN;
ALTER ACCOUNT SET REQUIRE_STORAGE_INTEGRATION_FOR_STAGE_CREATION = TRUE;
ALTER ACCOUNT SET REQUIRE_STORAGE_INTEGRATION_FOR_STAGE_OPERATION = TRUE;
ALTER ACCOUNT SET PREVENT_UNLOAD_TO_INLINE_URL = TRUE;
-- ALTER ACCOUNT SET NETWORK_POLICY = NP_CV_PROD_PRIVATE;   -- applied manually after Private Link verified
