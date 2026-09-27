# Compute — which warehouses we chose and why

Principle: **one warehouse per workload**, not per team. Workloads differ in
shape (bulk load vs MERGE vs many small BI queries), so each gets the size,
scaling policy and suspend setting that fits. Sizes below are PROD; DEV/QA are
XS with max-cluster 1. Credits are illustrative (Business Critical, Azure).

| Warehouse | Size | Clusters | Auto-suspend | Workload | Why this setting |
|---|---|---|---|---|---|
| `WH_BACKFILL` | **XLARGE** (temporary) | 1 | 60 s | Historical bulk `COPY INTO` + backfill MERGE | COPY parallelism scales with nodes × threads — XL loads ~128 files in parallel. Scale **up** for throughput; created for the backfill weeks, then set to XS/dropped. |
| `WH_INGEST` | XSMALL | 1 | 60 s | Small task-driven COPYs (reference files), replay procs | Snowpipe is **serverless** (no warehouse). This is only for the non-pipe loads. |
| `WH_TRANSFORM` | **MEDIUM** (→ LARGE at month-end via task) | 1 | 60 s | Task DAG stored procs (MERGE, SCD2), Dynamic Table refresh | MERGE of 10 M lines into 2.4 B-row fact is a single big query → needs **scale-up** (memory, no spilling), not more clusters. Month-end task `ALTER WAREHOUSE … SET WAREHOUSE_SIZE='LARGE'` then back. |
| `WH_RECON` | SMALL | 1 | 60 s | Legacy-vs-new reconciliation, DQ | Isolated so parallel-run recon never queues behind ETL, and its cost is visible separately. |
| `WH_BI` | SMALL | **1–4 multi-cluster**, `STANDARD` | 300 s | Power BI (DirectQuery/import refresh), Cognos compat | Many concurrent small queries → **scale out** (clusters), not up. Longer suspend keeps local SSD cache warm. **QAS** enabled (scale factor 8) for occasional big scans. |
| `WH_DATASCIENCE` | MEDIUM | 1 | 60 s | Actuarial/Snowpark notebooks | Heavy but bursty; own resource monitor. |
| `WH_ADHOC` | XSMALL | 1 | 60 s | Engineers/analysts exploration | `STATEMENT_TIMEOUT_IN_SECONDS=900` to stop runaway queries. |
| `WH_CICD` | XSMALL | 1 | 60 s | Deployments, tests | Cheap, isolated from PROD workloads. |

## Decision rules we used

| Symptom (Query Profile / `WAREHOUSE_LOAD_HISTORY`) | Action |
|---|---|
| "Bytes spilled to local/remote storage" | Scale **up** one size (more memory per node) |
| High `QUEUED_LOAD` with many concurrent queries | Scale **out** (max clusters) — BI only |
| One occasional huge scan in BI | Query Acceleration Service instead of permanent upsizing |
| Low utilisation, frequent resume | Merge small workloads, lower size, keep auto-suspend 60 s |
| Partitions scanned ≈ partitions total on big fact | Fix pruning (clustering key / filter), not the warehouse |

**Why not one big shared warehouse?** Backfill would starve dashboards; month-end
MERGE would queue BI; and cost attribution per workload would be impossible.

**Why not Snowpark-optimized warehouses?** No memory-heavy Python/ML in the
pipeline; standard warehouses suffice. **Why not serverless for everything?**
Serverless tasks are great for tiny control tasks (we use them), but for the
big predictable MERGEs a user-managed warehouse is cheaper and we can size it.

## Guard-rails

- **Resource monitors**: account-level monthly quota; per-warehouse monitors
  (notify 75 %, 90 %; suspend at 100 % for ADHOC/DATASCIENCE; notify-only for
  TRANSFORM/BI so PROD SLAs never get cut off by a quota).
- `STATEMENT_QUEUED_TIMEOUT_IN_SECONDS` on BI, statement timeouts everywhere.
- Weekly cost review from `WAREHOUSE_METERING_HISTORY` + `QUERY_ATTRIBUTION_HISTORY`
  (see `snowflake/12_monitoring`).

## Illustrative cost profile (steady state, PROD)

| Workload | Credits/day | Note |
|---|---|---|
| Snowpipe (serverless) | ~6 | ~12 000 files/day, per-file overhead kept low by 128–256 MB files |
| WH_TRANSFORM (M, ~5 h/day) | ~20 | incl. DT refresh |
| WH_BI (S, 1–4 clusters, ~14 h) | ~40 | largest line; QAS avoided upsizing to M |
| WH_RECON / ADHOC / CICD | ~8 | |
| **Total** | **~74** | vs backfill peak ~200/day for 3 weeks on XL |
