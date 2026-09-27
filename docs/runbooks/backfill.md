# Runbook — historical backfill wave

1. **Pre-checks**: SHIR nodes = 4 and healthy; `PROD_WH_BACKFILL` = XLARGE; `RM_PROD_BACKFILL` has budget;
   source DBA window confirmed; `ctl.backfill_partition` rows exist for the wave.
2. **Trigger** `PL_20_Historical_Backfill` (`object_id`, `wave_from_month`, `wave_to_month`).
3. **Monitor**: ADF → ForEach_Partition; `SELECT status, COUNT(*), SUM(rows_copied) FROM ctl.backfill_partition WHERE … GROUP BY status;`
4. **Partial failure**: pipeline ends with `Fail_Wave_Incomplete`. Read `last_error` per FAILED partition
   (usual: source timeout → split the partition with `backfill_plan --split-rows` lower; SHIR memory → reduce `parallelCopies`).
   **Re-run the same wave** — DONE partitions are skipped.
5. **Load**: `If_Wave_Complete` runs `SP_BACKFILL_COPY` (bulk COPY) then `EXECUTE TASK T_ROOT_BACKFILL`.
   Check `CTL_FILE_LOAD_LOG` for the ADF run id: all files `LOADED`, `ERRORS_SEEN = 0`.
6. **Validate** per month: source counts (from partition log) = RAW counts = `FACT_CLAIM_LINE_BF` counts; recon L2 amounts vs legacy.
7. After final wave: `11_clone_timetravel/03_backfill_swap.sql`, then scale down (RUNBOOK §4.6).
