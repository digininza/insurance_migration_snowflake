/* =============================================================================
   adf_control_db.sql — Azure SQL Database `sqldb-cv-adfctl`, schema ctl
   Metadata that drives the generic ADF pipelines (LLD_ADF.md §2).
   T-SQL. Deployed by the ADF CI pipeline (sqlpackage / DACPAC in production).
   ============================================================================= */
IF SCHEMA_ID('ctl') IS NULL EXEC('CREATE SCHEMA ctl');
GO

CREATE TABLE ctl.source_system (
    system_code           VARCHAR(20)  NOT NULL PRIMARY KEY,
    linked_service        VARCHAR(100) NOT NULL,
    source_type           VARCHAR(20)  NOT NULL,          -- SQLSERVER | ORACLE | SFTP
    extract_window_start  TIME         NULL,
    extract_window_end    TIME         NULL,
    max_parallel_copies   INT          NOT NULL DEFAULT 8,  -- protects OLTP
    priority              INT          NOT NULL DEFAULT 100,
    is_active             BIT          NOT NULL DEFAULT 1
);

CREATE TABLE ctl.source_object (
    object_id          INT IDENTITY(1,1) PRIMARY KEY,
    system_code        VARCHAR(20)  NOT NULL REFERENCES ctl.source_system(system_code),
    schema_name        VARCHAR(128) NOT NULL,
    table_name         VARCHAR(128) NOT NULL,
    feed_code          VARCHAR(40)  NOT NULL,             -- = Snowflake CONTROL.CTL_FEED.FEED_CODE
    load_type          VARCHAR(12)  NOT NULL CHECK (load_type IN ('FULL','INCREMENTAL','FILE','KEYS_ONLY')),
    select_columns     VARCHAR(MAX) NOT NULL,             -- explicit projection, never SELECT *
    watermark_column   VARCHAR(128) NULL,
    watermark_type     VARCHAR(12)  NULL CHECK (watermark_type IN ('ROWVERSION','DATETIME','SCN')),
    lookback_minutes   INT          NOT NULL DEFAULT 0,   -- Oracle timestamp overlap (dedup downstream)
    primary_key        VARCHAR(400) NOT NULL,
    partition_column   VARCHAR(128) NULL,                 -- backfill DynamicRange column
    target_path        VARCHAR(400) NOT NULL,             -- <system>/<object> under raw/<mode>/ (Snowpipe prefix!)
    snowflake_table    VARCHAR(400) NOT NULL,
    max_rows_per_file  INT          NOT NULL DEFAULT 2000000,  -- tuned so Parquet files are 128-256 MB
    criticality        VARCHAR(12)  NOT NULL DEFAULT 'CRITICAL',
    priority           INT          NOT NULL DEFAULT 100,
    is_active          BIT          NOT NULL DEFAULT 1,
    CONSTRAINT uq_source_object UNIQUE (system_code, schema_name, table_name)
);

CREATE TABLE ctl.watermark (
    object_id            INT PRIMARY KEY REFERENCES ctl.source_object(object_id),
    last_watermark       VARCHAR(40) NOT NULL,     -- rowversion as bigint text, or ISO timestamp
    last_success_run_id  VARCHAR(64) NULL,
    updated_at           DATETIME2   NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE TABLE ctl.watermark_hist (object_id INT, last_watermark VARCHAR(40), run_id VARCHAR(64), changed_at DATETIME2 DEFAULT SYSUTCDATETIME());

CREATE TABLE ctl.backfill_partition (
    partition_id       BIGINT IDENTITY(1,1) PRIMARY KEY,
    object_id          INT NOT NULL REFERENCES ctl.source_object(object_id),
    partition_month    DATE NOT NULL,
    partition_label    VARCHAR(40) NOT NULL,        -- e.g. 2014-01 or 2019-03_p2
    range_column       VARCHAR(128) NOT NULL,       -- e.g. SERVICE_FROM_DT
    range_start        VARCHAR(40) NOT NULL,        -- SQL literal
    range_end          VARCHAR(40) NOT NULL,
    id_lower           BIGINT NULL,                 -- DynamicRange bounds on partition_column
    id_upper           BIGINT NULL,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RUNNING','DONE','FAILED')),
    rows_copied        BIGINT NULL,
    attempts           INT NOT NULL DEFAULT 0,
    last_error         NVARCHAR(4000) NULL,
    updated_at         DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE ctl.pipeline_run (
    run_id VARCHAR(64), object_id INT, business_date DATE, rows_read BIGINT, rows_written BIGINT,
    files_written INT, bytes_written BIGINT, status VARCHAR(12), error_message NVARCHAR(4000),
    start_ts DATETIME2 DEFAULT SYSUTCDATETIME(), end_ts DATETIME2,
    CONSTRAINT pk_pipeline_run PRIMARY KEY (run_id, object_id)
);

CREATE TABLE ctl.recon_legacy_query (
    rule_id VARCHAR(20) PRIMARY KEY, legacy_sql NVARCHAR(MAX) NOT NULL, is_active BIT NOT NULL DEFAULT 1
);
GO

-- Old watermark as a SQL literal usable in the source dialect (with Oracle look-back overlap)
CREATE OR ALTER VIEW ctl.vw_watermark_literal AS
SELECT o.object_id,
       w.last_watermark,
       CASE o.watermark_type
         WHEN 'ROWVERSION' THEN w.last_watermark
         WHEN 'DATETIME'   THEN 'TO_TIMESTAMP(''' + CONVERT(VARCHAR(26), DATEADD(MINUTE, -o.lookback_minutes,
                                  CAST(w.last_watermark AS DATETIME2)), 121) + ''',''YYYY-MM-DD HH24:MI:SS.FF6'')'
         ELSE w.last_watermark END AS wm_literal
FROM ctl.source_object o JOIN ctl.watermark w ON w.object_id = o.object_id;
GO

CREATE OR ALTER PROCEDURE ctl.usp_get_objects @system_code VARCHAR(20), @load_type VARCHAR(12) AS
SELECT object_id, system_code, schema_name, table_name, feed_code, select_columns, watermark_column,
       watermark_type, target_path, max_rows_per_file, criticality
FROM ctl.source_object
WHERE system_code = @system_code AND load_type = @load_type AND is_active = 1
ORDER BY priority, object_id;
GO

CREATE OR ALTER PROCEDURE ctl.usp_update_watermark @object_id INT, @new_watermark VARCHAR(40), @run_id VARCHAR(64) AS
BEGIN
  SET NOCOUNT ON;
  IF @new_watermark IS NULL RETURN;              -- empty source table: keep old watermark
  INSERT INTO ctl.watermark_hist (object_id, last_watermark, run_id)
  SELECT object_id, last_watermark, @run_id FROM ctl.watermark WHERE object_id = @object_id;
  UPDATE ctl.watermark SET last_watermark = @new_watermark, last_success_run_id = @run_id, updated_at = SYSUTCDATETIME()
  WHERE object_id = @object_id;
END;
GO

CREATE OR ALTER PROCEDURE ctl.usp_log_run_start @run_id VARCHAR(64), @object_id INT, @business_date VARCHAR(10) AS
INSERT INTO ctl.pipeline_run (run_id, object_id, business_date, status) VALUES (@run_id, @object_id, @business_date, 'RUNNING');
GO

CREATE OR ALTER PROCEDURE ctl.usp_log_run_end @run_id VARCHAR(64), @object_id INT, @status VARCHAR(12), @error_message NVARCHAR(4000) AS
UPDATE ctl.pipeline_run SET status = @status, error_message = @error_message, end_ts = SYSUTCDATETIME()
WHERE run_id = @run_id AND object_id = @object_id;
GO

CREATE OR ALTER PROCEDURE ctl.usp_get_backfill_partitions @object_id INT, @from_month DATE, @to_month DATE, @max_rows INT AS
SELECT TOP (@max_rows) p.partition_id, p.partition_label, p.range_column, p.range_start, p.range_end, p.id_lower, p.id_upper,
       o.system_code, o.schema_name, o.table_name, o.select_columns, o.partition_column, o.target_path, o.max_rows_per_file
FROM ctl.backfill_partition p JOIN ctl.source_object o ON o.object_id = p.object_id
WHERE p.object_id = @object_id AND p.partition_month BETWEEN @from_month AND @to_month
  AND p.status IN ('PENDING','FAILED')                       -- restartable: DONE partitions are never re-copied
ORDER BY p.partition_month;
GO

CREATE OR ALTER PROCEDURE ctl.usp_mark_partition @partition_id BIGINT, @status VARCHAR(10), @rows_copied BIGINT, @error NVARCHAR(4000) AS
UPDATE ctl.backfill_partition
   SET status = @status, rows_copied = COALESCE(@rows_copied, rows_copied), last_error = @error,
       attempts = attempts + CASE WHEN @status = 'RUNNING' THEN 1 ELSE 0 END, updated_at = SYSUTCDATETIME()
 WHERE partition_id = @partition_id;
GO
