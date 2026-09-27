# Business Domain — CareVista Health (fictional payer)

## 1. Who CareVista is

CareVista Health is a fictional regional **health insurance payer** with ~3.2 M
members across three **lines of business (LOB)**:

| LOB | Members (illustrative) | Notes |
|---|---|---|
| Commercial (employer group + individual) | 2.1 M | Premiums billed monthly to employer groups |
| Medicare Advantage | 0.6 M | CMS risk adjustment, Star ratings, stricter reporting deadlines |
| Medicaid managed care | 0.5 M | State encounter reporting, row-level separation by state contract |

Row-level separation by LOB is a hard requirement: Medicaid analysts must not see
Commercial members and vice versa. That becomes a **row access policy** in Snowflake.

## 2. The data the platform carries

| Domain | Source system (legacy) | Key entities | Daily volume (illustrative) |
|---|---|---|---|
| **Claims** | Claims admin system on SQL Server (on-prem) | claim header, claim line, diagnosis, procedure, adjustment | 9–12 M claim lines/day incl. adjustments |
| **Membership / Eligibility** | Enrollment system on Oracle | subscriber, member, eligibility span, coverage, 834 enrollment | 150–400 K changes/day (peaks at open enrollment) |
| **Provider** | Provider data management on SQL Server | provider (NPI), network, contract, specialty | 20–50 K changes/day |
| **Premium billing** | Billing on Oracle | group, invoice, payment, delinquency | 1–2 M rows/day, month-end spike |
| **Pharmacy** | PBM partner, pipe-delimited files over SFTP | pharmacy claim (NDC) | 1.5 M rows/day |
| **Reference** | Code-set files | ICD-10-CM, CPT/HCPCS, NDC, place of service, revenue codes | quarterly/annual refresh |

History carried in the migration: **12 years** of claims (~2.4 B claim lines),
all membership history, 7 years of premium billing — **~48 TB uncompressed at
source, ~7.5 TB as Snappy Parquet, ~5.8 TB in Snowflake** after columnar
compression (illustrative).

## 3. Claims lifecycle (why claims data is hard)

```
Provider submits 837 ─▶ Received ─▶ Adjudicated (Paid / Denied / Pended) ─▶ Paid (835 remittance)
                                           │
                                           └─▶ Adjusted / Reversed (weeks or months later)
```

Consequences that shape the design:

1. **Claims are not immutable.** An adjustment reverses the original line
   (negative amounts) and adds a new version. The warehouse must keep every
   version (`claim_line_version`) and expose a "current" view — SCD-like handling
   of *facts*, not only dimensions.
2. **Late-arriving data.** A claim for a date of service in January can arrive in
   June. Marts are keyed on **date of service** *and* **paid date**; the
   "claims lag triangle" (incurred vs paid month) feeds **IBNR** actuarial reserves.
3. **Late-arriving dimensions.** A claim can arrive before the member's
   eligibility change lands. Unknown member keys get an **inferred member** row
   (`-1` or placeholder SK) that is back-filled when the member arrives.
4. **Money precision.** All amounts are `NUMBER(18,2)`; never `FLOAT`. A 1-cent
   difference between legacy and new is a reconciliation break.

## 4. Key business metrics (must reconcile before cutover)

| Metric | Definition (simplified) | Consumer |
|---|---|---|
| **Paid amount** | Σ plan paid on adjudicated, non-reversed lines | Finance, actuarial |
| **Allowed amount** | Σ contracted allowed amount | Network management |
| **Member months** | Count of members eligible on the 15th of each month | Every PMPM metric |
| **PMPM** | Paid ÷ member months | Executive, actuarial |
| **Medical Loss Ratio (MLR)** | Medical paid ÷ earned premium | Regulatory (ACA 80/85 % rule) |
| **Claims lag / IBNR triangle** | Paid amounts by incurred month × paid month | Actuarial reserving |
| **Denial rate** | Denied lines ÷ adjudicated lines | Operations |
| **Auto-adjudication rate** | Lines adjudicated with no human touch ÷ total | Operations |
| **Premium collected / delinquency** | Invoiced vs paid premium per group | Finance |

## 5. Why migrate (the business case)

| Pain in legacy | Impact | Target-state answer |
|---|---|---|
| PowerCenter licence + Oracle Exadata renewal | High fixed cost | Consumption pricing; warehouses suspend when idle |
| 9-hour serial nightly batch, ~40 % SLA misses at month-end | Claims ops dashboards late | Parallel ADF copies, incremental ELT, Dynamic Tables with 1-hour lag |
| ETL row-by-row in the Integration Service | Can't scale for 12 years of history | Set-based ELT on elastic Snowflake compute |
| EDW full at 92 % capacity; history archived to tape | Actuarial can't query >5 years | All history online, Time Travel, cheap storage |
| PHI copied into many dev/test databases | HIPAA audit finding | Zero-copy clones + dynamic masking; no physical PHI copies |
| Tribal knowledge in 420 undocumented mappings | Key-person risk | Assessment inventory + SQL in Git + lineage |

## 6. Regulatory context (framed honestly)

- **HIPAA** Privacy & Security rules: PHI (member name, DOB, SSN, address,
  member ID, diagnosis) needs minimum-necessary access, audit trails and
  encryption. We model the *engineering controls* — this repo is not a
  compliance certification.
- **Snowflake BAA** requires **Business Critical** edition for PHI → see ADR-002.
- **CMS / state encounter reporting** deadlines drive the Medicare/Medicaid marts.
- **ACA MLR** reporting drives the premium ↔ claims join.

## 7. Why a missing or wrong file blocks the pipeline

If the eligibility extract is missing and claims load anyway, every claim is
joined to stale eligibility → member months, PMPM and MLR are wrong, and
Finance may publish them. So eligibility and claims are **critical feeds**: the
Task DAG's publish step checks `CONTROL.CTL_FEED_STATUS` and refuses to refresh
the finance marts until both are `LOADED` and reconciled for the business date.
Pharmacy and reference feeds are **non-critical**: late arrival raises an alert
but does not block publication.
