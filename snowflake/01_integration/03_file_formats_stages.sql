/* =============================================================================
   03_file_formats_stages.sql — file formats + external stages on the integration
   Folder contract (ADF writes, Snowflake reads):
     raw/<mode>/<system>/<object>/load_date=YYYY-MM-DD/run_id=<adf_run_id>/part-*.snappy.parquet
     mode ∈ {incremental, backfill}
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;
USE SCHEMA CV_&{ENV}_RAW.LANDING;

CREATE FILE FORMAT IF NOT EXISTS FF_PARQUET
  TYPE = PARQUET
  USE_LOGICAL_TYPE = TRUE              -- DECIMAL/TIMESTAMP logical types preserved (money precision!)
  BINARY_AS_TEXT = FALSE
  COMMENT = 'ADF Parquet (Snappy)';

CREATE FILE FORMAT IF NOT EXISTS FF_PBM_PIPE
  TYPE = CSV FIELD_DELIMITER = '|' SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL') EMPTY_FIELD_AS_NULL = TRUE TRIM_SPACE = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE ENCODING = 'UTF8'
  COMMENT = 'PBM pharmacy partner file (trailer stripped by ADF after validation)';

CREATE FILE FORMAT IF NOT EXISTS FF_CODESET_CSV
  TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('');

CREATE STAGE IF NOT EXISTS STG_ADLS_RAW
  STORAGE_INTEGRATION = SI_CV_&{ENV}_ADLS
  URL = 'azure://&{ADLS_ACCOUNT}.blob.core.windows.net/raw/'
  FILE_FORMAT = FF_PARQUET
  DIRECTORY = (ENABLE = FALSE)
  COMMENT = 'Raw landing (incremental + backfill)';

CREATE STAGE IF NOT EXISTS STG_ADLS_RECON
  STORAGE_INTEGRATION = SI_CV_&{ENV}_ADLS
  URL = 'azure://&{ADLS_ACCOUNT}.blob.core.windows.net/recon/'
  FILE_FORMAT = FF_PARQUET
  COMMENT = 'Legacy EDW reconciliation extracts';

-- Smoke test after Azure consent: LIST @STG_ADLS_RAW/incremental/ PATTERN='.*claim_line.*' ;
