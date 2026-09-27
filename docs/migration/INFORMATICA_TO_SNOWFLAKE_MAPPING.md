# Informatica PowerCenter → Snowflake conversion patterns

How each PowerCenter concept was re-implemented. Worked example at the end:
`m_CLM_CLAIM_LINE_LOAD` (the XML is in [`informatica_legacy/exports/`](../../informatica_legacy/exports/)).

## 1. Transformations

| PowerCenter | Target implementation | Notes / gotchas |
|---|---|---|
| **Source Qualifier** (+ filter, SQL override) | ADF Copy source query (projection + watermark filter only). Joins/filters from overrides move to STAGE SQL | Keep extraction dumb; business filters belong in Snowflake so they're re-runnable |
| **Expression** | Column expressions in the `SELECT` of the STAGE proc | `IIF`→`IFF`, `DECODE`→`DECODE`/`CASE`, `LTRIM/RTRIM`→`TRIM`, `TO_DATE(x,'YYYYMMDD')`→`TRY_TO_DATE`, `IS_SPACES`→`TRIM(x)=''`, `ISNULL`→`IS NULL` |
| **Filter** | `WHERE` | Informatica filter drops rows silently → we **count** them into `CTL_BATCH_RUN.rows_filtered` |
| **Router** | `CASE` flag + multiple `INSERT`s from one CTE, or `INSERT ALL WHEN … THEN INTO …` (multi-table insert) | Error group → `QUARANTINE` table with reason code |
| **Lookup (connected)** | `LEFT JOIN` | Informatica returns **first/last/any** match on duplicates — replicate with `QUALIFY ROW_NUMBER()`; else joins multiply rows |
| **Lookup (unconnected, `:LKP.`)** | Scalar subquery / `LEFT JOIN` to a CTE | Often used for SK lookups with default `-1` → `COALESCE(d.member_sk, -1)` |
| **Dynamic / persistent lookup cache** | Not needed; SQL join against the table itself | Dynamic cache (insert-else-update in one run) → `MERGE` after dedupe in source CTE |
| **Joiner** | `JOIN` | Master/detail outer types map to `LEFT/RIGHT/FULL` — check which side is "master" |
| **Aggregator** | `GROUP BY` | Non-aggregated ports return **last row** in Informatica → make explicit `ANY_VALUE` or `MAX_BY(col, order_col)` |
| **Sorter** | `ORDER BY` only where order matters (e.g. `QUALIFY`) | Distinct option → `SELECT DISTINCT` |
| **Rank** | `QUALIFY RANK()/ROW_NUMBER() OVER (PARTITION BY … ORDER BY …) <= n` | |
| **Normalizer** (COBOL/occurs) | `LATERAL FLATTEN` or `UNPIVOT` | Diagnosis codes 1–12 columns → rows in `FACT_CLAIM_DIAGNOSIS` |
| **Union** | `UNION ALL` | |
| **Sequence Generator** | `SEQUENCE` object (`SEQ_MEMBER_SK.NEXTVAL`) | Gaps are fine; never rely on contiguity. Not `IDENTITY` (see DATA_MODEL) |
| **Update Strategy** (`DD_INSERT/UPDATE/DELETE/REJECT`) | `MERGE … WHEN MATCHED AND … THEN UPDATE / DELETE WHEN NOT MATCHED THEN INSERT` | `DD_REJECT` → quarantine insert |
| **SCD Type 2 wizard** | Stream + SP: `MERGE` to expire changed rows (hash diff) + `INSERT` new versions | See `SP_MERGE_DIM_MEMBER` |
| **Stored Procedure transformation** | Inline SQL or Snowflake proc | Oracle PL/SQL rewritten; packages flattened |
| **Java / Custom transformation** | Snowflake SQL UDF / Python UDF (rare) | 3 cases in claims (NPI Luhn check → SQL UDF) |
| **Mapplet** | SQL view or UDF reused by procs | e.g. `mplt_ADDR_STANDARDIZE` → `UDF_STD_ZIP` |
| **Transaction Control** | Explicit `BEGIN … COMMIT` in the proc | |
| **XML Parser / Generator** | `PARSE_XML`, `XMLGET` / `OBJECT_CONSTRUCT` | Only the provider directory feed |

## 2. Workflow/session concepts

| PowerCenter | Target |
|---|---|
| Workflow | ADF master pipeline (extract) + Snowflake Task DAG (transform) |
| Session | ADF Copy activity (extract) or one task/proc (transform) |
| Worklet | Child ADF pipeline or task sub-graph |
| Parameter file (`$$LAST_EXTRACT_DT`) | `ctl.watermark` + pipeline parameters |
| Mapping variable (`SETMAXVARIABLE`) | Watermark update stored procedure after success |
| Event-Wait (file watch) | Storage event trigger / Event Grid → Snowpipe |
| Decision / Link conditions | ADF If Condition / task `WHEN` + `SP_PUBLISH_GATE` |
| Email task | Logic App via `PL_90_Send_Alert`, Snowflake Alerts |
| Session log / reject (bad) file | `CTL_BATCH_RUN`, `QUARANTINE` tables, `COPY_HISTORY`, `VALIDATE()` |
| Commit interval / bulk mode | Irrelevant — single set-based statement, atomic |
| Pushdown optimization | Default behaviour now: everything runs in Snowflake |
| Deployment groups | Git + CI/CD (ADF ARM + SQL manifest) |
| Repository Manager lineage | Purview + `ACCESS_HISTORY`/`OBJECT_DEPENDENCIES` + [LINEAGE.md](../LINEAGE.md) |

## 3. Semantics that caused real breaks (and fixes)

| Legacy behaviour | Break seen in recon | Fix |
|---|---|---|
| Oracle `''` = NULL | Counts of "missing middle name" differed by 1.2 M | `NULLIF(TRIM(col),'')` in STAGE |
| Informatica rounds decimals at port precision (`decimal(15,2)`) at each step | Paid totals off by cents on multi-step allocations | Round at the same step as legacy; recon tolerance 0.00 at line, 0.00 at total |
| Aggregator returns last row for non-grouped ports | Different provider specialty on 0.3 % of scorecard rows | `MAX_BY(specialty, effective_from)` |
| Lookup "use first value" on duplicate cache rows | Different plan on members with overlapping spans | Deterministic `QUALIFY` with same order as legacy cache ORDER BY override |
| Oracle `DATE` includes time; mapping truncated via `TRUNC` | Off-by-one day for claims received near midnight UTC | Convert in source TZ before truncation |
| Router default group dropped rows silently | New platform had 18 k "extra" rows | Rows were legitimately rejected by legacy → documented as rule, reproduced |

## 4. Worked example — `m_CLM_CLAIM_LINE_LOAD`

Legacy: `SQ_CLAIM_LINE` (override with join to header, `$$LAST_EXTRACT_DT`) →
`EXP_DERIVE` (IIF on status, amounts rounding, `TO_DATE`) → `LKP_MEMBER_SK`
(unconnected, default -1) → `LKP_PROVIDER_SK` → `RTR_VALID` (valid / error) →
`UPD_CLAIM` (DD_UPDATE if exists else DD_INSERT) → `EDW.CLAIM_LINE_FACT`;
error group → `EDW.CLAIM_LINE_ERR`.

Target:
1. ADF `PL_11_Copy_Object_Incremental` extracts `claim_line` and `claim_header`
   separately (no join in source) with `rowversion` watermark → Parquet.
2. Snowpipe → `RAW.CLAIMS.CLAIM_LINE`, `RAW.CLAIMS.CLAIM_HEADER`.
3. `SP_STAGE_CLAIM_LINE` = SQ join + EXP + RTR (valid → `STAGE`, error → `QUARANTINE`).
4. `SP_MERGE_FACT_CLAIM_LINE` = LKPs + UPD → `CORE.CLAIMS.FACT_CLAIM_LINE`.

See [`snowflake/05_staging/`](../../snowflake/05_staging) and [`snowflake/06_core/`](../../snowflake/06_core).
