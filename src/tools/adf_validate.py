"""Static checks for the ADF factory JSON in /adf (run in CI before ARM export).

1. Every LinkedService/Dataset/Pipeline/IntegrationRuntime reference resolves.
2. No inline secrets: secret-bearing properties must be AzureKeyVaultSecret references
   (or absent — managed identity / key-pair via KV).
3. Every ctl.source_object target_path (metadata seed) has a Snowpipe watching
   raw/incremental/<target_path>/ — otherwise files would land and never load.

    python -m src.tools.adf_validate
"""
from __future__ import annotations

import csv
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SECRET_KEYS = {"password", "privateKey", "privateKeyContent", "privateKeyPassphrase", "connectionString",
               "accountKey", "sasUri", "sasToken", "servicePrincipalKey", "servicePrincipalCredential", "clientSecret"}
REF_TYPES = {
    "LinkedServiceReference": "linkedService",
    "DatasetReference": "dataset",
    "PipelineReference": "pipeline",
    "IntegrationRuntimeReference": "integrationRuntime",
}


def load_factory(adf_dir: Path) -> dict[str, dict[str, dict]]:
    objs: dict[str, dict[str, dict]] = {k: {} for k in ["linkedService", "dataset", "pipeline", "trigger", "integrationRuntime", "factory"]}
    for kind in objs:
        for p in sorted((adf_dir / kind).glob("*.json")):
            doc = json.loads(p.read_text())
            objs[kind][doc["name"]] = doc
    return objs


def _walk(node, path=""):
    if isinstance(node, dict):
        yield path, node
        for k, v in node.items():
            yield from _walk(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from _walk(v, f"{path}[{i}]")


def check_references(objs) -> list[str]:
    errors = []
    for kind, items in objs.items():
        for name, doc in items.items():
            for path, node in _walk(doc):
                t = node.get("type")
                if t in REF_TYPES and "referenceName" in node:
                    target_kind = REF_TYPES[t]
                    ref = node["referenceName"]
                    if target_kind == "integrationRuntime" and ref == "AutoResolveIntegrationRuntime":
                        continue
                    if ref not in objs[target_kind]:
                        errors.append(f"{kind}/{name}{path}: {t} '{ref}' not found")
    return errors


def check_no_inline_secrets(objs) -> list[str]:
    errors = []
    for name, doc in objs["linkedService"].items():
        for path, node in _walk(doc):
            for k, v in node.items():
                if k in SECRET_KEYS:
                    if not (isinstance(v, dict) and v.get("type") == "AzureKeyVaultSecret"):
                        errors.append(f"linkedService/{name}{path}.{k}: secret must be an AzureKeyVaultSecret reference")
                if isinstance(v, str) and re.search(r"(?i)(password|pwd|accountkey|sig)=", v):
                    errors.append(f"linkedService/{name}{path}.{k}: inline credential in string")
    return errors


def check_pipe_coverage(seed_csv: Path, pipes_sql: Path) -> list[str]:
    errors = []
    sql = pipes_sql.read_text()
    watched = set(re.findall(r"STG_ADLS_RAW/incremental/([a-z0-9_]+/[a-z0-9_]+)/", sql, flags=re.I))
    with open(seed_csv, newline="") as fh:
        for row in csv.DictReader(fh):
            if row["load_type"] in {"INCREMENTAL", "FILE", "KEYS_ONLY"} and row["target_path"] not in watched:
                errors.append(f"metadata target_path '{row['target_path']}' ({row['table_name']}) has no Snowpipe prefix")
    return errors


def validate(repo: Path = REPO) -> list[str]:
    objs = load_factory(repo / "adf")
    return (check_references(objs) + check_no_inline_secrets(objs)
            + check_pipe_coverage(repo / "metadata" / "source_object_seed.csv", repo / "snowflake" / "03_raw" / "02_pipes.sql"))


def main() -> int:
    errors = validate()
    for e in errors:
        print("ERROR", e)
    objs = load_factory(REPO / "adf")
    print(f"ADF validation: {sum(len(v) for v in objs.values())} objects, {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
