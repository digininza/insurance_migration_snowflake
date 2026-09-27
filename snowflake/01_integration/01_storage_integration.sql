/* =============================================================================
   01_storage_integration.sql — keyless Snowflake → ADLS Gen2 access (ADR-013)
   One-time Azure steps after creation (documented in RUNBOOK §2):
     1. DESC INTEGRATION → open AZURE_CONSENT_URL as a tenant admin → consent.
     2. Grant the AZURE_MULTI_TENANT_APP_NAME service principal
        "Storage Blob Data Reader" on container `raw` and `recon`
        (Contributor only on `recon/unload` if unloads are needed).
   ============================================================================= */
USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION IF NOT EXISTS SI_CV_&{ENV}_ADLS
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'AZURE'
  ENABLED = TRUE
  AZURE_TENANT_ID = '&{AZURE_TENANT_ID}'
  STORAGE_ALLOWED_LOCATIONS = (
      'azure://&{ADLS_ACCOUNT}.blob.core.windows.net/raw/',
      'azure://&{ADLS_ACCOUNT}.blob.core.windows.net/recon/')
  STORAGE_BLOCKED_LOCATIONS = ('azure://&{ADLS_ACCOUNT}.blob.core.windows.net/raw/_quarantine_pii_exports/')
  COMMENT = 'ADLS raw + recon containers. No SAS tokens anywhere.';

DESC INTEGRATION SI_CV_&{ENV}_ADLS;   -- copy AZURE_CONSENT_URL + AZURE_MULTI_TENANT_APP_NAME

GRANT USAGE ON INTEGRATION SI_CV_&{ENV}_ADLS TO ROLE &{ENV}_SR_CICD;   -- to create stages
