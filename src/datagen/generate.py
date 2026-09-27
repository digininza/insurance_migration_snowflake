"""Synthetic CareVista source data + the two implementations being reconciled.

Generates members, eligibility spans, claim headers and claim-line versions
(original / reversal / adjustment) with seeded defects, then produces:

  * new_fact   — what the Snowflake pipeline produces (SP_STAGE_* + SP_MERGE_FACT_*)
  * legacy_fact — what the Informatica/Oracle EDW produced, including the legacy
                  behaviours that caused real reconciliation breaks:
      L-DEF-1  Router default group silently dropped lines whose status had trailing
               spaces ('PAID ') — new platform trims → MISSING_IN_LEGACY
      L-DEF-2  EXP port decimal(15,2) TRUNCATED 3-decimal source amounts instead of
               rounding → 1-cent VALUE_MISMATCH
Seeded source defects handled identically by both (should NOT break):
      D1 duplicate extract of the same line version (dedupe on rowversion)
      D2 orphan lines (header missing) → quarantined by new, dropped by legacy SQ join
      D3 late-arriving member (claim before member) → inferred member vs -1

All values are fictional. Money is Decimal, never float.

    python -m src.datagen.generate --out data --seed 42 --members 2000 --claims 8000
"""
from __future__ import annotations

import argparse
import csv
import random
from dataclasses import asdict, dataclass
from datetime import date, timedelta
from decimal import ROUND_DOWN, ROUND_HALF_UP, Decimal
from pathlib import Path

CENT = Decimal("0.01")
LOBS = [("COM", 0.65), ("MA", 0.20), ("MCD", 0.15)]
STATUSES = [("PAID", 0.82), ("DENIED", 0.12), ("PENDED", 0.06)]
FIRST = ["Alex", "Sam", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Jamie", "Avery", "Quinn"]
LAST = ["Rivera", "Chen", "Okafor", "Novak", "Haddad", "Silva", "Kowalski", "Tanaka", "Mensah", "Larsen"]


@dataclass
class Member:
    member_id: str
    first_name: str
    last_name: str
    birth_dt: date
    lob_code: str
    zip_cd: str


@dataclass
class ClaimHeader:
    claim_id: str
    claim_type: str
    member_id: str
    lob_code: str
    received_dt: date
    paid_dt: date | None


@dataclass
class ClaimLine:
    claim_id: str
    line_no: int
    claim_line_version: int
    adjustment_type: str       # OR | RV | AD
    service_from_dt: date
    procedure_cd: str
    billed_amt: Decimal
    allowed_amt: Decimal
    paid_amt: Decimal          # source sign: reversals arrive POSITIVE (legacy EXP negated them)
    line_status: str
    source_rowversion: int


def _pick(rng, weighted):
    r, acc = rng.random(), 0.0
    for v, w in weighted:
        acc += w
        if r <= acc:
            return v
    return weighted[-1][0]


def generate(seed: int = 42, n_members: int = 2000, n_claims: int = 8000, business_date: date = date(2026, 5, 31),
             defect_rate: float = 0.01) -> dict:
    rng = random.Random(seed)
    members = [Member(f"M{100000 + i}", rng.choice(FIRST), rng.choice(LAST),
                      date(1940, 1, 1) + timedelta(days=rng.randint(0, 29000)), _pick(rng, LOBS),
                      f"{rng.randint(10000, 99999)}") for i in range(n_members)]
    late_members = [Member(f"M9{rng.randint(10000, 99999)}", "Late", "Arrival", date(1980, 1, 1), "COM", "30301")
                    for _ in range(max(1, int(n_claims * defect_rate / 4)))]

    headers: list[ClaimHeader] = []
    lines: list[ClaimLine] = []
    rowver = 1_000_000
    for c in range(n_claims):
        m = rng.choice(late_members) if rng.random() < defect_rate / 4 else rng.choice(members)
        received = business_date - timedelta(days=rng.randint(0, 120))
        hdr = ClaimHeader(f"C{2026000000 + c}", rng.choice(["P", "I"]), m.member_id, m.lob_code, received,
                          received + timedelta(days=rng.randint(5, 30)))
        headers.append(hdr)
        for ln in range(1, rng.randint(1, 4) + 1):
            billed = Decimal(rng.randint(5000, 500000)) / 100
            allowed = (billed * Decimal(str(rng.uniform(0.35, 0.9)))).quantize(CENT, ROUND_HALF_UP)
            status = _pick(rng, STATUSES)
            # D-src: ~1 % of amounts carry 3 decimals in the source (decimal(15,3) column)
            if rng.random() < defect_rate:
                paid = (allowed * Decimal("0.8")).quantize(Decimal("0.001")) + Decimal("0.005")
            else:
                paid = (allowed * Decimal("0.8")).quantize(CENT, ROUND_HALF_UP) if status == "PAID" else Decimal("0.00")
            svc = received - timedelta(days=rng.randint(0, 60))
            if rng.random() < defect_rate:            # L-DEF-1 source quirk: trailing space in status
                status = status + " "
            rowver += 1
            base = ClaimLine(hdr.claim_id, ln, 1, "OR", svc, f"99{rng.randint(201, 215)}", billed, allowed, paid,
                             status, rowver)
            lines.append(base)
            if rng.random() < 0.05 and status.strip() == "PAID":     # adjustment: reverse + re-adjudicate
                rowver += 1
                lines.append(ClaimLine(hdr.claim_id, ln, 2, "RV", svc, base.procedure_cd, billed, allowed, paid, "PAID", rowver))
                rowver += 1
                new_paid = (paid * Decimal("0.9")).quantize(CENT, ROUND_HALF_UP)
                lines.append(ClaimLine(hdr.claim_id, ln, 3, "AD", svc, base.procedure_cd, billed, allowed, new_paid, "PAID", rowver))
            if rng.random() < defect_rate:            # D1 duplicate extract, later rowversion, same content
                rowver += 1
                lines.append(ClaimLine(**{**asdict(base), "source_rowversion": rowver}))

    # D2 orphan lines (header never arrives in this batch)
    for i in range(max(1, int(n_claims * defect_rate / 2))):
        rowver += 1
        lines.append(ClaimLine(f"C99{i:07d}", 1, 1, "OR", business_date - timedelta(days=3), "99213",
                               Decimal("120.00"), Decimal("80.00"), Decimal("64.00"), "PAID", rowver))
    return {"members": members, "late_members": late_members, "headers": headers, "lines": lines,
            "business_date": business_date}


# ----------------------------------------------------------------- implementations
def _dedupe_latest(lines: list[ClaimLine]) -> list[ClaimLine]:
    best: dict[tuple, ClaimLine] = {}
    for ln in lines:
        k = (ln.claim_id, ln.line_no, ln.claim_line_version)
        if k not in best or ln.source_rowversion > best[k].source_rowversion:
            best[k] = ln
    return list(best.values())


def _sign(adj: str, v: Decimal) -> Decimal:
    return -abs(v) if adj == "RV" else v


def transform_new(data: dict) -> tuple[list[dict], list[dict]]:
    """Mirror of SP_STAGE_CLAIM_LINE + SP_MERGE_FACT_CLAIM_LINE. Returns (fact, quarantine)."""
    hdr = {h.claim_id: h for h in data["headers"]}
    fact, quarantine = [], []
    for ln in _dedupe_latest(data["lines"]):
        h = hdr.get(ln.claim_id)
        status = ln.line_status.strip().upper()
        if h is None:
            quarantine.append({"claim_id": ln.claim_id, "line_no": ln.line_no, "reason": "ORPHAN_LINE_NO_HEADER"})
            continue
        fact.append({
            "claim_id": ln.claim_id, "line_no": ln.line_no, "claim_line_version": ln.claim_line_version,
            "lob_code": h.lob_code, "claim_type": h.claim_type, "received_dt": h.received_dt,
            "service_month": ln.service_from_dt.replace(day=1), "line_status": status,
            "billed_amt": _sign(ln.adjustment_type, ln.billed_amt).quantize(CENT, ROUND_HALF_UP),
            "allowed_amt": _sign(ln.adjustment_type, ln.allowed_amt).quantize(CENT, ROUND_HALF_UP),
            "paid_amt": _sign(ln.adjustment_type, ln.paid_amt).quantize(CENT, ROUND_HALF_UP),   # NUMBER(18,2) rounds
        })
    return fact, quarantine


def transform_legacy(data: dict) -> list[dict]:
    """Emulates m_CLM_CLAIM_LINE_LOAD incl. L-DEF-1 (router drops 'PAID ') and L-DEF-2 (truncation)."""
    hdr = {h.claim_id: h for h in data["headers"]}
    out = []
    for ln in _dedupe_latest(data["lines"]):          # UPD_CLAIM DD_UPDATE on existing key ≈ latest wins
        h = hdr.get(ln.claim_id)
        if h is None:                                  # SQ inner join drops orphans
            continue
        if ln.line_status not in ("PAID", "DENIED", "PENDED", "VOID"):   # router default group, no trim
            continue
        out.append({
            "claim_id": ln.claim_id, "line_no": ln.line_no, "claim_line_version": ln.claim_line_version,
            "lob_code": h.lob_code, "claim_type": h.claim_type, "received_dt": h.received_dt,
            "service_month": ln.service_from_dt.replace(day=1), "line_status": ln.line_status,
            "billed_amt": _sign(ln.adjustment_type, ln.billed_amt).quantize(CENT, ROUND_DOWN),
            "allowed_amt": _sign(ln.adjustment_type, ln.allowed_amt).quantize(CENT, ROUND_DOWN),
            "paid_amt": _sign(ln.adjustment_type, ln.paid_amt).quantize(CENT, ROUND_DOWN),        # decimal(15,2) truncates
        })
    return out


def write_csv(rows: list[dict], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as fh:
        if not rows:
            return
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--members", type=int, default=2000)
    ap.add_argument("--claims", type=int, default=8000)
    a = ap.parse_args(argv)
    data = generate(a.seed, a.members, a.claims)
    out = Path(a.out)
    write_csv([asdict(m) for m in data["members"]], out / "source" / "member.csv")
    write_csv([asdict(h) for h in data["headers"]], out / "source" / "claim_header.csv")
    write_csv([asdict(ln) for ln in data["lines"]], out / "source" / "claim_line.csv")
    new_fact, quarantine = transform_new(data)
    legacy_fact = transform_legacy(data)
    write_csv(new_fact, out / "new" / "fact_claim_line.csv")
    write_csv(quarantine, out / "new" / "quarantine_claim_line.csv")
    write_csv(legacy_fact, out / "legacy" / "claim_line_fact.csv")
    print(f"members={len(data['members'])} headers={len(data['headers'])} source_lines={len(data['lines'])} "
          f"new_fact={len(new_fact)} quarantined={len(quarantine)} legacy_fact={len(legacy_fact)} → {out}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
