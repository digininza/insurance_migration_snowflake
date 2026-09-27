from datetime import date

from src.tools.backfill_plan import plan


def test_one_partition_per_month_when_small():
    parts = plan(2, date(2014, 1, 1), date(2014, 12, 1), {})
    assert len(parts) == 12
    assert parts[0].range_start == "'2014-01-01'" and parts[0].range_end == "'2014-02-01'"
    assert parts[-1].range_end == "'2015-01-01'"


def test_large_month_is_split_into_contiguous_id_ranges():
    est = {"2019-03": (120_000_000, 1, 1_200_000)}
    parts = [p for p in plan(2, date(2019, 3, 1), date(2019, 3, 1), est, split_rows=50_000_000)]
    assert [p.partition_label for p in parts] == ["2019-03_p1", "2019-03_p2", "2019-03_p3"]
    assert parts[0].id_lower == 1 and parts[-1].id_upper == 1_200_000
    for a, b in zip(parts, parts[1:]):
        assert b.id_lower == a.id_upper + 1          # no gaps, no overlap


def test_twelve_years_of_claims_partition_count():
    est = {f"{y}-{m:02d}": (17_000_000, 1, 17_000_000) for y in range(2014, 2026) for m in range(1, 13)}
    assert len(plan(2, date(2014, 1, 1), date(2025, 12, 1), est)) == 144
