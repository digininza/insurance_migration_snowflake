# Legacy inventory

- `workflow_inventory.csv` — sample of the programme's workflow inventory (the real one had ~490 workflows;
  this synthetic excerpt shows the columns and decisions: MIGRATE vs RETIRE, wave, target pattern).
- `assessment.csv` — **generated** by `make assess` from `../exports/*.xml` (mapping-level transformation
  counts, SQL overrides, lookups, complexity score, suggested Snowflake pattern). Not committed by hand.
