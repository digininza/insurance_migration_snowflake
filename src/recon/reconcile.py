"""Offline reconciliation engine — same levels and break categories as
CONTROL.RECON.SP_RUN_RECON, runnable locally on extracts (CI + investigations).

Levels implemented here: L1 counts, L2 amount totals, L3 key-level hash diff,
L4 column/type parity (for extracts with declared schemas), L6 KPI (derived totals).

    python -m src.recon.reconcile --data data --report data/recon_report.md
"""
from __future__ import annotations

import argparse
import csv
import hashlib
from collections import Counter, defaultdict
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path

MONEY = ("billed_amt", "allowed_amt", "paid_amt")
LEGACY_LOB = {"COM": "C", "MA": "M", "MCD": "D"}


@dataclass(frozen=True)
class Result:
    level: str
    rule: str
    grain: str
    legacy: str | None
    new: str | None
    status: str          # MATCH | VALUE_MISMATCH | MISSING_IN_NEW | MISSING_IN_LEGACY | TYPE_MISMATCH

    @property
    def is_break(self) -> bool:
        return self.status != "MATCH"


def grain_key(r: dict) -> str:
    """Same format as the Oracle extract and RECON_RULE.NEW_SQL: LOB|CLAIM_TYPE|YYYY-MM."""
    sm = str(r["service_month"])[:7]
    return f"{LEGACY_LOB.get(r['lob_code'], 'U')}|{r['claim_type']}|{sm}"


def row_hash(r: dict) -> str:
    parts = [f"{Decimal(str(r[c])):.2f}" for c in MONEY] + [str(r["line_status"]).strip()]
    return hashlib.md5("|".join(parts).encode()).hexdigest()


def key(r: dict) -> str:
    return f"{r['claim_id']}|{r['line_no']}|{r['claim_line_version']}"


def _compare(level, rule, legacy: dict, new: dict, tol: Decimal | None) -> list[Result]:
    out = []
    for g in sorted(set(legacy) | set(new)):
        lv, nv = legacy.get(g), new.get(g)
        if lv is None:
            st = "MISSING_IN_LEGACY"
        elif nv is None:
            st = "MISSING_IN_NEW"
        elif tol is None:
            st = "MATCH" if lv == nv else "VALUE_MISMATCH"
        else:
            st = "MATCH" if abs(Decimal(str(nv)) - Decimal(str(lv))) <= tol else "VALUE_MISMATCH"
        out.append(Result(level, rule, g, None if lv is None else str(lv), None if nv is None else str(nv), st))
    return out


def counts_by_grain(rows):
    return dict(Counter(grain_key(r) for r in rows))


def sums_by_grain(rows, col):
    acc: dict[str, Decimal] = defaultdict(Decimal)
    for r in rows:
        acc[grain_key(r)] += Decimal(str(r[col]))
    return dict(acc)


def reconcile(legacy_rows: list[dict], new_rows: list[dict], amount_tolerance: Decimal = Decimal("0.00"),
              legacy_schema: dict[str, str] | None = None, new_schema: dict[str, str] | None = None) -> list[Result]:
    results: list[Result] = []
    results += _compare("L1", "RC-L1-001 row count by LOB|type|month", counts_by_grain(legacy_rows), counts_by_grain(new_rows), Decimal(0))
    for col in MONEY:
        results += _compare("L2", f"RC-L2 sum({col})", sums_by_grain(legacy_rows, col), sums_by_grain(new_rows, col), amount_tolerance)
    results += _compare("L3", "RC-L3-001 key hash", {key(r): row_hash(r) for r in legacy_rows},
                        {key(r): row_hash(r) for r in new_rows}, None)
    if legacy_schema is not None and new_schema is not None:
        for col in sorted(set(legacy_schema) | set(new_schema)):
            lt, nt = legacy_schema.get(col), new_schema.get(col)
            st = ("MISSING_IN_NEW" if nt is None else "MISSING_IN_LEGACY" if lt is None
                  else "MATCH" if _type_compatible(lt, nt) else "TYPE_MISMATCH")
            results.append(Result("L4", "RC-L4 type parity", col, lt, nt, st))
    tot_l = sum((Decimal(str(r["paid_amt"])) for r in legacy_rows), Decimal(0))
    tot_n = sum((Decimal(str(r["paid_amt"])) for r in new_rows), Decimal(0))
    results += _compare("L6", "RC-L6 total net paid (finance KPI)", {"ALL": tot_l}, {"ALL": tot_n}, amount_tolerance)
    return results


def _type_compatible(legacy_t: str, new_t: str) -> bool:
    """Widening allowed, narrowing not: NUMBER(15,2) → NUMBER(18,2) ok; → NUMBER(12,2) or FLOAT not ok."""
    import re
    lm = re.match(r"NUMBER\((\d+),(\d+)\)", legacy_t.upper().replace(" ", ""))
    nm = re.match(r"NUMBER\((\d+),(\d+)\)", new_t.upper().replace(" ", ""))
    if lm:
        return bool(nm) and int(nm.group(1)) >= int(lm.group(1)) and int(nm.group(2)) >= int(lm.group(2))
    if legacy_t.upper().startswith(("VARCHAR2", "CHAR")):
        return new_t.upper().startswith(("VARCHAR", "TEXT", "CHAR", "STRING"))
    return legacy_t.upper() == new_t.upper()


def summarize(results: list[Result]) -> dict:
    s: dict = {"compared": len(results), "breaks": sum(r.is_break for r in results)}
    s["by_level"] = {lvl: {"compared": sum(r.level == lvl for r in results),
                           "breaks": sum(r.level == lvl and r.is_break for r in results)}
                     for lvl in sorted({r.level for r in results})}
    s["by_status"] = dict(Counter(r.status for r in results if r.is_break))
    s["status"] = "GREEN" if s["breaks"] == 0 else "RED"
    return s


def render_markdown(results: list[Result], max_rows: int = 25) -> str:
    s = summarize(results)
    lines = [f"# Reconciliation report — {s['status']}", "",
             f"Compared {s['compared']} grains, **{s['breaks']} breaks**.", "",
             "| Level | Compared | Breaks |", "|---|---|---|"]
    lines += [f"| {k} | {v['compared']} | {v['breaks']} |" for k, v in s["by_level"].items()]
    lines += ["", "| Break category | Count |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(s["by_status"].items())]
    lines += ["", f"## First {max_rows} breaks", "", "| Level | Rule | Grain | Legacy | New | Status |", "|---|---|---|---|---|---|"]
    lines += [f"| {r.level} | {r.rule} | {r.grain} | {r.legacy} | {r.new} | {r.status} |"
              for r in [r for r in results if r.is_break][:max_rows]]
    return "\n".join(lines) + "\n"


def read_csv(path: Path) -> list[dict]:
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data")
    ap.add_argument("--report", default="data/recon_report.md")
    a = ap.parse_args(argv)
    d = Path(a.data)
    res = reconcile(read_csv(d / "legacy" / "claim_line_fact.csv"), read_csv(d / "new" / "fact_claim_line.csv"))
    Path(a.report).write_text(render_markdown(res))
    s = summarize(res)
    print(f"recon {s['status']}: {s['breaks']} breaks / {s['compared']} grains  {s['by_status']}  → {a.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
