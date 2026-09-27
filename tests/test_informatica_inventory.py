from pathlib import Path

from src.tools.informatica_inventory import assess_directory, parse_export

EXPORTS = Path(__file__).resolve().parents[1] / "informatica_legacy" / "exports"


def _by_name():
    return {a.mapping: a for a in assess_directory(EXPORTS)}


def test_all_mappings_found_with_workflows():
    m = _by_name()
    assert set(m) == {"m_CLM_CLAIM_LINE_LOAD", "m_CLM_DIAG_NORMALIZE", "m_CLM_AGG_DENIAL_DAILY",
                      "m_MBR_MEMBER_SCD2", "m_ELG_MBR_MONTHS", "m_MBR_GROUP_COPY"}
    assert m["m_CLM_CLAIM_LINE_LOAD"].workflow == "wf_CLM_DAILY_CLAIMS"


def test_claim_line_mapping_flags():
    a = _by_name()["m_CLM_CLAIM_LINE_LOAD"]
    assert a.lookups == 2 and a.sql_overrides == 2          # SQ override + lookup override
    assert "$$LAST_EXTRACT_DT" in a.parameters
    assert a.complexity == "Medium"
    assert "MERGE" in a.target_pattern


def test_scd2_mapping_is_complex():
    a = _by_name()["m_MBR_MEMBER_SCD2"]
    assert a.is_scd2 and a.dynamic_lookups == 1
    assert a.transformation_counts["Stored Procedure"] == 1
    assert a.complexity == "Complex" and "SCD2" in a.target_pattern


def test_simple_and_aggregate_patterns():
    m = _by_name()
    assert m["m_MBR_GROUP_COPY"].complexity == "Simple"
    assert m["m_CLM_AGG_DENIAL_DAILY"].target_pattern == "Dynamic Table"
    assert m["m_CLM_AGG_DENIAL_DAILY"].truncate_target is True


def test_parse_single_file_rows_have_hints():
    rows = [a.as_row() for a in parse_export(EXPORTS / "wf_CLM_DAILY_CLAIMS.xml")]
    assert len(rows) == 3
    assert any("MERGE" in r["construct_hints"] for r in rows)
