# Healthcare Insurance Terminology (plain language)

| Term | Meaning | Where it shows up here |
|---|---|---|
| **Payer** | The insurance company that pays claims (CareVista) | whole project |
| **Member / Subscriber** | Subscriber = policy holder; member = anyone covered (subscriber + dependants) | `DIM_MEMBER` (`SUBSCRIBER_ID`, `RELATIONSHIP_CD`) |
| **Eligibility span** | Start/end dates a member is covered under a plan | `FACT_ELIGIBILITY_MONTH` |
| **Member month** | One member covered for one month; the denominator of PMPM | `MART.FINANCE.DT_MEMBER_MONTHS` |
| **PMPM** | Per Member Per Month — cost ÷ member months | `MART.FINANCE.DT_PMPM_BY_LOB_MONTH` |
| **LOB** | Line of business: Commercial, Medicare Advantage, Medicaid | row access policy |
| **Claim / Claim line** | A bill from a provider; each line is one service | `FACT_CLAIM_LINE` |
| **Professional vs Institutional claim** | Doctor bill (837P / CMS-1500) vs hospital bill (837I / UB-04) | `claim_type` |
| **Adjudication** | Deciding whether and how much to pay | `LINE_STATUS` |
| **Billed / Allowed / Paid** | Provider charge / contracted maximum / what plan actually paid | amount columns |
| **Member liability** | Copay + coinsurance + deductible the member owes | `member_liability_amt` |
| **Adjustment / Reversal** | A later correction; reverses the original line and adds a new one | `claim_line_version`, `is_current` |
| **Date of service (DOS) / Incurred date** | When care happened | lag triangle rows |
| **Paid date** | When the claim was paid | lag triangle columns |
| **IBNR** | Incurred But Not Reported — reserve for claims not yet received | `MART.CLAIMS.DT_CLAIMS_LAG_TRIANGLE` |
| **MLR** | Medical Loss Ratio = medical cost ÷ premium; ACA requires ≥80/85 % | `MART.FINANCE.V_MLR_MONTHLY` |
| **NPI** | National Provider Identifier, 10 digits | `DIM_PROVIDER` |
| **In-network / Out-of-network** | Whether provider has a contract | `DIM_PROVIDER.NETWORK_ID`, `IS_PARTICIPATING` |
| **ICD-10-CM** | Diagnosis codes | `DIM_DIAGNOSIS` |
| **CPT / HCPCS** | Procedure codes | `DIM_PROCEDURE` |
| **NDC** | National Drug Code (pharmacy) | `FACT_PHARMACY_CLAIM` |
| **Revenue code / Place of service** | Where/what department for institutional/professional | `FACT_CLAIM_LINE.REVENUE_CD`, `PLACE_OF_SERVICE_CD` |
| **EDI 834 / 837 / 835** | X12 standards: enrollment / claim submission / remittance | source feeds (upstream of this repo) |
| **PBM** | Pharmacy Benefit Manager — third party that adjudicates drug claims | SFTP pharmacy feed |
| **PHI** | Protected Health Information under HIPAA | tag `PHI_CLASS`, masking policies |
| **Minimum necessary** | HIPAA principle: see only what your job needs | functional roles + masking |
| **BAA** | Business Associate Agreement — contract that lets a vendor hold PHI | Snowflake Business Critical |
| **Encounter data** | Claims-like records reported to the state for Medicaid | regulatory mart |
| **Risk adjustment / HCC** | Medicare payment adjustment based on diagnoses | future mart (out of scope) |
| **Open enrollment** | Annual window when enrollment volume spikes 5–10× | scaling scenario |
