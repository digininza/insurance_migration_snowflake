/* =============================================================================
   03_legacy_compat_views.sql — reproduce Oracle EDW table shapes so 180 Cognos
   reports and 35 extracts cut over by CONNECTION only (DATA_MODEL §5).
   Each view: legacy name, legacy column names, legacy types/code values,
   an OWNER and SUNSET date in the comment. Usage tracked via ACCESS_HISTORY.
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;

CREATE OR REPLACE VIEW CV_&{ENV}_MART.LEGACY_COMPAT.EDW_CLAIM_FACT
  COMMENT = 'Legacy EDW.CLAIM_LINE_FACT | owner: claims-reporting | sunset: 2027-06-30'
AS
SELECT f.CLAIM_ID                                   AS CLM_ID,
       f.LINE_NO                                    AS CLM_LN_NBR,
       f.CLAIM_LINE_VERSION                         AS CLM_LN_SEQ,
       IFF(f.IS_CURRENT_VERSION, 'Y', 'N')::CHAR(1) AS CURR_IND,         -- legacy CHAR(1) Y/N flags
       f.MEMBER_SK                                  AS MBR_KEY,
       f.RENDERING_PROVIDER_SK                      AS RNDR_PROV_KEY,
       f.SERVICE_FROM_DATE_SK                       AS SVC_DT_KEY,
       f.PAID_DATE_SK                               AS PD_DT_KEY,
       DECODE(f.LOB_CODE, 'COM', 'C', 'MA', 'M', 'MCD', 'D', 'U') AS LOB_CD,   -- legacy 1-char LOB codes
       f.PROCEDURE_CD                               AS PROC_CD,
       f.PRIMARY_DX_CD                              AS PRIM_DIAG_CD,
       f.LINE_STATUS                                AS LN_STAT_CD,
       f.BILLED_AMT                                 AS CHRG_AMT,
       f.ALLOWED_AMT                                AS ALWD_AMT,
       f.PAID_AMT                                   AS PD_AMT,
       f.MEMBER_LIABILITY_AMT                       AS MBR_RESP_AMT
FROM CV_&{ENV}_CORE.CLAIMS.FACT_CLAIM_LINE f;

CREATE OR REPLACE VIEW CV_&{ENV}_MART.LEGACY_COMPAT.EDW_MEMBER_DIM
  COMMENT = 'Legacy EDW.MEMBER_DIM (current rows only, as legacy did) | owner: membership-reporting | sunset: 2027-06-30'
AS
SELECT MEMBER_SK AS MBR_KEY, MEMBER_ID AS MBR_ID, SUBSCRIBER_ID AS SBSCR_ID, FIRST_NAME AS MBR_FRST_NM,
       LAST_NAME AS MBR_LST_NM, BIRTH_DT AS MBR_BRTH_DT, GENDER_CD AS MBR_GNDR_CD, ZIP5 AS MBR_ZIP_CD,
       DECODE(LOB_CODE, 'COM', 'C', 'MA', 'M', 'MCD', 'D', 'U') AS LOB_CD,
       IFF(IS_ACTIVE, 'A', 'T')::CHAR(1) AS MBR_STAT_CD
FROM CV_&{ENV}_CORE.MEMBER.DIM_MEMBER
WHERE IS_CURRENT AND MEMBER_SK <> -1;        -- masking policies still apply to PHI columns

CREATE OR REPLACE VIEW CV_&{ENV}_MART.LEGACY_COMPAT.EDW_MBR_MONTHS
  COMMENT = 'Legacy EDW.AGG_MBR_MONTHS | owner: finance | sunset: 2027-03-31'
AS
SELECT TO_NUMBER(TO_CHAR(ELIGIBILITY_MONTH, 'YYYYMM')) AS YR_MO,
       DECODE(LOB_CODE, 'COM', 'C', 'MA', 'M', 'MCD', 'D', 'U') AS LOB_CD,
       PLAN_ID AS PLN_ID, MEMBER_MONTHS AS MBR_MO_CNT
FROM CV_&{ENV}_MART.FINANCE.DT_MEMBER_MONTHS;
