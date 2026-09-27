# Runbook — Time Travel recovery

1. Identify the bad statement: `QUERY_HISTORY` filtered by table + time; get `QUERY_ID`.
2. Inspect: `SELECT … FROM CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE BEFORE (STATEMENT => '<qid>') WHERE …;`
3. Restore by clone + swap (fast, atomic):
   ```sql
   CREATE TABLE CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE_RESTORE CLONE CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE BEFORE (STATEMENT => '<qid>');
   ALTER TABLE CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE SWAP WITH CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE_RESTORE;
   ```
4. Re-apply legitimate batches after the restore point (STAGE ≤ 3 days, else RAW by `_LOAD_TS`).
5. Check policies still attached: `SELECT * FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(REF_ENTITY_NAME=>'CV_PROD_CORE.CLAIMS.FACT_CLAIM_LINE', REF_ENTITY_DOMAIN=>'table'));`
6. Dropped object: `UNDROP TABLE|SCHEMA|DATABASE …` (within retention). Beyond 30 days: Fail-safe (Snowflake support, 7 days).
