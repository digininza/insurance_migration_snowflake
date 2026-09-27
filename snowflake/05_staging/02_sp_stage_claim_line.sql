/* =============================================================================
   02_sp_stage_claim_line.sql
   Replaces Informatica m_CLM_CLAIM_LINE_LOAD front half:
     SQ_CLAIM_LINE (join header) + EXP_DERIVE + FIL + RTR_VALID(valid / error)
   Pattern:
     1. BEGIN transaction; copy the stream delta into a temp table (the DML read
        is what advances the stream offset — only on COMMIT).
     2. Valid rows → STAGE.CLAIMS.CLAIM_LINE (typed, derived, deduped per batch).
        Invalid rows → QUARANTINE with a reason code (never silently dropped).
     3. COMMIT; log counts. Any error → ROLLBACK (stream not consumed) → RAISE.
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;

CREATE OR REPLACE PROCEDURE CV_&{ENV}_CONTROL.ORCHESTRATION.SP_STAGE_CLAIM_LINE(P_BATCH_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_in        NUMBER DEFAULT 0;
  v_valid     NUMBER DEFAULT 0;
  v_rejected  NUMBER DEFAULT 0;
BEGIN
  CREATE OR REPLACE TEMPORARY TABLE TMP_CLAIM_LINE_DELTA
    LIKE CV_&{ENV}_RAW.CLAIMS.CLAIM_LINE;           -- DDL outside the transaction

  BEGIN TRANSACTION;

  INSERT INTO TMP_CLAIM_LINE_DELTA
    SELECT * EXCLUDE (METADATA$ACTION, METADATA$ISUPDATE, METADATA$ROW_ID)
    FROM CV_&{ENV}_RAW.CLAIMS.STRM_CLAIM_LINE_STAGE;  -- consumes the stream on COMMIT
  v_in := SQLROWCOUNT;

  -- Valid rows (RTR_VALID.VALID group) — derive + type + dedupe (latest rowversion per version key)
  INSERT INTO CV_&{ENV}_STAGE.CLAIMS.CLAIM_LINE
  WITH hdr AS (
      SELECT CLAIM_ID, CLAIM_TYPE, MEMBER_ID, LOB_CODE, BILLING_PROVIDER_NPI, RECEIVED_DT, PAID_DT
      FROM CV_&{ENV}_CORE.CLAIMS.CLAIM_HEADER_CURRENT
  )
  SELECT :P_BATCH_ID,
         TRIM(l.CLAIM_ID), l.LINE_NO, l.CLAIM_LINE_VERSION,
         UPPER(COALESCE(NULLIF(TRIM(l.ADJUSTMENT_TYPE),''),'OR')),
         h.CLAIM_TYPE, h.MEMBER_ID, h.LOB_CODE, h.BILLING_PROVIDER_NPI,
         NULLIF(TRIM(l.RENDERING_PROVIDER_NPI),''),
         h.RECEIVED_DT, h.PAID_DT,
         l.SERVICE_FROM_DT, COALESCE(l.SERVICE_TO_DT, l.SERVICE_FROM_DT),
         DATE_TRUNC('month', l.SERVICE_FROM_DT),
         UPPER(NULLIF(TRIM(l.PROCEDURE_CD),'')), NULLIF(TRIM(l.PROCEDURE_MODIFIER),''),
         NULLIF(TRIM(l.REVENUE_CD),''), NULLIF(TRIM(l.PLACE_OF_SERVICE_CD),''),
         REPLACE(UPPER(NULLIF(TRIM(l.PRIMARY_DX_CD),'')), '.', ''),        -- legacy EXP stripped dots from ICD codes
         l.UNITS,
         -- CLM-R-017: reversal lines carry negative amounts (legacy EXP_DERIVE.o_PAID_AMT)
         IFF(l.ADJUSTMENT_TYPE = 'RV', -ABS(l.BILLED_AMT),  l.BILLED_AMT),
         IFF(l.ADJUSTMENT_TYPE = 'RV', -ABS(l.ALLOWED_AMT), l.ALLOWED_AMT),
         IFF(l.ADJUSTMENT_TYPE = 'RV', -ABS(l.PAID_AMT),    l.PAID_AMT),
         ROUND(COALESCE(l.COPAY_AMT,0) + COALESCE(l.COINSURANCE_AMT,0) + COALESCE(l.DEDUCTIBLE_AMT,0), 2)
           * IFF(l.ADJUSTMENT_TYPE = 'RV', -1, 1),
         UPPER(TRIM(l.LINE_STATUS)), NULLIF(TRIM(l.DENIAL_REASON_CD),''),
         (l.AUTO_ADJUDICATED_FLG = 'Y'),
         l.SOURCE_ROWVERSION, l.UPDATED_TS, l._FILE_NAME, CURRENT_TIMESTAMP()
  FROM TMP_CLAIM_LINE_DELTA l
  LEFT JOIN hdr h ON h.CLAIM_ID = TRIM(l.CLAIM_ID)
  WHERE l.CLAIM_ID IS NOT NULL AND l.LINE_NO IS NOT NULL AND l.CLAIM_LINE_VERSION IS NOT NULL
    AND l.SERVICE_FROM_DT IS NOT NULL
    AND h.CLAIM_ID IS NOT NULL
    AND UPPER(TRIM(l.LINE_STATUS)) IN ('PAID','DENIED','PENDED','VOID')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TRIM(l.CLAIM_ID), l.LINE_NO, l.CLAIM_LINE_VERSION
                             ORDER BY l.SOURCE_ROWVERSION DESC, l._LOAD_TS DESC, l._FILE_ROW DESC) = 1;
  v_valid := SQLROWCOUNT;

  -- Error group → quarantine with an explicit reason (legacy wrote .bad files nobody read)
  INSERT INTO CV_&{ENV}_STAGE.QUARANTINE.CLAIM_LINE_REJECT (_BATCH_ID, REJECT_REASON, RECORD, _FILE_NAME)
  SELECT :P_BATCH_ID,
         CASE WHEN l.CLAIM_ID IS NULL OR l.LINE_NO IS NULL OR l.CLAIM_LINE_VERSION IS NULL THEN 'MISSING_KEY'
              WHEN l.SERVICE_FROM_DT IS NULL THEN 'MISSING_SERVICE_DATE'
              WHEN h.CLAIM_ID IS NULL THEN 'ORPHAN_LINE_NO_HEADER'
              ELSE 'INVALID_LINE_STATUS' END,
         OBJECT_CONSTRUCT_KEEP_NULL(l.*), l._FILE_NAME
  FROM TMP_CLAIM_LINE_DELTA l
  LEFT JOIN CV_&{ENV}_CORE.CLAIMS.CLAIM_HEADER_CURRENT h ON h.CLAIM_ID = TRIM(l.CLAIM_ID)
  WHERE l.CLAIM_ID IS NULL OR l.LINE_NO IS NULL OR l.CLAIM_LINE_VERSION IS NULL
     OR l.SERVICE_FROM_DT IS NULL OR h.CLAIM_ID IS NULL
     OR UPPER(TRIM(l.LINE_STATUS)) NOT IN ('PAID','DENIED','PENDED','VOID')
     OR l.LINE_STATUS IS NULL;
  v_rejected := SQLROWCOUNT;

  COMMIT;

  CALL CV_&{ENV}_CONTROL.AUDIT.SP_LOG_BATCH(:P_BATCH_ID, 'SP_STAGE_CLAIM_LINE', 'CV_&{ENV}_STAGE.CLAIMS.CLAIM_LINE',
                                            'SUCCESS', :v_valid, 0, :v_rejected, NULL);
  RETURN OBJECT_CONSTRUCT('rows_in', v_in, 'staged', v_valid, 'quarantined', v_rejected,
                          'deduped_within_batch', v_in - v_valid - v_rejected);
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    CALL CV_&{ENV}_CONTROL.AUDIT.SP_LOG_BATCH(:P_BATCH_ID, 'SP_STAGE_CLAIM_LINE', 'CV_&{ENV}_STAGE.CLAIMS.CLAIM_LINE',
                                              'FAILED', 0, 0, 0, :SQLERRM);
    RAISE;
END;
$$;

/* Orphan lines (header not yet arrived) are quarantined with ORPHAN_LINE_NO_HEADER
   and re-driven by SP_REPLAY_ORPHAN_LINES once the header lands (runbook:
   docs/runbooks/recon_break_triage.md). Legacy silently dropped them in the
   SQ inner join — this was recon break category MISSING_IN_LEGACY in week 2. */
