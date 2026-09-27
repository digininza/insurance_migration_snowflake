PY ?= .venv/bin/python

.PHONY: venv test lint assess generate recon validate all

venv:
	python3 -m venv .venv && .venv/bin/pip install -q -r requirements-dev.txt

test:
	$(PY) -m pytest

lint:
	$(PY) -m ruff check src tests

assess:
	$(PY) -m src.tools.informatica_inventory --exports informatica_legacy/exports --out informatica_legacy/inventory/assessment.csv

generate:
	$(PY) -m src.datagen.generate --out data --seed 42 --members 2000 --claims 8000

recon: generate
	$(PY) -m src.recon.reconcile --data data --report data/recon_report.md

validate:
	$(PY) -m src.tools.adf_validate
	$(PY) -m src.tools.sql_manifest

all: lint validate test
