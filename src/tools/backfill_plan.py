"""Generate ctl.backfill_partition rows for a historical backfill.

One partition per service month; months whose estimated row count exceeds
`split_rows` are split into equal claim-id sub-ranges so every ADF copy is
roughly the same size (predictable duration, balanced parallelism, cheap retry).

    python -m src.tools.backfill_plan --object-id 2 --from 2014-01 --to 2025-12 \
        --estimates monthly_counts.csv --out data/backfill_partitions.csv
"""
from __future__ import annotations

import argparse
import csv
import math
import sys
from dataclasses import asdict, dataclass
from datetime import date


@dataclass(frozen=True)
class Partition:
    object_id: int
    partition_month: str
    partition_label: str
    range_column: str
    range_start: str
    range_end: str
    id_lower: int | None
    id_upper: int | None
    est_rows: int


def month_iter(start: date, end: date):
    y, m = start.year, start.month
    while (y, m) <= (end.year, end.month):
        yield date(y, m, 1)
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def next_month(d: date) -> date:
    return date(d.year + 1, 1, 1) if d.month == 12 else date(d.year, d.month + 1, 1)


def plan(object_id: int, start: date, end: date, estimates: dict[str, tuple[int, int, int]],
         split_rows: int = 50_000_000, range_column: str = "SERVICE_FROM_DT") -> list[Partition]:
    """estimates: 'YYYY-MM' -> (row_count, min_id, max_id)."""
    parts: list[Partition] = []
    for m in month_iter(start, end):
        key = m.strftime("%Y-%m")
        rows, lo, hi = estimates.get(key, (0, 0, 0))
        n_splits = max(1, math.ceil(rows / split_rows)) if rows else 1
        span = max(1, math.ceil((hi - lo + 1) / n_splits)) if hi >= lo else 1
        for i in range(n_splits):
            sub_lo = lo + i * span if rows else None
            sub_hi = min(hi, lo + (i + 1) * span - 1) if rows else None
            parts.append(Partition(
                object_id=object_id,
                partition_month=m.isoformat(),
                partition_label=key if n_splits == 1 else f"{key}_p{i + 1}",
                range_column=range_column,
                range_start=f"'{m.isoformat()}'",
                range_end=f"'{next_month(m).isoformat()}'",
                id_lower=sub_lo,
                id_upper=sub_hi,
                est_rows=rows // n_splits if rows else 0,
            ))
    return parts


def _ym(s: str) -> date:
    y, m = s.split("-")[:2]
    return date(int(y), int(m), 1)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--object-id", type=int, required=True)
    ap.add_argument("--from", dest="start", required=True)
    ap.add_argument("--to", dest="end", required=True)
    ap.add_argument("--estimates", help="CSV month,row_count,min_id,max_id")
    ap.add_argument("--split-rows", type=int, default=50_000_000)
    ap.add_argument("--out", default="data/backfill_partitions.csv")
    a = ap.parse_args(argv)
    est = {}
    if a.estimates:
        with open(a.estimates, newline="") as fh:
            for r in csv.DictReader(fh):
                est[r["month"]] = (int(r["row_count"]), int(r["min_id"]), int(r["max_id"]))
    parts = plan(a.object_id, _ym(a.start), _ym(a.end), est, a.split_rows)
    with open(a.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(asdict(parts[0]).keys()))
        w.writeheader()
        w.writerows(asdict(p) for p in parts)
    print(f"{len(parts)} partitions → {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
