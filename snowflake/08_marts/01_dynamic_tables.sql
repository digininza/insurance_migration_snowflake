/* =============================================================================
   01_dynamic_tables.sql — subject marts as Dynamic Tables (ADR-010)
   - REFRESH_MODE = INCREMENTAL is declared explicitly: creation FAILS if the
     query can't refresh incrementally, instead of silently falling back to FULL.
   - Intermediate DTs use TARGET_LAG = DOWNSTREAM.
   - Money totals sum ALL versions: reversals are negative rows, so the sum is
     the net paid amount — exactly how the legacy EDW computed it.
   ~60 legacy aggregate mappings (truncate/insert nightly) → these DTs.
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;

-- -------------------------------------------------------------- member months
CREATE OR REPLACE DYNAMIC TABLE CV_&{ENV}_MART.FINANCE.DT_MEMBER_MONTHS
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = &{ENV}_WH_TRANSFORM
  REFRESH_MODE = INCREMENTAL
  COMMENT = 'Grain: month × LOB × plan. Replaces m_AGG_MBR_MONTHS.'
AS
SELECT ELIGIBILITY_MONTH, LOB_CODE, PLAN_ID,
       SUM(MEMBER_MONTH)          AS MEMBER_MONTHS,
       COUNT(*)                   AS MEMBER_ROWS            -- no COUNT(DISTINCT): keep it incremental
FROM CV_&{ENV}_CORE.MEMBER.FACT_ELIGIBILITY_MONTH
GROUP BY ELIGIBILITY_MONTH, LOB_CODE, PLAN_ID;

-- -------------------------------------------------------- claims cost monthly
CREATE OR REPLACE DYNAMIC TABLE CV_&{ENV}_MART.CLAIMS.DT_CLAIMS_COST_MONTHLY
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = &{ENV}_WH_TRANSFORM
  REFRESH_MODE = INCREMENTAL
  COMMENT = 'Grain: service month × LOB × claim type. Net of reversals.'
AS
SELECT SERVICE_MONTH, LOB_CODE, CLAIM_TYPE,
       SUM(BILLED_AMT)            AS BILLED_AMT,
       SUM(ALLOWED_AMT)           AS ALLOWED_AMT,
       SUM(PAID_AMT)              AS PAID_AMT,
       SUM(MEMBER_LIABILITY_AMT)  AS MEMBER_LIABILITY_AMT,
       COUNT_IF(IS_CURRENT_VERSION AND LINE_STATUS = 'PAID') AS PAID_LINES
FROM CV_&{ENV}_CORE.CLAIMS.FACT_CLAIM_LINE
GROUP BY SERVICE_MONTH, LOB_CODE, CLAIM_TYPE;

-- ------------------------------------------------------------------ PMPM (leaf)
CREATE OR REPLACE DYNAMIC TABLE CV_&{ENV}_MART.FINANCE.DT_PMPM_BY_LOB_MONTH
  TARGET_LAG = '1 hour'
  WAREHOUSE = &{ENV}_WH_TRANSFORM
  REFRESH_MODE = INCREMENTAL
  COMMENT = 'Grain: month × LOB. Executive PMPM. Suspended by SP_PUBLISH_GATE when blocked.'
AS
WITH mm AS (
    SELECT ELIGIBILITY_MONTH AS MONTH_START, LOB_CODE, SUM(MEMBER_MONTHS) AS MEMBER_MONTHS
    FROM CV_&{ENV}_MART.FINANCE.DT_MEMBER_MONTHS GROUP BY 1, 2
), cost AS (
    SELECT SERVICE_MONTH AS MONTH_START, LOB_CODE, SUM(PAID_AMT) AS PAID_AMT, SUM(ALLOWED_AMT) AS ALLOWED_AMT
    FROM CV_&{ENV}_MART.CLAIMS.DT_CLAIMS_COST_MONTHLY GROUP BY 1, 2
)
SELECT mm.MONTH_START, mm.LOB_CODE, mm.MEMBER_MONTHS,
       COALESCE(cost.PAID_AMT, 0)    AS PAID_AMT,
       COALESCE(cost.ALLOWED_AMT, 0) AS ALLOWED_AMT,
       ROUND(COALESCE(cost.PAID_AMT, 0) / NULLIF(mm.MEMBER_MONTHS, 0), 2) AS PAID_PMPM
FROM mm
LEFT JOIN cost ON cost.MONTH_START = mm.MONTH_START AND cost.LOB_CODE = mm.LOB_CODE;

-- ------------------------------------------------- lag triangle (IBNR input)
CREATE OR REPLACE DYNAMIC TABLE CV_&{ENV}_MART.CLAIMS.DT_CLAIMS_LAG_TRIANGLE
  TARGET_LAG = '6 hours'
  WAREHOUSE = &{ENV}_WH_TRANSFORM
  REFRESH_MODE = AUTO
  COMMENT = 'Grain: LOB × incurred (service) month × paid month. Actuarial IBNR reserving input.'
AS
SELECT LOB_CODE,
       SERVICE_MONTH                                   AS INCURRED_MONTH,
       PAID_MONTH,
       DATEDIFF(month, SERVICE_MONTH, PAID_MONTH)      AS LAG_MONTHS,
       SUM(PAID_AMT)                                   AS PAID_AMT,
       COUNT(*)                                        AS LINE_VERSIONS
FROM CV_&{ENV}_CORE.CLAIMS.FACT_CLAIM_LINE
WHERE PAID_MONTH IS NOT NULL
GROUP BY LOB_CODE, SERVICE_MONTH, PAID_MONTH;

-- -------------------------------------------------------- provider scorecard
CREATE OR REPLACE DYNAMIC TABLE CV_&{ENV}_MART.PROVIDER.DT_PROVIDER_SCORECARD
  TARGET_LAG = '1 day'
  WAREHOUSE = &{ENV}_WH_TRANSFORM
  REFRESH_MODE = AUTO          -- COUNT(DISTINCT) may force FULL; daily lag makes that acceptable
  COMMENT = 'Grain: rendering provider × service month (current versions only)'
AS
SELECT f.RENDERING_PROVIDER_SK, p.PROVIDER_NPI, p.SPECIALTY_CD, p.NETWORK_ID, f.SERVICE_MONTH,
       COUNT(*)                                      AS LINES,
       COUNT_IF(f.LINE_STATUS = 'DENIED')            AS DENIED_LINES,
       SUM(f.ALLOWED_AMT)                            AS ALLOWED_AMT,
       SUM(f.PAID_AMT)                               AS PAID_AMT,
       COUNT(DISTINCT f.MEMBER_SK)                   AS UNIQUE_MEMBERS
FROM CV_&{ENV}_CORE.CLAIMS.FACT_CLAIM_LINE f
JOIN CV_&{ENV}_CORE.PROVIDER.DIM_PROVIDER p ON p.PROVIDER_SK = f.RENDERING_PROVIDER_SK
WHERE f.IS_CURRENT_VERSION
GROUP BY f.RENDERING_PROVIDER_SK, p.PROVIDER_NPI, p.SPECIALTY_CD, p.NETWORK_ID, f.SERVICE_MONTH;

-- ------------------------------------------------------------ denial rate daily
CREATE OR REPLACE DYNAMIC TABLE CV_&{ENV}_MART.CLAIMS.DT_DENIAL_RATE_DAILY
  TARGET_LAG = '1 hour'
  WAREHOUSE = &{ENV}_WH_TRANSFORM
  REFRESH_MODE = INCREMENTAL
  COMMENT = 'Grain: received date × LOB × claim type (current versions)'
AS
SELECT d.CALENDAR_DATE AS RECEIVED_DATE, f.LOB_CODE, f.CLAIM_TYPE,
       COUNT_IF(f.LINE_STATUS IN ('PAID','DENIED'))  AS ADJUDICATED_LINES,
       COUNT_IF(f.LINE_STATUS = 'DENIED')            AS DENIED_LINES,
       COUNT_IF(f.IS_AUTO_ADJUDICATED)               AS AUTO_ADJUDICATED_LINES
FROM CV_&{ENV}_CORE.CLAIMS.FACT_CLAIM_LINE f
JOIN CV_&{ENV}_CORE.COMMON.DIM_DATE d ON d.DATE_SK = f.RECEIVED_DATE_SK
WHERE f.IS_CURRENT_VERSION
GROUP BY d.CALENDAR_DATE, f.LOB_CODE, f.CLAIM_TYPE;

/* Checks after deploy:
   SHOW DYNAMIC TABLES IN DATABASE CV_PROD_MART;         -- refresh_mode, target_lag, scheduling_state
   SELECT * FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY()) ORDER BY refresh_start_time DESC;
   ALTER DYNAMIC TABLE ... REFRESH;                        -- manual refresh after backfill SWAP */
