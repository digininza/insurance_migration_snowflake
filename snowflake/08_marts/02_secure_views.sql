/* =============================================================================
   02_secure_views.sql — consumer-facing secure views (definition hidden,
   optimizer can't leak filtered rows). Row access policy on the underlying
   facts still applies (LOB separation).
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;

CREATE OR REPLACE SECURE VIEW CV_&{ENV}_MART.FINANCE.V_MLR_MONTHLY
  COMMENT = 'Medical Loss Ratio by month × LOB = medical paid / earned premium (simplified: invoiced)'
AS
WITH prem AS (
    SELECT BILLING_MONTH AS MONTH_START, LOB_CODE, SUM(INVOICE_AMT) AS PREMIUM_AMT
    FROM CV_&{ENV}_CORE.FINANCE.FACT_PREMIUM_INVOICE
    WHERE INVOICE_STATUS <> 'VOID'
    GROUP BY 1, 2
)
SELECT p.MONTH_START, p.LOB_CODE, p.PAID_AMT AS MEDICAL_PAID_AMT, prem.PREMIUM_AMT,
       ROUND(p.PAID_AMT / NULLIF(prem.PREMIUM_AMT, 0), 4) AS MLR,
       l.MLR_TARGET,
       IFF(p.PAID_AMT / NULLIF(prem.PREMIUM_AMT, 0) < l.MLR_TARGET, 'BELOW_TARGET', 'OK') AS MLR_FLAG
FROM CV_&{ENV}_MART.FINANCE.DT_PMPM_BY_LOB_MONTH p
LEFT JOIN prem ON prem.MONTH_START = p.MONTH_START AND prem.LOB_CODE = p.LOB_CODE
LEFT JOIN CV_&{ENV}_CORE.COMMON.DIM_LOB l ON l.LOB_CODE = p.LOB_CODE;

CREATE OR REPLACE SECURE VIEW CV_&{ENV}_MART.REGULATORY.V_MEDICAID_ENCOUNTER_EXTRACT
  COMMENT = 'State encounter submission extract (Medicaid lines, current version). Row access limits to MCD roles.'
AS
SELECT f.CLAIM_ID, f.LINE_NO, f.CLAIM_LINE_VERSION, m.MEMBER_ID, p.PROVIDER_NPI AS RENDERING_NPI,
       d.CALENDAR_DATE AS SERVICE_DATE, f.PROCEDURE_CD, f.PRIMARY_DX_CD, f.PLACE_OF_SERVICE_CD,
       f.UNITS, f.BILLED_AMT, f.ALLOWED_AMT, f.PAID_AMT, f.LINE_STATUS
FROM CV_&{ENV}_CORE.CLAIMS.FACT_CLAIM_LINE f
JOIN CV_&{ENV}_CORE.MEMBER.DIM_MEMBER m     ON m.MEMBER_SK = f.MEMBER_SK
JOIN CV_&{ENV}_CORE.PROVIDER.DIM_PROVIDER p ON p.PROVIDER_SK = f.RENDERING_PROVIDER_SK
JOIN CV_&{ENV}_CORE.COMMON.DIM_DATE d       ON d.DATE_SK = f.SERVICE_FROM_DATE_SK
WHERE f.LOB_CODE = 'MCD' AND f.IS_CURRENT_VERSION;
