PY := python
PIP := $(PY) -m pip

.PHONY: help setup fetch run report all test lint clean

help:
	@echo "setup   创建虚拟环境并安装依赖"
	@echo "fetch   从 GitHub 下载开源数据集"
	@echo "run     执行 ETL -> 建模 -> 指标 -> 质量校验"
	@echo "report  生成图表与 dashboard.html"
	@echo "all     run + report"
	@echo "test    运行测试套件"

setup:
	$(PY) -m venv .venv
	.venv/Scripts/$(PIP) install -r requirements.txt

fetch:
	PYTHONPATH=src $(PY) scripts/fetch_data.py

run:
	PYTHONPATH=src $(PY) -m star_pipeline run

report:
	PYTHONPATH=src $(PY) -m star_pipeline report

all:
	PYTHONPATH=src $(PY) -m star_pipeline all

test:
	PYTHONPATH=src $(PY) -m pytest tests/ -q

clean:
	rm -rf data/warehouse data/parquet reports/*.png reports/data .pytest_cache
