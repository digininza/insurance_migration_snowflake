# Interview Guide — Informatica → ADF + ADLS + Snowflake (healthcare payer)

> Use this to explain the project honestly. Numbers are the project's
> illustrative assumptions; say "roughly" and be ready to explain how you'd
> measure them. Don't claim what you didn't do — see §7.

---

## 1. The 30-second version

"I worked on migrating a health insurer's legacy Informatica PowerCenter ETL and
Oracle EDW to Azure and Snowflake. We used a metadata-driven ADF framework,
first to backfill about 48 TB of history and then for watermark-based
incremental loads. ADF landed Parquet in ADLS Gen2, and Snowpipe loaded it into
Snowflake. We rebuilt the Informatica logic as ELT inside Snowflake with
Streams, Tasks, stored procedures and Dynamic Tables. Before cutover we ran the
old and new pipelines in parallel and reconciled counts, amounts, key-level
hashes, data types and business rules."

## 2. The 2-minute version (your narrative, tightened)

"In my healthcare insurance project we migrated legacy **Informatica PowerCenter**
workflows (around 420 of them) that loaded an **Oracle EDW** to **Azure Data
Factory, ADLS Gen2 and Snowflake**.

**Historical data:** we built a **metadata-driven batch framework** in ADF. A
control database held one row per source object plus a partition plan: month by
month, with claim-ID ranges for the big months. ADF copied the partitions in
parallel using dynamic-range reads, and it was restartable, so a failure only
re-ran the failed partitions. We loaded the history with **bulk COPY INTO on a
dedicated XL warehouse**, not Snowpipe, because that gave predictable
throughput for about 60,000 files.

**Ongoing loads:** **incremental extraction with watermarks** kept in control
tables. SQL Server used rowversion, and Oracle used timestamps with a small
look-back overlap. We read the new watermark before the copy and only saved it
after the copy succeeded. ADF's **Copy Activity** landed **Snappy Parquet** in
ADLS, and **Snowpipe auto-ingest** loaded it through Event Grid and a storage
queue.

**In Snowflake** we followed **ELT**. RAW kept the data as it landed. STAGE did
typing, dedup and DQ, with bad rows going to quarantine. CORE was a Kimball star
with SCD2 dimensions and versioned claim facts. MART was built on Dynamic
Tables. **Streams and Tasks** drove **stored procedures** that re-implemented the
Informatica Expression, Lookup, Router and Update Strategy logic as set-based
MERGE, and we kept every validation rule as a documented rule ID.

**Before cutover** we ran both platforms in parallel and **reconciled** daily at
six levels: row counts, amount totals, key-level hashes, data types, business
rules and report KPIs such as PMPM and member months. We cut over only after 10
straight green days and three clean month-ends, and consumers moved by changing
a connection, thanks to legacy-compatible views."

## 3. The 5-minute version — add these layers in order

1. **Why migrate:** licence and Exadata renewal, a 9-hour batch that missed its SLA about 40 % of the time, and no room for 12 years of claims.
2. **Security:** Business Critical (needed for the HIPAA BAA), Private Link, Key Vault, a storage integration with no keys, tag-based PHI masking and row access by LOB.
3. **Compute:** warehouses isolated by workload (details in §4).
4. **Hard parts:** late-arriving members (inferred rows), claim adjustments (versioned facts with negative reversals), and Oracle `''`-equals-NULL semantics.
5. **Result:** the 05:30 SLA was met, run cost was about 60 % of legacy, PHI no longer sat in test copies, and 14 % of workflows were retired.

---

## 4. The questions you will get (with answers)

### "Was it ETL or ELT? Why?"
ELT. Informatica transformed rows in its own engine. We moved all business
logic into Snowflake SQL because compute sits next to the data, it scales per
workload, raw data is kept for re-processing without re-extracting, and lineage
lives in one engine. ADF does only technical work: column projection,
Parquet typing and file trailer checks. We rejected ADF Mapping Data Flows
because they would add a second Spark engine and split the logic.
→ [HLD §2](../architecture/HLD.md), [ADR-004](../architecture/decisions/ADR-004-elt-not-etl.md)

### "How does Snowflake read ADLS? How did you handle credentials?"
A **storage integration** (`TYPE=EXTERNAL_STAGE, STORAGE_PROVIDER='AZURE'`,
allowed locations limited to the `raw/` and `recon/` containers). An Azure admin
consented to Snowflake's multi-tenant app, and we granted that service
principal *Storage Blob Data Reader*. No SAS tokens and no keys. For Snowpipe,
a **notification integration** of type Azure Storage Queue receives Event Grid
BlobCreated events. We also set `REQUIRE_STORAGE_INTEGRATION_FOR_STAGE_CREATION`
so nobody can create a stage pointing at an arbitrary URL.
→ [LLD_SNOWFLAKE §3](../architecture/LLD_SNOWFLAKE.md)

### "Where did Key Vault fit?"
- ADF's managed identity reads Key Vault. Source DB passwords, the SFTP key and the
  **Snowflake key-pair private key** are `AzureKeyVaultSecret` references, never
  inline, and CI fails if one is inline.
- **Tri-Secret Secure**: the customer-managed key for Snowflake encryption sits in Key Vault (HSM).
- Rotation uses `RSA_PUBLIC_KEY_2` for zero-downtime key-pair rotation.
→ [SECURITY_HIPAA §2](../architecture/SECURITY_HIPAA.md)

### "Which warehouses did you choose and why?"
One warehouse per workload:
- BACKFILL: XL and temporary. COPY parallelism scales with nodes.
- INGEST: XS, because Snowpipe itself is serverless.
- TRANSFORM: M, moved to L at month-end. A big MERGE needs to scale **up** for memory and to avoid spilling.
- RECON: S, isolated so reconciliation never queues behind ETL.
- BI: S with 1–4 clusters, which scales **out** for concurrency, plus Query Acceleration for outlier scans.
- ADHOC: XS with strict timeouts.

Resource monitors sit on each warehouse, but PROD ELT gets notify-only so a
quota can't stop the SLA. The rule of thumb: spilling → scale up, queuing →
scale out, poor pruning → fix the clustering or filters, not the warehouse.
→ [COMPUTE_WAREHOUSES](../architecture/COMPUTE_WAREHOUSES.md)

### "Did you build only fact/dim, or marts too?"
Both, in layers. RAW → STAGE → **CORE** (a Kimball conformed star: 8 dims with
SCD2 where needed, versioned claim-line facts, and a member-month periodic
snapshot) → **MART** (Dynamic Tables for PMPM, member months, the claims lag
triangle for IBNR, and the provider scorecard, plus secure views for MLR and
Medicaid encounters) → **LEGACY_COMPAT** views that match the old EDW table
shapes, so 180 reports cut over without a rewrite. Why not marts only?
Actuaries need atomic history. Why not the star only? Recomputing member
months on every dashboard was the biggest cost in the PoC.
→ [DATA_MODEL](../architecture/DATA_MODEL.md)

### "Streams, Tasks, Dynamic Tables — when did you use which?"
- **Streams + Tasks + procs** for procedural, stateful work: dedup with a quarantine
  table, SCD2 with sequence keys and inferred-member upgrades, versioned fact
  MERGE and the publish gate. Streams are append-only on RAW and consumed inside
  a transaction, so a failure never loses changes.
  Tasks form a DAG with `WHEN SYSTEM$STREAM_HAS_DATA`, so no warehouse spins up
  for an empty run, and a finalizer task writes the audit.
- **Dynamic Tables** for declarative aggregates. About 60 truncate-and-insert
  aggregate mappings became roughly 9 DTs. `TARGET_LAG=DOWNSTREAM` for
  intermediates, and `REFRESH_MODE=INCREMENTAL` is declared so the deploy fails
  if a DT can't refresh incrementally.
- Materialized views: not used, because they can't join.
→ [STREAMS_TASKS_DYNAMIC_TABLES](../architecture/STREAMS_TASKS_DYNAMIC_TABLES.md)

### "Where did you use zero-copy cloning?"
1. Weekly **QA refresh**: replicate PROD CORE to the NONPROD account, then clone. Masking policies travel with the clone, which fixed an audit finding about PHI in test databases.
2. **Parallel-run freeze**: `CLONE … AT(TIMESTAMP => …)` matching the moment of the legacy extract.
3. **Backfill-in-clone + `SWAP WITH`**: history was built off to the side and swapped in atomically.
4. **Pre-release snapshot** of CORE schemas for one-command rollback.
5. **Dev sandboxes** per ticket.

Watch-outs: clone storage grows as data diverges, database-level grants aren't
cloned, cloned tasks come up suspended, and cloned streams start from the
clone point.
→ [ZERO_COPY_CLONE_TIME_TRAVEL](../architecture/ZERO_COPY_CLONE_TIME_TRAVEL.md)

### "How did you handle TB scale?"
- **Extract:** partitioned dynamic-range reads, 16–32 parallel copies, SHIR scaled to 4 nodes, ExpressRoute burst, reads from AG secondaries.
- **Land:** Parquet/Snappy files of **128–256 MB**. Small files hurt Snowpipe cost; huge files hurt COPY parallelism.
- **Load:** bulk COPY on XL for history; Snowpipe for incremental.
- **Transform:**
  - Clustering `(service_month, lob_code)` on the 2.4 B-row fact only.
  - History inserted pre-sorted.
  - **MERGE bounded by `SERVICE_MONTH BETWEEN min AND max`** so the target prunes (48 min → 7 min).
  - Search Optimization for claim-ID lookups.
  - Transient STAGE.

→ [TB_SCALE_PERFORMANCE](../architecture/TB_SCALE_PERFORMANCE.md)

### "Watermark: what if a row is updated during the copy?"
Read the new watermark first and copy the range `(old, new]`. A row committed
during the copy has a higher version and comes in next run. The watermark is
saved only on success, so a failed run re-reads the same window, and
duplicates are harmless because of dedup on the version key. For deletes:
claims are soft-deleted; for members, a weekly key-only extract plus an anti-join.

### "How did you prove the new pipeline matched legacy?"
The six-level framework in §2, driven by a rule table (212 rules). The legacy
side computed aggregates and hashes **inside Oracle** and shipped small Parquet
files, not full tables. Breaks were categorised and dispositioned. Two real
examples:
- Legacy truncated 3-decimal amounts, so we saw 1-cent mismatches.
- The legacy Router silently dropped `'PAID '` rows with a trailing space.

Both were signed off as legacy defects.
→ [RECONCILIATION](../migration/RECONCILIATION.md)

### "What other cloud-native services?"
Event Grid, Storage Queue, Key Vault (HSM), managed identities, Entra ID
SSO/SCIM, Azure SQL (ADF metadata), Self-hosted IR and Managed VNet IR with
private endpoints, Azure Monitor/Log Analytics, Logic Apps (alerts), Purview
(catalog/lineage), Sentinel (SIEM), ExpressRoute, and GitHub Actions with OIDC.
On the Snowflake side: Snowpipe, Streams, Tasks, DTs, Alerts, Search
Optimization, QAS, replication/failover groups, tag-based masking and row access.
→ [CLOUD_NATIVE_SERVICES](../architecture/CLOUD_NATIVE_SERVICES.md)

### "How did you convert Informatica logic?"
An assessment tool parsed the PowerCenter XML exports, scored complexity and
assigned waves. Mapping patterns:
- Expression → SELECT expressions
- Lookup → LEFT JOIN + `QUALIFY` (to reproduce "first value")
- Router → `INSERT ALL` or a quarantine table
- Update Strategy → MERGE
- Sequence Generator → SEQUENCE
- Normalizer → UNPIVOT/FLATTEN
- SCD2 wizard → a single MERGE with a UNION ALL trick

We rewrote set-based instead of auto-converting, because row-by-row
transliterated code ran slowly and was hard to read.
→ [INFORMATICA_TO_SNOWFLAKE_MAPPING](../migration/INFORMATICA_TO_SNOWFLAKE_MAPPING.md)

---

## 5. Whiteboard drills

1. Draw the HLD ([diagram](../diagrams/01_hld.mmd)) in 90 seconds. Legacy goes on the left, and the ADF → ADLS → Snowpipe → RAW/STAGE/CORE/MART flow goes on the right.
2. Write the SCD2 MERGE with the UNION ALL null-key trick from memory ([proc](../../snowflake/06_core/04_sp_merge_dim_member_scd2.sql)).
3. Walk through the ADF watermark pipeline: activities, and what happens on failure ([diagram](../diagrams/02_adf_lld.mmd)).
4. Explain why the claims fact MERGE was slow and how pruning fixed it.

## 6. Curveballs

| Question | Good answer |
|---|---|
| "Why not Snowpipe for backfill too?" | Burst of about 60k files: latency and cost are unpredictable, and there's no control over timing. COPY on a sized warehouse is observable, and `VALIDATION_MODE` allows dry runs. |
| "Why not Databricks/Synapse?" | Team skills were SQL, one governance engine for PHI, clean workload isolation; Synapse dedicated pools needed manual scaling and concurrency slots. |
| "Snowpipe dedupe window?" | 14 days for pipe load history, 64 days for COPY metadata. Re-landing under a new path loads again, and that's by design for replays. |
| "What if the eligibility feed is late?" | Claims still load and get inferred member SKs. The publish gate blocks the finance marts because eligibility is a critical feed, and the PMPM DT is suspended so stale-but-right beats fresh-but-wrong. |
| "How do you stop a DT costing a fortune?" | Size the lag to the consumer's need, use DOWNSTREAM for intermediates, check the refresh mode, and monitor `DYNAMIC_TABLE_REFRESH_HISTORY` credits. |
| "Largest risk you saw?" | Hidden logic in SQL overrides and lookup-cache ordering. The parser flagged every override, and each one got a recon rule. |
| "Why sequences not IDENTITY?" | Usable in MERGE, explicit across clone/swap, and they mirror the Sequence Generator. Gaps are acceptable. |

## 7. Integrity notes (keep it honest)

- Volumes, costs and timings in this repo are **illustrative**. If you quote them, present them as approximate, and be ready to explain how you measured them (`QUERY_HISTORY`, `WAREHOUSE_METERING_HISTORY`).
- The code here is a reference implementation that runs offline (tests, validators and the recon engine). The Snowflake/ADF artefacts are deployable templates that need a real account to execute.
- Name your own role precisely (e.g. "I owned the ADF framework and the claims-domain procs, and co-owned reconciliation").
