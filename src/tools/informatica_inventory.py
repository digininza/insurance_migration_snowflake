"""Assess Informatica PowerCenter XML exports for migration.

Parses `pmrep objectexport` XML (POWERMART > REPOSITORY > FOLDER > MAPPING/WORKFLOW),
counts transformations per mapping, flags the constructs that make a mapping hard
to migrate (SQL overrides, dynamic lookups, stored procedures, mapplets,
normalizers, SCD2 patterns), scores complexity and suggests the Snowflake target
pattern. Output feeds wave planning (docs/migration/MIGRATION_STRATEGY.md §2).

    python -m src.tools.informatica_inventory --exports informatica_legacy/exports \
        --out informatica_legacy/inventory/assessment.csv
"""
from __future__ import annotations

import argparse
import csv
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

# Effort weight per transformation type (calibrated on the first 40 mappings migrated).
WEIGHTS = {
    "Source Qualifier": 0.0,
    "Expression": 1.0,
    "Filter": 0.5,
    "Sorter": 0.5,
    "Sequence": 1.0,
    "Lookup Procedure": 2.0,
    "Router": 2.0,
    "Update Strategy": 2.0,
    "Aggregator": 2.0,
    "Joiner": 2.0,
    "Rank": 2.0,
    "Union Transformation": 1.0,
    "Normalizer": 3.0,
    "Mapplet": 3.0,
    "Stored Procedure": 4.0,
    "Java": 5.0,
    "Custom Transformation": 5.0,
    "XML Parser": 3.0,
}
DEFAULT_WEIGHT = 2.0
SQL_OVERRIDE_WEIGHT = 2.0
DYNAMIC_LOOKUP_WEIGHT = 1.0
SIMPLE_MAX, MEDIUM_MAX = 5.0, 15.0

SNOWFLAKE_PATTERN = {
    "Expression": "SELECT-list expressions (IFF/CASE/TRY_TO_*)",
    "Filter": "WHERE (count filtered rows into audit)",
    "Lookup Procedure": "LEFT JOIN + QUALIFY ROW_NUMBER() for 'first/last value' semantics; COALESCE(sk,-1)",
    "Router": "INSERT ALL WHEN … / CASE flag + quarantine table",
    "Update Strategy": "MERGE",
    "Aggregator": "GROUP BY (explicit MAX_BY/ANY_VALUE for non-grouped ports)",
    "Joiner": "JOIN (check master/detail outer semantics)",
    "Normalizer": "LATERAL FLATTEN / UNPIVOT",
    "Sequence": "SEQUENCE.NEXTVAL",
    "Sorter": "ORDER BY only where order matters",
    "Mapplet": "shared view / UDF",
    "Stored Procedure": "rewrite PL/SQL as Snowflake Scripting / inline SQL",
    "Rank": "QUALIFY RANK()",
}


@dataclass
class MappingAssessment:
    folder: str
    mapping: str
    workflow: str = ""
    transformation_counts: Counter = field(default_factory=Counter)
    sources: int = 0
    targets: int = 0
    sql_overrides: int = 0
    dynamic_lookups: int = 0
    truncate_target: bool = False
    parameters: list[str] = field(default_factory=list)

    @property
    def lookups(self) -> int:
        return self.transformation_counts.get("Lookup Procedure", 0)

    @property
    def is_scd2(self) -> bool:
        return ("SCD" in self.mapping.upper()) or self.transformation_counts.get("Update Strategy", 0) >= 2

    @property
    def score(self) -> float:
        s = sum(WEIGHTS.get(t, DEFAULT_WEIGHT) * n for t, n in self.transformation_counts.items())
        s += SQL_OVERRIDE_WEIGHT * self.sql_overrides + DYNAMIC_LOOKUP_WEIGHT * self.dynamic_lookups
        return round(s, 1)

    @property
    def complexity(self) -> str:
        if self.score <= SIMPLE_MAX:
            return "Simple"
        return "Medium" if self.score <= MEDIUM_MAX else "Complex"

    @property
    def target_pattern(self) -> str:
        c = self.transformation_counts
        if self.is_scd2:
            return "Stream + Task + SCD2 MERGE procedure"
        if c.get("Aggregator") and not c.get("Update Strategy"):
            return "Dynamic Table"
        if self.complexity == "Simple":
            if c.get("Normalizer"):
                return "ADF metadata row + RAW; STAGE SQL with UNPIVOT/FLATTEN"
            return "ADF metadata row + RAW; logic as STAGE view"
        return "Stream + Task + stored procedure (MERGE)"

    @property
    def construct_hints(self) -> str:
        return " | ".join(f"{t}: {SNOWFLAKE_PATTERN[t]}" for t in sorted(self.transformation_counts) if t in SNOWFLAKE_PATTERN)

    def as_row(self) -> dict:
        c = self.transformation_counts
        return {
            "folder": self.folder,
            "workflow": self.workflow,
            "mapping": self.mapping,
            "sources": self.sources,
            "targets": self.targets,
            "transformations": sum(c.values()),
            "lookups": self.lookups,
            "routers": c.get("Router", 0),
            "update_strategies": c.get("Update Strategy", 0),
            "aggregators": c.get("Aggregator", 0),
            "stored_procs": c.get("Stored Procedure", 0),
            "mapplets": c.get("Mapplet", 0),
            "normalizers": c.get("Normalizer", 0),
            "sql_overrides": self.sql_overrides,
            "dynamic_lookups": self.dynamic_lookups,
            "is_scd2": self.is_scd2,
            "truncate_target": self.truncate_target,
            "parameters": ";".join(self.parameters),
            "score": self.score,
            "complexity": self.complexity,
            "target_pattern": self.target_pattern,
            "construct_hints": self.construct_hints,
        }


OVERRIDE_ATTRS = {"Sql Query", "Lookup Sql Override", "User Defined Join"}


def parse_export(path: str | Path) -> list[MappingAssessment]:
    """Return one assessment per MAPPING in a PowerCenter XML export."""
    root = ET.parse(str(path)).getroot()
    results: list[MappingAssessment] = []
    for folder in root.iter("FOLDER"):
        fname = folder.get("NAME", "")
        session_map: dict[str, tuple[str, bool]] = {}
        for wf in folder.iter("WORKFLOW"):
            for sess in wf.iter("SESSION"):
                truncate = any(a.get("NAME") == "Truncate target table option" and a.get("VALUE") == "YES"
                               for a in sess.iter("ATTRIBUTE"))
                session_map[sess.get("MAPPINGNAME", "")] = (wf.get("NAME", ""), truncate)

        for m in folder.iter("MAPPING"):
            a = MappingAssessment(folder=fname, mapping=m.get("NAME", ""))
            for t in m.iter("TRANSFORMATION"):
                ttype = t.get("TYPE", "Unknown")
                a.transformation_counts[ttype] += 1
                for attr in t.iter("TABLEATTRIBUTE"):
                    name, value = attr.get("NAME"), (attr.get("VALUE") or "").strip()
                    if name in OVERRIDE_ATTRS and value:
                        a.sql_overrides += 1
                    if name == "Dynamic Lookup Cache" and value.upper() == "YES":
                        a.dynamic_lookups += 1
            for inst in m.iter("INSTANCE"):
                if inst.get("TYPE") == "SOURCE":
                    a.sources += 1
                elif inst.get("TYPE") == "TARGET":
                    a.targets += 1
            a.parameters = [v.get("NAME", "") for v in m.iter("MAPPINGVARIABLE")]
            a.workflow, a.truncate_target = session_map.get(a.mapping, ("", False))
            results.append(a)
    return results


def assess_directory(exports_dir: str | Path) -> list[MappingAssessment]:
    out: list[MappingAssessment] = []
    for p in sorted(Path(exports_dir).glob("*.xml")):
        out.extend(parse_export(p))
    return out


def write_csv(assessments: list[MappingAssessment], out_path: str | Path) -> None:
    rows = [a.as_row() for a in assessments]
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else ["mapping"])
        w.writeheader()
        w.writerows(rows)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--exports", default="informatica_legacy/exports")
    ap.add_argument("--out", default="informatica_legacy/inventory/assessment.csv")
    args = ap.parse_args(argv)
    res = assess_directory(args.exports)
    write_csv(res, args.out)
    by = Counter(a.complexity for a in res)
    print(f"{len(res)} mappings assessed → {args.out}  ({dict(by)})")
    for a in res:
        print(f"  {a.complexity:8} {a.score:5}  {a.folder}/{a.mapping}  → {a.target_pattern}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
