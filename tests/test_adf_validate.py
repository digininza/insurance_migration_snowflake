import json
import shutil
from pathlib import Path

from src.tools import adf_validate

REPO = Path(__file__).resolve().parents[1]


def test_repository_factory_is_valid():
    assert adf_validate.validate(REPO) == []


def _copy_repo(tmp_path: Path) -> Path:
    for d in ["adf", "metadata"]:
        shutil.copytree(REPO / d, tmp_path / d)
    (tmp_path / "snowflake" / "03_raw").mkdir(parents=True)
    shutil.copy(REPO / "snowflake" / "03_raw" / "02_pipes.sql", tmp_path / "snowflake" / "03_raw" / "02_pipes.sql")
    return tmp_path


def test_inline_password_is_rejected(tmp_path):
    root = _copy_repo(tmp_path)
    p = root / "adf" / "linkedService" / "LS_SqlServer_Claims.json"
    doc = json.loads(p.read_text())
    doc["properties"]["typeProperties"]["password"] = "Winter2026!"
    p.write_text(json.dumps(doc))
    errors = adf_validate.validate(root)
    assert any("AzureKeyVaultSecret" in e for e in errors)


def test_dangling_dataset_reference_is_rejected(tmp_path):
    root = _copy_repo(tmp_path)
    (root / "adf" / "dataset" / "DS_ADLS_Parquet.json").unlink()
    errors = adf_validate.validate(root)
    assert any("DS_ADLS_Parquet" in e and "not found" in e for e in errors)


def test_target_path_without_pipe_is_rejected(tmp_path):
    root = _copy_repo(tmp_path)
    seed = root / "metadata" / "source_object_seed.csv"
    seed.write_text(seed.read_text().replace("claims/claim_line,", "claims/clm_line,"))
    errors = adf_validate.validate(root)
    assert any("claims/clm_line" in e for e in errors)


def test_every_pipeline_has_a_folder_and_description():
    for p in (REPO / "adf" / "pipeline").glob("*.json"):
        props = json.loads(p.read_text())["properties"]
        assert props.get("description"), p.name
        assert props.get("folder", {}).get("name"), p.name
