# Streams + Tasks vs Dynamic Tables vs stored procedures vs MVs

We used **all four**, each where it fits. The rule of thumb we applied:

> **Imperative, stateful, must-audit → Streams + Tasks + stored procedures.**
> **Declarative, derived, "keep this result fresh" → Dynamic Tables.**

| Need | Choice | Reason |
|---|---|---|
| RAW → STAGE cleansing with quarantine of bad rows | Stream + Task + SP | Writes to **two** targets (clean + quarantine) and logs counts — DTs produce exactly one table |
| SCD2 `DIM_MEMBER`, `DIM_PROVIDER` | Stream + Task + SP (`MERGE` + insert) | SCD2 needs update-then-insert, sequence SKs, inferred-member upgrade — procedural |
| Versioned `FACT_CLAIM_LINE` with late-arriving dims | Task `AFTER` dims + SP | Order dependency + fallback SK logic + audit |
| Publish gate (block marts if feeds incomplete) | Task + SP | Control flow, not data derivation |
| Member months, PMPM, lag triangle, scorecards | **Dynamic Tables** | Pure SQL derivations over CORE; Snowflake manages incremental refresh and dependency ordering; ~60 legacy aggregate mappings became ~9 DTs |
| Simple single-table aggregate for a hot dashboard tile | (Considered **materialized view**) → DT | MVs can't join; DT covers it with one mechanism |
| Reference code-set refresh (quarterly) | Task + `COPY` | Rare, full reload |

## Streams details

- **Append-only streams on RAW** (RAW is insert-only) — cheaper, no delete tracking.
- **Standard streams on CORE dims** feed downstream extract procedures that need updates/deletes.
- **Consume in a transaction**: `BEGIN; INSERT … SELECT FROM stream; … COMMIT;` —
  the offset moves only on commit, so a failed task re-reads the same changes.
- Multiple consumers of the same RAW table → **one stream per consumer**
  (e.g. `STRM_CLAIM_LINE_STAGE`, `STRM_CLAIM_LINE_AUDIT`), because consuming
  advances the offset for everyone reading that stream.
- **Staleness**: a stream becomes stale if not consumed within the table's data
  retention (extended up to `MAX_DATA_EXTENSION_TIME_IN_DAYS`). Alert `ALR_STREAM_STALE`
  checks `SHOW STREAMS` → `stale_after` < now + 2 days. Recovery runbook: recreate
  stream + replay from RAW by `_load_ts` window.

## Tasks details

- One root task per domain DAG, `SCHEDULE = 'USING CRON 0 * * * * UTC'`; children
  with `AFTER` and `WHEN SYSTEM$STREAM_HAS_DATA()` so no warehouse resumes when
  nothing arrived (the `WHEN` is evaluated by cloud services, not the warehouse).
- **Finalizer task** (`FINALIZE = T_ROOT…`) always runs → writes run outcome to
  `CONTROL.AUDIT_LOG`, raises alert on failure.
- `SUSPEND_TASK_AFTER_NUM_FAILURES = 3`, `TASK_AUTO_RETRY_ATTEMPTS = 2`.
- Backfill DAG has **no schedule**; ADF runs `EXECUTE TASK T_ROOT_BACKFILL` after a
  wave is loaded.
- Deploy: `ALTER TASK root SUSPEND` → alter children → `SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('root')`.

## Dynamic Table details

- `TARGET_LAG = DOWNSTREAM` for intermediate DTs (refresh only when a consumer needs it).
- Leaf DTs have explicit lags matched to consumer need (1 h ops, 6 h actuarial, 1 day provider).
- Verify `REFRESH_MODE = INCREMENTAL` after deploy; functions like `CURRENT_DATE()`
  in the DT query or some window patterns force FULL → we pass dates via joins to
  `DIM_DATE` instead.
- DTs are **initialised after CORE backfill swap**, not during, to avoid refreshing
  against half-loaded history.
- Monitoring: `DYNAMIC_TABLE_REFRESH_HISTORY` → alert if `refresh_action = 'FAILED'`
  or lag breaches target by 2×.

## Why not all Dynamic Tables?

At the time of the migration DTs could not express: multi-target writes
(clean + quarantine), SCD2 with sequence-based SKs and inferred-member upgrades,
per-step audit logging, and control-flow gating. Those are exactly the pieces
ported from complex Informatica mappings, so they stayed procedural.

## Why not all Tasks + procs?

Every aggregate would need its own incremental logic, watermark and tests.
DTs gave incremental refresh and dependency management for free, and the SQL
reads like the business definition — which made **reconciliation with legacy
aggregates** far easier to reason about.
