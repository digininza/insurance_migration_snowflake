# TB-scale workload handling

Two different problems: a **one-time 48 TB historical backfill** and a
**recurring ~50–80 GB/day incremental** (with 5–10× spikes at open enrollment
and month-end). Each end of the pipe has its own levers.

## 1. Extract (ADF → source systems)

| Lever | What we did | Why |
|---|---|---|
| Partitioned reads | `DynamicRange` on `claim_id` (SQL Server), physical partitions (Oracle) | One Copy activity → N parallel source queries |
| Parallelism | `parallelCopies` 16–32, ForEach `batchCount` 12, per-system cap in `ctl.source_system.max_parallel_copies` | Throughput without overloading OLTP |
| SHIR scale-out | 2 → 4 nodes (8 vCPU, 32 GB) during backfill; concurrent jobs per node raised | SHIR CPU was the first bottleneck (Parquet encoding happens on SHIR) |
| Network | ExpressRoute (1 Gbps → temporary 10 Gbps burst for backfill) | 48 TB at 1 Gbps ≈ 4.5 days of pure transfer — too tight with retries |
| Source-side | Read from **read replicas / AG secondaries** for backfill; `NOLOCK` not used (dirty reads break recon) | Protect production OLTP |
| Window | Backfill outside 02:00–04:30 incremental window; throttled by schedule | DBA agreement |

## 2. Land (ADLS Gen2)

- **Parquet + Snappy**: ~6.4× smaller than source; typed columns → no string
  parsing in Snowflake; column pruning on load.
- **File size 128–256 MB** (`maxRowsPerFile` per object, tuned from row width).
  Tiny files hurt Snowpipe cost (per-file overhead) and COPY parallelism; single
  huge files can't be split across threads.
- Folder layout enables targeted replay and pattern-based COPY:
  `raw/<mode>/<system>/<object>/load_date=YYYY-MM-DD/run_id=<adf_run_id>/part-*.parquet`
  with `mode ∈ {backfill, incremental}`.
- Lifecycle: Hot 30 days → Cool 180 → Archive; `raw/` is immutable (WORM-like
  via immutability policy on `raw/backfill` until cutover sign-off).

## 3. Load (ADLS → Snowflake)

| | Backfill | Incremental |
|---|---|---|
| Mechanism | `COPY INTO` (bulk) | Snowpipe auto-ingest |
| Compute | `WH_BACKFILL` XL (user-managed) | Serverless |
| Parallelism | ~8 threads/node → XL (16 nodes) ≈ 128 files at once | Snowpipe scales automatically |
| Dedupe window | 64 days load metadata | 14 days pipe history |
| Throughput (illustrative) | ~2.5 TB/h Parquet on XL | minutes from file arrival |

Why not Snowpipe for backfill: ~60 000 files at once makes latency
unpredictable, cost is per-file + serverless compute we can't cap by size, and
we wanted to *choose* the moment of load (after a partition wave is validated).
`COPY` with `PATTERN` per wave on a known warehouse gave predictable, observable
throughput, and `VALIDATION_MODE = RETURN_ERRORS` dry runs first.

`MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE` for Parquet → schema drift-tolerant
column mapping; new source columns are added to RAW via
`ENABLE_SCHEMA_EVOLUTION = TRUE` on RAW tables (only RAW — CORE changes go through CI).

## 4. Transform at TB scale

| Technique | Where |
|---|---|
| **Backfill-in-clone + SWAP**: build CORE fact for history in a cloned schema with `WH_BACKFILL`, validate, then `ALTER TABLE … SWAP WITH` | Avoids 12 years of MERGE against a live table; atomic cutover |
| **Insert-sorted by cluster key** for history (`ORDER BY service_month, lob_code`) | Tables start well-clustered; auto-clustering cost is then small |
| **Clustering key** `(service_month, lob_code)` on `FACT_CLAIM_LINE` only | Only table where depth mattered (2.4 B rows, range filters); others rely on natural load order |
| **Incremental MERGE bounded by partition**: `MERGE … ON t.claim_id = s.claim_id AND t.service_month BETWEEN :min AND :max` | Pruning on target side of MERGE — the biggest single win (scan 3 % instead of 100 %) |
| Streams (only changed rows) | Never re-read RAW |
| Dynamic Tables with incremental refresh | Aggregates update from deltas |
| Search Optimization (point lookups) | claim_id / member_id lookups |
| Avoid `SELECT *` + `ORDER BY` in views; avoid UDFs in join predicates | Pruning + parallelism |
| Transient STAGE | No Fail-safe storage for 7 days × daily churn |

## 5. Evidence we looked at (how we proved it)

```sql
-- Pruning on the big fact
SELECT query_id, partitions_scanned, partitions_total,
       bytes_spilled_to_local_storage, bytes_spilled_to_remote_storage
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_text ILIKE '%FACT_CLAIM_LINE%' AND start_time > DATEADD(day,-1,CURRENT_TIMESTAMP());

SELECT SYSTEM$CLUSTERING_INFORMATION('CORE.CLAIMS.FACT_CLAIM_LINE','(service_month, lob_code)');
```

| Before → after (illustrative) | |
|---|---|
| Daily claim MERGE | 48 min on L → **7 min on M** after target-side pruning + clustering |
| PMPM dashboard | 38 s → **1.2 s** via Dynamic Table + result cache |
| Backfill total | 19 days elapsed (incl. 2 re-runs of failed partitions) |

## 6. Spikes (open enrollment, month-end)

- ADF: per-object `priority` → claims & eligibility first; batchCount raised via
  pipeline parameter, not code change.
- Snowflake: month-end task scales `WH_TRANSFORM` to L at 00:00 on day 1 and back
  at 08:00; BI multi-cluster absorbs report storms.
