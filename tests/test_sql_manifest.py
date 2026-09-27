from pathlib import Path

from src.tools.sql_manifest import check_manifest, lint_sql, lint_tree

SF = Path(__file__).resolve().parents[1] / "snowflake"


def test_repository_sql_is_clean():
    assert lint_tree(SF) == []


def test_manifest_covers_every_file():
    assert check_manifest(SF) == []


def test_float_is_rejected():
    errs = lint_sql("CREATE TABLE IF NOT EXISTS T (PAID_AMT FLOAT);", "x.sql", True)
    assert any("floating" in e for e in errs)


def test_money_precision_rule():
    assert lint_sql("CREATE TABLE IF NOT EXISTS T (PAID_AMT NUMBER(18,2));", "x.sql", True) == []
    errs = lint_sql("CREATE TABLE IF NOT EXISTS T (PAID_AMT NUMBER(15,2));", "x.sql", True)
    assert any("NUMBER(18,2)" in e for e in errs)
    # aliases and expressions are not column definitions
    assert lint_sql("SELECT SUM(PAID_AMT) AS PAID_AMT, p.PAID_AMT AS MEDICAL_PAID_AMT FROM X;", "x.sql", True) == []


def test_create_or_replace_table_only_allowed_for_temp_or_manual():
    assert lint_sql("CREATE OR REPLACE TABLE T (A INT);", "x.sql", True)
    assert lint_sql("CREATE OR REPLACE TEMPORARY TABLE T LIKE S;", "x.sql", True) == []
    assert lint_sql("CREATE OR REPLACE TABLE T (A INT);", "x.sql", False) == []


def test_strings_and_comments_are_ignored():
    sql = "-- PAID_AMT FLOAT\nINSERT INTO R VALUES ('PAID_AMT FLOAT');"
    assert lint_sql(sql, "x.sql", True) == []
