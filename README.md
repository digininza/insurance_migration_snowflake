# CareVista Health — Informatica PowerCenter → Azure + Snowflake Migration

A **reference implementation** of a healthcare-insurance (payer) data-platform
migration: legacy **Informatica PowerCenter** ETL into an on-prem Oracle EDW is
replaced by **Azure Data Factory (metadata-driven) → ADLS Gen2 (Parquet) →
Snowpipe → Snowflake (ELT with Streams, Tasks, stored procedures and Dynamic
Tables)**, and a **legacy-vs-new reconciliation framework** gates production
cutover.

> **Synthetic learning/demo project.** CareVista Health is fictional. No real
> member, patient or PHI data is used anywhere; every record comes from the
> seeded generator in [`src/datagen/`](src/datagen/). Volumes, SLAs, costs and
> credit numbers are *illustrative project assumptions*, stated as such.

---

## The story in one paragraph

CareVista ran ~420 PowerCenter workflows (claims, membership/eligibility,
provider, premium billing, pharmacy) that extracted from on-prem SQL Server and
Oracle systems, transformed rows inside the PowerCenter Integration Service, and
loaded an Oracle EDW. Licence renewal, a 9-hour nightly batch that regularly
breached its 06:00 SLA, and no room left for 12 years of claims history drove a
migration to Azure + Snowflake. We **backfilled ~48 TB of history** with a
metadata-driven, restartable, partitioned ADF framework and bulk `COPY INTO`,
switched daily processing to **watermark-based incremental extraction** landing
**Parquet** in ADLS Gen2, loaded it with **Snowpipe auto-ingest (Event Grid)**,
re-implemented the Informatica mappings as **Snowflake SQL / stored procedures**
(ELT, not ETL), and ran a **parallel-run reconciliation** (counts, amounts,
data types, key business rules) for 3 consecutive month-ends before cutover.

## Architecture in one picture

```
 LEGACY (decommissioned)                                   TARGET (this repo)
 ───────────────────────                                   ───────────────────
 Claims (SQL Server) ─┐                        ┌────────── Azure Key Vault (secrets, CMK for Tri-Secret Secure)
 Membership (Oracle) ─┤  Informatica           │
 Provider (SQL Svr)  ─┼─ PowerCenter ─▶ Oracle │  ADF (metadata-driven, Self-hosted IR, Managed VNet)
 Billing (Oracle)    ─┤  (ETL)           EDW   │    • historical backfill  (partitioned, restartable)
 PBM files (SFTP)    ─┘                        │    • incremental          (watermark + control tables)
                                               ▼
                         ADLS Gen2  raw/<system>/<object>/load_date=YYYY-MM-DD/run_id=<id>/*.parquet
                                               │ BlobCreated → Event Grid → Storage Queue
                                               ▼
                         Snowflake  (Business Critical, Azure, Private Link)
   RAW (Snowpipe / COPY, as-landed) ─▶ STAGE (typed, deduped, DQ) ─▶ CORE (conformed dims SCD2 + facts)
        │ Streams + Tasks DAG + stored procedures (MERGE)                     │ Dynamic Tables
        ▼                                                                     ▼
   CONTROL · AUDIT · DQ · RECON (legacy vs new)             MART (claims, finance, provider, care mgmt, regulatory)
                                                                 + LEGACY_COMPAT views ─▶ Power BI / Cognos / extracts
 Cross-cutting: RBAC · tag-based PHI masking · row access · zero-copy clones · Time Travel · resource monitors · CI/CD
```

Full diagrams (Mermaid, render on GitHub): [`docs/diagrams/`](docs/diagrams/) —
HLD, ADF LLD, Snowflake LLD, data model ERD, migration waves (Gantt),
reconciliation flow, security/network, and task DAG.

## Documentation map

| Document | Covers |
|---|---|
| [RUNBOOK.md](RUNBOOK.md) | How to deploy, run backfill/incremental, reconcile, cut over, roll back |
| [docs/BUSINESS_DOMAIN.md](docs/BUSINESS_DOMAIN.md) | Payer business: members, claims lifecycle, adjudication, premiums, why the migration |
| [docs/HEALTHCARE_TERMINOLOGY.md](docs/HEALTHCARE_TERMINOLOGY.md) | Plain-language glossary (PMPM, ICD-10, CPT, NPI, IBNR, 834/835/837, HIPAA…) |
| [docs/architecture/HLD.md](docs/architecture/HLD.md) | High-level architecture, every layer, ETL→ELT decision |
| [docs/architecture/LLD_ADF.md](docs/architecture/LLD_ADF.md) | Metadata-driven ADF framework: control tables, pipelines, watermarks, backfill partitions |
| [docs/architecture/LLD_SNOWFLAKE.md](docs/architecture/LLD_SNOWFLAKE.md) | Snowflake objects: integrations, stages, pipes, streams, tasks, procs, dynamic tables |
| [docs/architecture/DATA_MODEL.md](docs/architecture/DATA_MODEL.md) | Layering (RAW/STAGE/CORE/MART) — **not only fact/dim**: bus matrix, SCD2, marts, compat views |
| [docs/architecture/COMPUTE_WAREHOUSES.md](docs/architecture/COMPUTE_WAREHOUSES.md) | **Which warehouses and why**: sizing, multi-cluster, QAS, scale up vs out, credits |
| [docs/architecture/TB_SCALE_PERFORMANCE.md](docs/architecture/TB_SCALE_PERFORMANCE.md) | 48 TB backfill + daily TB-scale handling: file sizing, parallelism, clustering, pruning |
| [docs/architecture/SECURITY_HIPAA.md](docs/architecture/SECURITY_HIPAA.md) | Key Vault, storage/notification integrations, Private Link, PHI masking, Tri-Secret Secure |
| [docs/architecture/CLOUD_NATIVE_SERVICES.md](docs/architecture/CLOUD_NATIVE_SERVICES.md) | Every Azure + Snowflake native service used and what it replaced |
| [docs/architecture/STREAMS_TASKS_DYNAMIC_TABLES.md](docs/architecture/STREAMS_TASKS_DYNAMIC_TABLES.md) | When Streams+Tasks vs Dynamic Tables vs stored procs vs MVs |
| [docs/architecture/ZERO_COPY_CLONE_TIME_TRAVEL.md](docs/architecture/ZERO_COPY_CLONE_TIME_TRAVEL.md) | Clone-based parallel run, backfill-and-SWAP, release rollback, Time Travel |
| [docs/architecture/decisions/](docs/architecture/decisions/) | 18 Architecture Decision Records |
| [docs/migration/MIGRATION_STRATEGY.md](docs/migration/MIGRATION_STRATEGY.md) | Assessment → waves → parallel run → cutover → decommission |
| [docs/migration/INFORMATICA_TO_SNOWFLAKE_MAPPING.md](docs/migration/INFORMATICA_TO_SNOWFLAKE_MAPPING.md) | Transformation-by-transformation conversion patterns (Expression, Lookup, Router, Update Strategy…) |
| [docs/migration/RECONCILIATION.md](docs/migration/RECONCILIATION.md) | 6-level reconciliation framework and exit criteria for cutover |
| [docs/migration/CUTOVER_PLAN.md](docs/migration/CUTOVER_PLAN.md) | Cutover weekend, go/no-go, rollback |
| [docs/LINEAGE.md](docs/LINEAGE.md) | Source-to-report lineage, legacy mapping → new object |
| [docs/scenarios/TROUBLESHOOTING.md](docs/scenarios/TROUBLESHOOTING.md) | 20 production-support scenarios |
| [docs/interview/INTERVIEW_GUIDE.md](docs/interview/INTERVIEW_GUIDE.md) | 30-second / 2-minute / 5-minute pitch, question bank, curveballs |
| [informatica_legacy/](informatica_legacy/) | Sample PowerCenter XML export + workflow inventory used by the assessment tool |
| [adf/](adf/) | ADF factory as JSON (linked services, datasets, pipelines, triggers, IRs) |
| [snowflake/](snowflake/) | All Snowflake DDL/DML, numbered in deploy order; manifest in `snowflake/deploy/` |

## What's implemented

- ✅ **Assessment tooling**: parses PowerCenter XML exports → mapping inventory, complexity score, migration wave and target pattern
- ✅ **ADF metadata-driven framework**: 1 generic copy pipeline driven by `ctl.source_object`; historical backfill by range partitions (restartable); incremental by watermark; SFTP file ingest with trailer validation; all secrets from **Key Vault**; SHIR + Managed VNet IR
- ✅ **ADLS Gen2 layout**: `raw/` (immutable Parquet, Snappy, 128–256 MB), `archive/` (lifecycle to Cool/Archive), `quarantine/`, `recon/`
- ✅ **Snowflake storage integration + notification integration** (Event Grid → Storage Queue) — no keys, no SAS tokens
- ✅ **Snowpipe auto-ingest** for incremental; **bulk `COPY INTO` on a dedicated XL warehouse** for historical backfill (and why)
- ✅ **Streams + Tasks DAG** calling **Snowflake Scripting stored procedures** (MERGE, SCD2, DQ, audit)
- ✅ **Dynamic Tables** for marts (PMPM, utilisation, provider scorecard, claims lag triangle for IBNR)
- ✅ **Kimball CORE** (8 conformed dims, 6 facts) + subject **MARTs** + **LEGACY_COMPAT** views (reports cut over without rewrite)
- ✅ **Workload-isolated warehouses** with resource monitors, multi-cluster BI, Query Acceleration
- ✅ **HIPAA controls**: Business Critical, Private Link, Tri-Secret Secure (CMK in Key Vault), tag-based PHI masking, row access by line of business, access history
- ✅ **Zero-copy cloning**: QA/UAT refresh, parallel-run freeze, backfill-in-clone + `ALTER TABLE … SWAP WITH`, pre-release snapshot for rollback
- ✅ **Reconciliation engine** (SQL + Python): row counts, amount totals, key-level hash diff, data-type/schema parity, business-rule parity, report-level KPI parity
- ✅ Monitoring views + Snowflake Alerts + Azure Monitor/Log Analytics integration
- ✅ CI/CD (GitHub Actions): lint, unit tests, ADF JSON validation, SQL manifest check, deploy via SnowSQL/Snowflake CLI
- ✅ Synthetic data generator with seeded defects (duplicates, orphans, late adjustments, negative paid, schema drift)

## Verify locally (no Azure or Snowflake account needed)

```bash
make venv
make test          # pytest: datagen, recon engine, informatica parser, ADF validator, SQL manifest
make assess        # informatica_legacy/exports/*.xml → informatica_legacy/inventory/assessment.csv
make generate      # synthetic legacy + migrated extracts into ./data/
make recon         # legacy vs new reconciliation report (shows the seeded breaks)
make validate      # ADF JSON references + no inline secrets + SQL manifest completeness
```

## Repository map

```text
insurance_migration_snowflake/
├── README.md, RUNBOOK.md, Makefile
├── docs/
│   ├── BUSINESS_DOMAIN.md, HEALTHCARE_TERMINOLOGY.md, LINEAGE.md
│   ├── architecture/   HLD, LLD_ADF, LLD_SNOWFLAKE, DATA_MODEL, COMPUTE_WAREHOUSES,
│   │                   TB_SCALE_PERFORMANCE, SECURITY_HIPAA, CLOUD_NATIVE_SERVICES,
│   │                   STREAMS_TASKS_DYNAMIC_TABLES, ZERO_COPY_CLONE_TIME_TRAVEL, decisions/ADR-*
│   ├── migration/      MIGRATION_STRATEGY, INFORMATICA_TO_SNOWFLAKE_MAPPING, RECONCILIATION, CUTOVER_PLAN
│   ├── diagrams/       *.mmd (HLD, LLDs, ERD, Gantt, recon, security, task DAG)
│   ├── runbooks/       backfill, snowpipe, task failure, recon break, rollback, key rotation
│   ├── scenarios/      TROUBLESHOOTING.md (20 scenarios)
│   └── interview/      INTERVIEW_GUIDE.md
├── informatica_legacy/ exports/*.xml (PowerCenter), inventory/workflow_inventory.csv
├── adf/                factory, integrationRuntime, linkedService, dataset, pipeline, trigger
├── metadata/           control-table seeds (source objects, backfill partitions, recon rules)
├── snowflake/          00_account … 12_monitoring, deploy/manifest.txt
├── src/                datagen/, recon/, tools/ (informatica_inventory, adf_validate, sql_manifest)
├── tests/              pytest suite
└── .github/workflows/  ci.yml, deploy.yml
```
