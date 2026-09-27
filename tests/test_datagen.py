from decimal import Decimal

from src.datagen.generate import generate, transform_legacy, transform_new


def test_generation_is_deterministic():
    a = generate(seed=7, n_members=200, n_claims=500)
    b = generate(seed=7, n_members=200, n_claims=500)
    assert [x.claim_id for x in a["lines"]] == [x.claim_id for x in b["lines"]]
    assert [x.paid_amt for x in a["lines"]] == [x.paid_amt for x in b["lines"]]


def test_money_is_decimal_never_float():
    d = generate(seed=1, n_members=50, n_claims=100)
    for ln in d["lines"]:
        assert isinstance(ln.paid_amt, Decimal) and isinstance(ln.allowed_amt, Decimal)


def test_new_platform_dedupes_and_quarantines_orphans():
    d = generate(seed=3, n_members=300, n_claims=1500, defect_rate=0.02)
    fact, quarantine = transform_new(d)
    keys = [(r["claim_id"], r["line_no"], r["claim_line_version"]) for r in fact]
    assert len(keys) == len(set(keys)), "duplicate extracts must be deduped"
    assert quarantine and all(q["reason"] == "ORPHAN_LINE_NO_HEADER" for q in quarantine)
    assert all(r["claim_id"] != q["claim_id"] for r in fact for q in quarantine[:5])


def test_reversals_are_negative_and_net_paid_is_preserved():
    d = generate(seed=5, n_members=300, n_claims=3000)
    fact, _ = transform_new(d)
    by_line = {}
    for r in fact:
        by_line.setdefault((r["claim_id"], r["line_no"]), []).append(r)
    adjusted = [v for v in by_line.values() if len(v) == 3]
    assert adjusted, "generator should produce OR/RV/AD chains"
    for chain in adjusted:
        chain.sort(key=lambda r: r["claim_line_version"])
        orig, rev, adj = chain
        assert rev["paid_amt"] == -orig["paid_amt"]                   # CLM-R-017
        assert sum(r["paid_amt"] for r in chain) == adj["paid_amt"]   # net = latest version


def test_legacy_drops_trailing_space_status_rows():
    d = generate(seed=11, n_members=300, n_claims=3000, defect_rate=0.03)
    new, _ = transform_new(d)
    legacy = transform_legacy(d)
    assert len(new) > len(legacy)          # L-DEF-1 makes legacy lose rows
