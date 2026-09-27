# Runbook — reconciliation break triage

```sql
SELECT * FROM CV_PROD_CONTROL.RECON.V_RECON_SCORECARD WHERE BUSINESS_DATE = :bd AND BREAKS > 0;
SELECT * FROM CV_PROD_CONTROL.RECON.RECON_RESULT
WHERE BUSINESS_DATE = :bd AND STATUS <> 'MATCH' AND CRITICALITY = 'CRITICAL' ORDER BY RECON_LEVEL, RULE_ID LIMIT 200;
```

1. Start at the **lowest level**: L1 count breaks explain most L2/L6 breaks.
2. For an L2/L6 grain break, drill to L3 keys in that grain (same LOB|type|month).
3. Pull both rows: legacy via `PL_41` ad-hoc query, new from `FACT_CLAIM_LINE` + `_FILE_NAME` lineage.
4. Classify: see categories in [RECONCILIATION.md §4](../migration/RECONCILIATION.md).
5. Record disposition:
```sql
UPDATE CV_PROD_CONTROL.RECON.RECON_RESULT
   SET DISPOSITION = 'LEGACY_DEFECT', DISPOSITION_BY = CURRENT_USER(), DISPOSITION_NOTE = 'L-DEF-1 router default group'
 WHERE RUN_ID = :run AND RULE_ID = 'RC-L3-001' AND STATUS = 'MISSING_IN_LEGACY';
```
6. `LEGACY_DEFECT` needs data-owner sign-off in `CUTOVER_CHECKLIST` before it stops counting as open.
