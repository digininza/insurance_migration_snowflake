/* =============================================================================
   04_sp_merge_dim_member_scd2.sql — SCD Type 2 for DIM_MEMBER
   Replaces Informatica m_MBR_MEMBER_SCD2 (LKP_DIM_MEMBER + EXP_DETECT_CHANGE +
   RTR_NEW_CHANGED + UPD_EXPIRE + UPD_INSERT + SEQ_MEMBER_SK) with ONE MERGE:

   The source is UNION ALL of
     (a) every staged member keyed by MEMBER_ID      → matches current row → expire it
                                                       or (new member) → insert
     (b) changed members again with a NULL merge key  → never matches → insert new version
   Inferred members (created by the claims load for late-arriving members) are
   upgraded IN PLACE so facts already pointing at their SK stay valid.
   ============================================================================= */
USE ROLE &{ENV}_SR_CICD;

CREATE OR REPLACE PROCEDURE CV_&{ENV}_CONTROL.ORCHESTRATION.SP_MERGE_DIM_MEMBER(P_BATCH_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_ins NUMBER DEFAULT 0;
  v_upd NUMBER DEFAULT 0;
BEGIN
  CREATE OR REPLACE TEMPORARY TABLE TMP_MEMBER_SRC LIKE CV_&{ENV}_STAGE.MEMBERSHIP.MEMBER;

  BEGIN TRANSACTION;
  -- consume STAGE stream; keep latest per member across any accumulated batches
  INSERT INTO TMP_MEMBER_SRC
  SELECT * EXCLUDE (METADATA$ACTION, METADATA$ISUPDATE, METADATA$ROW_ID)
  FROM CV_&{ENV}_STAGE.MEMBERSHIP.STRM_STG_MEMBER_CORE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY MEMBER_ID ORDER BY SOURCE_UPDATED_TS DESC, _STAGED_AT DESC) = 1;

  MERGE INTO CV_&{ENV}_CORE.MEMBER.DIM_MEMBER t
  USING (
      SELECT s.MEMBER_ID AS MERGE_KEY, s.* FROM TMP_MEMBER_SRC s
      UNION ALL
      SELECT NULL AS MERGE_KEY, s.*
      FROM TMP_MEMBER_SRC s
      JOIN CV_&{ENV}_CORE.MEMBER.DIM_MEMBER d
        ON d.MEMBER_ID = s.MEMBER_ID AND d.IS_CURRENT AND NOT d.IS_INFERRED
       AND d.ROW_HASH <> s.ROW_HASH
       AND s.SOURCE_UPDATED_TS >= d.EFFECTIVE_FROM          -- ignore out-of-order older versions
  ) s
  ON t.MEMBER_ID = s.MERGE_KEY AND t.IS_CURRENT
  -- inferred placeholder → becomes the real first version, same SK
  WHEN MATCHED AND t.IS_INFERRED THEN UPDATE SET
       SUBSCRIBER_ID = s.SUBSCRIBER_ID, RELATIONSHIP_CD = s.RELATIONSHIP_CD, FIRST_NAME = s.FIRST_NAME,
       LAST_NAME = s.LAST_NAME, BIRTH_DT = s.BIRTH_DT, GENDER_CD = s.GENDER_CD, SSN = s.SSN,
       ADDRESS_LINE1 = s.ADDRESS_LINE1, CITY = s.CITY, STATE_CD = s.STATE_CD, ZIP5 = s.ZIP5, PHONE = s.PHONE,
       EMAIL = s.EMAIL, GROUP_ID = s.GROUP_ID, LOB_CODE = s.LOB_CODE, PCP_NPI = s.PCP_NPI, IS_ACTIVE = s.IS_ACTIVE,
       ROW_HASH = s.ROW_HASH, IS_INFERRED = FALSE, _BATCH_ID = :P_BATCH_ID, _UPDATED_AT = CURRENT_TIMESTAMP()
  -- changed → expire current version
  WHEN MATCHED AND t.ROW_HASH <> s.ROW_HASH AND s.SOURCE_UPDATED_TS >= t.EFFECTIVE_FROM THEN UPDATE SET
       EFFECTIVE_TO = s.SOURCE_UPDATED_TS, IS_CURRENT = FALSE, _BATCH_ID = :P_BATCH_ID, _UPDATED_AT = CURRENT_TIMESTAMP()
  -- new member, or new version of a changed member
  WHEN NOT MATCHED THEN INSERT
       (MEMBER_SK, MEMBER_ID, SUBSCRIBER_ID, RELATIONSHIP_CD, FIRST_NAME, LAST_NAME, BIRTH_DT, GENDER_CD, SSN,
        ADDRESS_LINE1, CITY, STATE_CD, ZIP5, PHONE, EMAIL, GROUP_ID, LOB_CODE, PCP_NPI, IS_ACTIVE, IS_INFERRED,
        ROW_HASH, EFFECTIVE_FROM, EFFECTIVE_TO, IS_CURRENT, _BATCH_ID)
       VALUES (CV_&{ENV}_CORE.COMMON.SEQ_MEMBER_SK.NEXTVAL, s.MEMBER_ID, s.SUBSCRIBER_ID, s.RELATIONSHIP_CD,
               s.FIRST_NAME, s.LAST_NAME, s.BIRTH_DT, s.GENDER_CD, s.SSN, s.ADDRESS_LINE1, s.CITY, s.STATE_CD,
               s.ZIP5, s.PHONE, s.EMAIL, s.GROUP_ID, s.LOB_CODE, s.PCP_NPI, s.IS_ACTIVE, FALSE, s.ROW_HASH,
               s.SOURCE_UPDATED_TS, '9999-12-31'::TIMESTAMP_NTZ, TRUE, :P_BATCH_ID);
  SELECT "number of rows inserted", "number of rows updated" INTO :v_ins, :v_upd FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
  COMMIT;

  CALL CV_&{ENV}_CONTROL.AUDIT.SP_LOG_BATCH(:P_BATCH_ID, 'SP_MERGE_DIM_MEMBER', 'CV_&{ENV}_CORE.MEMBER.DIM_MEMBER',
                                            'SUCCESS', :v_ins, :v_upd, 0, NULL);
  RETURN OBJECT_CONSTRUCT('inserted_versions', v_ins, 'expired_or_upgraded', v_upd);
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    CALL CV_&{ENV}_CONTROL.AUDIT.SP_LOG_BATCH(:P_BATCH_ID, 'SP_MERGE_DIM_MEMBER', 'CV_&{ENV}_CORE.MEMBER.DIM_MEMBER',
                                              'FAILED', 0, 0, 0, :SQLERRM);
    RAISE;
END;
$$;

/* Post-conditions checked by DQ/recon rule MBR-R-009:
   - exactly one IS_CURRENT row per MEMBER_ID
   - no overlapping [EFFECTIVE_FROM, EFFECTIVE_TO) per MEMBER_ID
   SELECT MEMBER_ID FROM CV_PROD_CORE.MEMBER.DIM_MEMBER WHERE IS_CURRENT GROUP BY 1 HAVING COUNT(*) > 1; */
