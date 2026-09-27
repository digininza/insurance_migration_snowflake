# Cutover plan (per wave; claims wave shown)

## T-14 → T-1
- Go/No-Go criteria tracked in `CONTROL.CUTOVER_CHECKLIST` (recon exit criteria, SLA, runbooks, sign-offs).
- Freeze on legacy mapping changes (change-freeze window).
- Consumer comms: each LEGACY_COMPAT view owner confirms connection switch date.
- Pre-cutover clone: `CREATE SCHEMA CORE.CLAIMS_PRE_CUTOVER CLONE CORE.CLAIMS;`

## Cutover weekend (Sat 18:00 → Sun 22:00)

| Step | Time | Action | Owner | Rollback point |
|---|---|---|---|---|
| 1 | Sat 18:00 | Last legacy nightly completes; legacy workflows **unscheduled** (not deleted) | Legacy ops | — |
| 2 | 18:30 | Final ADF incremental; watermarks aligned to legacy last extract | DE | Watermark snapshot in `ctl.watermark_hist` |
| 3 | 19:30 | Task DAG run; publish gate green | DE | Clone `PRE_CUTOVER` |
| 4 | 20:30 | Final full recon L1–L6 for the last business date | DE + BA | — |
| 5 | 22:00 | **Go/No-Go call** | Programme lead, Finance, Actuarial | — |
| 6 | 22:30 | Switch Cognos/Power BI/extract connections to Snowflake (DNS alias + gateway config) | BI team | Revert DNS alias |
| 7 | Sun 08:00 | Smoke tests on top 20 reports, 35 extracts validated | Report owners | — |
| 8 | Sun 20:00 | Enable PROD schedules; Oracle EDW set **read-only** | DE / DBA | Re-enable legacy schedules |

## Rollback (decision deadline: Sun 22:00 + first business day 12:00)
1. Reconnect consumers to Oracle (DNS alias back).
2. Re-enable PowerCenter workflows (untouched, only unscheduled).
3. Snowflake: keep running in parallel; `SWAP WITH CLAIMS_PRE_CUTOVER` if bad data was published.
4. Incident review before retry.

## After cutover
- Hypercare 30 days, daily recon continues against **frozen legacy snapshots** for 2 weeks.
- Legacy EDW read-only for 90 days, then archived to ADLS (`archive/legacy_edw/` Parquet) for audit.
- PowerCenter licence ended; repository exported to Git for historical reference.
- Fix `LEGACY_DEFECT` items now (with business sign-off), one release at a time.
