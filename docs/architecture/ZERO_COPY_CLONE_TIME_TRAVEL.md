# Zero-copy cloning & Time Travel — how the migration used them

A clone is a metadata operation: the new object points at the same
micro-partitions; storage is only paid for partitions that change afterwards.
That made five migration activities cheap and fast. Scripts:
[`snowflake/11_clone_timetravel/`](../../snowflake/11_clone_timetravel).

## 1. QA / UAT environment refresh (weekly)

PROD and NONPROD are separate accounts (ADR-003), and a clone can't cross
accounts. So CORE is **replicated** once to NONPROD as a read-only secondary
(`CV_PROD_CORE_REPLICA`, refreshed weekly), and QA is a **clone of the replica**:
```sql
-- in NONPROD account
ALTER DATABASE CV_PROD_CORE_REPLICA REFRESH;                          -- replication
CREATE OR REPLACE DATABASE CV_QA_CORE CLONE CV_PROD_CORE_REPLICA;     -- seconds, ~0 extra storage
```
- Masking and row access policies are carried with the clone (they reference
  the governance database), so QA testers see masked PHI — fixing the legacy
  HIPAA audit finding about PHI in test schemas.
- Grants: `CLONE` copies child-object grants but not the database's own grants →
  post-clone script re-applies QA roles.

## 2. Parallel-run freeze for reconciliation

At each parallel-run checkpoint (month-end close), we froze the new platform
at the exact moment the legacy EDW extract was taken:
```sql
CREATE SCHEMA CV_PROD_CONTROL.RECON_SNAP_20260531 CLONE CV_PROD_CORE.CLAIMS
  AT (TIMESTAMP => '2026-06-01 05:30:00'::TIMESTAMP_LTZ);
```
Recon then ran against a stable snapshot while daily loads continued.

## 3. Backfill-in-clone + atomic SWAP

```sql
CREATE TABLE CORE.CLAIMS.FACT_CLAIM_LINE_BF CLONE CORE.CLAIMS.FACT_CLAIM_LINE;  -- empty structure + grants
-- load 12 years into _BF with WH_BACKFILL, validate recon ...
ALTER TABLE CORE.CLAIMS.FACT_CLAIM_LINE SWAP WITH CORE.CLAIMS.FACT_CLAIM_LINE_BF;
```
Readers never see a half-loaded table; rollback = swap back.

## 4. Pre-release snapshot (rollback point)

Before every release that alters CORE (DDL or logic change):
```sql
CREATE SCHEMA CORE.CLAIMS_PRE_R27 CLONE CORE.CLAIMS;
```
If the release corrupts data: `ALTER SCHEMA CORE.CLAIMS SWAP WITH CORE.CLAIMS_PRE_R27`
(then replay streams from RAW). Snapshots dropped after 7 days.

## 5. Dev sandboxes for engineers

`CREATE SCHEMA DEV_CORE.CLAIMS_JIRA1234 CLONE CV_QA_CORE.CLAIMS;` — test a mapping
rewrite on realistic volume without copying data.

## Time Travel

| Object | `DATA_RETENTION_TIME_IN_DAYS` (PROD) | Why |
|---|---|---|
| RAW | 1 | Re-loadable from ADLS |
| STAGE (transient) | 1 | Short-lived batches; 1 day (not 0) because STAGE tables carry streams feeding CORE |
| CORE | 30 | Recovery window for bad MERGEs, point-in-time recon |
| MART (DTs) | 1 | Re-derivable |
| CONTROL | 30 | Audit |

Typical uses: `SELECT … AT(OFFSET => -3600)` to diff a bad load;
`CREATE TABLE … CLONE … BEFORE(STATEMENT => '<query_id>')` to restore;
`UNDROP TABLE`. Runbook: [`docs/runbooks/time_travel_recovery.md`](../runbooks/time_travel_recovery.md).

## Cost watch-outs

- Clones that live long and diverge stop being "free" — `TABLE_STORAGE_METRICS`
  (`RETAINED_FOR_CLONE_BYTES`) reviewed weekly; stale snapshots dropped.
- High-churn tables × long Time Travel = storage cost → STAGE transient, CORE 30 d.
- A cloned table keeps its **clustering key**. Streams inside a cloned
  database/schema are cloned, but changes they had not consumed yet are
  **not available** in the clone — the cloned streams start from the clone point.
- Tasks in a cloned database/schema are cloned **suspended** — QA DAGs are
  resumed explicitly by the refresh script.
