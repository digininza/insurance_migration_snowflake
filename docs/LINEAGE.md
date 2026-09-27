# Lineage — source → report, and legacy object → new object

## 1. Run-level lineage (every row can be traced)

| Column | Set by | Answers |
|---|---|---|
| ADF `pipeline().RunId` in folder `run_id=` | ADF Copy sink path | Which extract produced this file |
| `_FILE_NAME`, `_FILE_ROW`, `_FILE_LAST_MODIFIED`, `_LOAD_TS` | Snowpipe/COPY `INCLUDE_METADATA` | Which file/row a RAW record came from, when loaded |
| `SOURCE_ROWVERSION` / `UPDATED_TS` | Source | Which source version |
| `_BATCH_ID` (task graph run id) | Stage/Core procs | Which DAG run staged/merged it |
| `AUDIT_BATCH_LOG` | `SP_LOG_BATCH`, finalizer | Row counts in/out/rejected per step |
| `CTL_ADF_RUN_LOG` + `CTL_FEED_STATUS` | ADF → `SP_ADF_LOG_RUN` | Watermark range per extract |
| `ACCESS_HISTORY` | Snowflake | Who read which column (PHI audit) |

Trace a suspicious PMPM number: `DT_PMPM_BY_LOB_MONTH` → `DT_CLAIMS_COST_MONTHLY` →
`FACT_CLAIM_LINE._BATCH_ID` → `AUDIT_BATCH_LOG` → `STAGE…_FILE_NAME` →
ADLS `raw/incremental/claims/claim_line/load_date=…/run_id=…` → `CTL_ADF_RUN_LOG`
old/new watermark → source rows.

## 2. Object lineage (legacy → new)

| Legacy (Informatica / Oracle EDW) | New (Snowflake) | Notes |
|---|---|---|
| `wf_CLM_DAILY_CLAIMS / m_CLM_CLAIM_LINE_LOAD` | `PL_11` (CLM_HDR, CLM_LINE) → `PIPE_CLAIM_*` → `SP_MERGE_CLAIM_HEADER`, `SP_STAGE_CLAIM_LINE`, `SP_MERGE_FACT_CLAIM_LINE` | SQ join moved out of the source query |
| `EDW.CLAIM_LINE_FACT` | `CORE.CLAIMS.FACT_CLAIM_LINE` (+ `LEGACY_COMPAT.EDW_CLAIM_FACT`) | |
| `EDW.CLAIM_LINE_ERR` / `.bad` files | `STAGE.QUARANTINE.CLAIM_LINE_REJECT` | Reason codes; orphans auto-replayed |
| `m_CLM_DIAG_NORMALIZE` (Normalizer DX1–DX12) | Source already normalized → `FACT_CLAIM_DIAGNOSIS` | |
| `m_CLM_AGG_DENIAL_DAILY` (truncate/insert) | `MART.CLAIMS.DT_DENIAL_RATE_DAILY` | Dynamic Table, 1 h lag |
| `wf_MBR_MEMBERSHIP / m_MBR_MEMBER_SCD2` | `SP_STAGE_MEMBER` + `SP_MERGE_DIM_MEMBER` | Single MERGE SCD2, inferred-member upgrade |
| `EDW.MEMBER_DIM` | `CORE.MEMBER.DIM_MEMBER` (+ `LEGACY_COMPAT.EDW_MEMBER_DIM`) | PHI masked by tag |
| `m_ELG_MBR_MONTHS` → `EDW.AGG_MBR_MONTHS` | `SP_MERGE_FACT_ELIGIBILITY_MONTH` → `FACT_ELIGIBILITY_MONTH` → `DT_MEMBER_MONTHS` (+ `EDW_MBR_MONTHS`) | 15th-of-month rule ELG-R-001 |
| `mplt_ADDR_STANDARDIZE` | STAGE expressions (ZIP5, INITCAP) | |
| `SP_GET_PCP` (PL/SQL) | `PCP_NPI` extracted directly from source column | Package logic simplified after analysis |
| Parameter files `$$LAST_EXTRACT_DT` | `ctl.watermark` | |
| Workflow Event-Wait | Event Grid → Snowpipe | |

## 3. Catalog

Microsoft Purview scans ADLS (`raw/`) and Snowflake (CORE, MART) weekly;
glossary terms from [HEALTHCARE_TERMINOLOGY.md](HEALTHCARE_TERMINOLOGY.md) are
attached to MART columns. `SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES` gives
view/DT dependencies for impact analysis before a CORE change.
