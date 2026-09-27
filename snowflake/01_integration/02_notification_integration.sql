/* =============================================================================
   02_notification_integration.sql — Event Grid → Storage Queue → Snowpipe
   Azure side (Terraform/Bicep in the landing-zone repo, summarised here):
     - Storage queue:  <account>/queues/snowpipe-raw-incremental
     - Event Grid system topic on the storage account, subscription:
         event type  = Microsoft.Storage.BlobCreated
         subject begins with /blobServices/default/containers/raw/blobs/incremental/
         subject ends with   .parquet          (ignore _SUCCESS markers)
         endpoint    = storage queue above
     - Consent via AZURE_CONSENT_URL, then grant the Snowflake SP
       "Storage Queue Data Contributor" on the queue.
   Backfill files land under raw/backfill/ and are deliberately NOT routed to
   Snowpipe — they are loaded with bulk COPY (ADR-007).
   ============================================================================= */
USE ROLE ACCOUNTADMIN;

CREATE NOTIFICATION INTEGRATION IF NOT EXISTS NI_CV_&{ENV}_ADLS_EVENTS
  ENABLED = TRUE
  TYPE = QUEUE
  NOTIFICATION_PROVIDER = AZURE_STORAGE_QUEUE
  AZURE_STORAGE_QUEUE_PRIMARY_URI = 'https://&{ADLS_ACCOUNT}.queue.core.windows.net/snowpipe-raw-incremental'
  AZURE_TENANT_ID = '&{AZURE_TENANT_ID}'
  COMMENT = 'Snowpipe auto-ingest for raw/incremental/**';

DESC NOTIFICATION INTEGRATION NI_CV_&{ENV}_ADLS_EVENTS;

GRANT USAGE ON INTEGRATION NI_CV_&{ENV}_ADLS_EVENTS TO ROLE &{ENV}_SR_CICD;

-- Outbound email for Snowflake Alerts
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS NI_CV_&{ENV}_EMAIL
  TYPE = EMAIL ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('data-platform-oncall@carevista.example');
GRANT USAGE ON INTEGRATION NI_CV_&{ENV}_EMAIL TO ROLE &{ENV}_SR_TRANSFORM;
