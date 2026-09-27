/* =============================================================================
   recon_legacy_queries.sql — rows for ctl.recon_legacy_query (Oracle SQL run
   against the LEGACY EDW by PL_41). Output columns must match
   CV_<ENV>_CONTROL.RECON.LEGACY_METRIC. ':BD' is replaced with DATE 'yyyy-mm-dd'.
   Grain key format must equal the Snowflake NEW_SQL format exactly.
   ============================================================================= */
INSERT INTO ctl.recon_legacy_query (rule_id, legacy_sql) VALUES
('RC-L1-001', 'SELECT :BD AS BUSINESS_DATE, ''CLAIM_LINE_FACT'' AS TABLE_NAME, ''ROW_COUNT_BY_LOB_TYPE_MONTH'' AS METRIC_NAME,
                      LOB_CD || ''|'' || CLM_TYP_CD || ''|'' || TO_CHAR(SVC_MO, ''YYYY-MM'') AS GRAIN_KEY,
                      TO_CHAR(COUNT(*)) AS METRIC_VALUE, SYSTIMESTAMP AS EXTRACTED_AT
               FROM EDW.CLAIM_LINE_FACT WHERE RCVD_DT <= :BD GROUP BY LOB_CD, CLM_TYP_CD, SVC_MO'),
('RC-L2-001', 'SELECT :BD, ''CLAIM_LINE_FACT'', ''PAID_AMT_BY_LOB_TYPE_MONTH'',
                      LOB_CD || ''|'' || CLM_TYP_CD || ''|'' || TO_CHAR(SVC_MO, ''YYYY-MM''),
                      TO_CHAR(SUM(PD_AMT), ''FM999999999999990.00''), SYSTIMESTAMP
               FROM EDW.CLAIM_LINE_FACT WHERE RCVD_DT <= :BD GROUP BY LOB_CD, CLM_TYP_CD, SVC_MO'),
('RC-L3-001', 'SELECT :BD, ''CLAIM_LINE_FACT'', ''KEY_HASH_RECEIVED_ON_BD'',
                      CLM_ID || ''|'' || CLM_LN_NBR || ''|'' || CLM_LN_SEQ,
                      LOWER(STANDARD_HASH(TO_CHAR(CHRG_AMT,''FM999999999999990.00'') || ''|'' || TO_CHAR(ALWD_AMT,''FM999999999999990.00'')
                            || ''|'' || TO_CHAR(PD_AMT,''FM999999999999990.00'') || ''|'' || LN_STAT_CD, ''MD5'')), SYSTIMESTAMP
               FROM EDW.CLAIM_LINE_FACT WHERE RCVD_DT = :BD'),
('RC-L6-001', 'SELECT :BD, ''AGG_MBR_MONTHS'', ''MEMBER_MONTHS_BY_LOB_MONTH'',
                      LOB_CD || ''|'' || SUBSTR(TO_CHAR(YR_MO), 1, 4) || ''-'' || SUBSTR(TO_CHAR(YR_MO), 5, 2),
                      TO_CHAR(SUM(MBR_MO_CNT)), SYSTIMESTAMP
               FROM EDW.AGG_MBR_MONTHS WHERE YR_MO <= TO_NUMBER(TO_CHAR(:BD, ''YYYYMM'')) GROUP BY LOB_CD, YR_MO');
