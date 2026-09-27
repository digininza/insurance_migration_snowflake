from datetime import date
from decimal import Decimal

from src.datagen.generate import generate, transform_legacy, transform_new
from src.recon.reconcile import Result, reconcile, render_markdown, summarize


def _row(claim="C1", line=1, ver=1, paid="10.00", status="PAID", lob="COM", month=date(2026, 5, 1)):
    return {"claim_id": claim, "line_no": line, "claim_line_version": ver, "lob_code": lob, "claim_type": "P",
            "service_month": month, "line_status": status, "billed_amt": Decimal("20.00"),
            "allowed_amt": Decimal("15.00"), "paid_amt": Decimal(paid)}


def test_identical_inputs_are_green():
    rows = [_row("C1"), _row("C2", paid="5.55")]
    res = reconcile(rows, [dict(r) for r in rows])
    assert summarize(res)["status"] == "GREEN"
    assert {r.level for r in res} >= {"L1", "L2", "L3", "L6"}


def test_missing_and_mismatch_are_classified():
    legacy = [_row("C1"), _row("C2", paid="5.55")]
    new = [_row("C1"), _row("C2", paid="5.56"), _row("C3")]
    res = reconcile(legacy, new)
    l3 = {r.grain: r.status for r in res if r.level == "L3"}
    assert l3["C2|1|1"] == "VALUE_MISMATCH"
    assert l3["C3|1|1"] == "MISSING_IN_LEGACY"
    assert l3["C1|1|1"] == "MATCH"


def test_amount_tolerance_applies_to_l2_only():
    legacy, new = [_row(paid="10.00")], [_row(paid="10.01")]
    res = reconcile(legacy, new, amount_tolerance=Decimal("0.01"))
    assert all(r.status == "MATCH" for r in res if r.level == "L2")
    assert any(r.status == "VALUE_MISMATCH" for r in res if r.level == "L3")   # hashes stay exact


def test_type_parity_widening_ok_narrowing_breaks():
    res = reconcile([_row()], [_row()],
                    legacy_schema={"PD_AMT": "NUMBER(15,2)", "CLM_ID": "VARCHAR2(20)", "SVC_DT": "DATE"},
                    new_schema={"PD_AMT": "NUMBER(18,2)", "CLM_ID": "VARCHAR(20)", "SVC_DT": "TIMESTAMP_NTZ"})
    l4 = {r.grain: r.status for r in res if r.level == "L4"}
    assert l4["PD_AMT"] == "MATCH" and l4["CLM_ID"] == "MATCH" and l4["SVC_DT"] == "TYPE_MISMATCH"
    res2 = reconcile([_row()], [_row()], legacy_schema={"PD_AMT": "NUMBER(15,2)"}, new_schema={"PD_AMT": "FLOAT"})
    assert [r.status for r in res2 if r.level == "L4"] == ["TYPE_MISMATCH"]


def test_seeded_legacy_defects_surface_as_expected_categories():
    d = generate(seed=42, n_members=500, n_claims=3000, defect_rate=0.02)
    new, _ = transform_new(d)
    s = summarize(reconcile(transform_legacy(d), new))
    assert s["status"] == "RED"
    assert s["by_status"].get("MISSING_IN_LEGACY", 0) > 0     # L-DEF-1 router drop
    assert s["by_status"].get("VALUE_MISMATCH", 0) > 0        # L-DEF-2 truncation
    assert "MISSING_IN_NEW" not in s["by_status"]             # new never loses what legacy loaded


def test_report_renders():
    md = render_markdown([Result("L1", "r", "g", "1", "2", "VALUE_MISMATCH")])
    assert "RED" in md and "VALUE_MISMATCH" in md
