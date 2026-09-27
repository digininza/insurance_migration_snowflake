"""Lint the Snowflake SQL tree (run in CI).

1. Every .sql under snowflake/ is listed exactly once in deploy/manifest.txt
   (as a deploy step or `manual:` runbook script), and every manifest entry exists.
2. No FLOAT/DOUBLE/REAL column types anywhere (money precision — recon L4).
3. Columns named *_AMT are NUMBER(18,2).
4. Deployable scripts never `CREATE OR REPLACE` a permanent TABLE (would wipe data);
   use CREATE TABLE IF NOT EXISTS. Temporary tables and manual runbooks are exempt.

    python -m src.tools.sql_manifest
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SQL_TYPES = {"NUMBER", "NUMERIC", "DECIMAL", "INT", "INTEGER", "BIGINT", "FLOAT", "FLOAT4", "FLOAT8", "DOUBLE",
             "REAL", "VARCHAR", "STRING", "TEXT", "CHAR", "DATE", "TIMESTAMP_NTZ", "TIMESTAMP_LTZ", "BOOLEAN", "VARIANT"}


def strip_comments(sql: str) -> str:
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    return re.sub(r"--[^\n]*", " ", sql)


def read_manifest(path: Path) -> tuple[list[str], list[str]]:
    deploy, manual = [], []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("manual:"):
            manual.append(line.split(":", 1)[1].strip())
        else:
            deploy.append(line)
    return deploy, manual


def check_manifest(sf_dir: Path) -> list[str]:
    deploy, manual = read_manifest(sf_dir / "deploy" / "manifest.txt")
    listed = deploy + manual
    errors = [f"manifest lists '{p}' more than once" for p in sorted({p for p in listed if listed.count(p) > 1})]
    on_disk = {str(p.relative_to(sf_dir)) for p in sf_dir.rglob("*.sql")}
    errors += [f"manifest entry '{p}' does not exist" for p in listed if p not in on_disk]
    errors += [f"'{p}' is not in manifest.txt (deploy or manual:)" for p in sorted(on_disk - set(listed))]
    return errors


def lint_sql(text: str, name: str, deployable: bool) -> list[str]:
    errors = []
    body = strip_comments(text)
    # remove single-quoted string literals (rule SQL, comments) before type checks
    code = re.sub(r"'(?:[^']|'')*'", "''", body)
    for m in re.finditer(r"\b(FLOAT4?|FLOAT8|DOUBLE(?:\s+PRECISION)?|REAL)\b", code, flags=re.I):
        errors.append(f"{name}: forbidden floating type '{m.group(1)}'")
    for m in re.finditer(r"\b(\w+_AMT)\s+([A-Z_0-9]+)(\s*\(\s*\d+\s*(?:,\s*\d+\s*)?\))?", code, flags=re.I):
        col, typ, prec = m.group(1), m.group(2).upper(), (m.group(3) or "").replace(" ", "")
        if typ in SQL_TYPES and (typ != "NUMBER" or prec != "(18,2)"):
            errors.append(f"{name}: money column {col} must be NUMBER(18,2), found {typ}{prec}")
    if deployable:
        for _m in re.finditer(r"CREATE\s+OR\s+REPLACE\s+(?!TEMPORARY)(?:TRANSIENT\s+)?TABLE\b", code, flags=re.I):
            errors.append(f"{name}: CREATE OR REPLACE TABLE in a deployable script (use IF NOT EXISTS)")
    return errors


def lint_tree(sf_dir: Path) -> list[str]:
    deploy, manual = read_manifest(sf_dir / "deploy" / "manifest.txt")
    errors = check_manifest(sf_dir)
    for rel in deploy + manual:
        p = sf_dir / rel
        if p.exists():
            errors += lint_sql(p.read_text(), rel, deployable=rel in deploy)
    return errors


def main() -> int:
    errors = lint_tree(REPO / "snowflake")
    for e in errors:
        print("ERROR", e)
    n = len(list((REPO / "snowflake").rglob("*.sql")))
    print(f"SQL lint: {n} files, {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
