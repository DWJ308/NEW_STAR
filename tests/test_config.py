"""配置加载与数据校验的单元测试（不依赖真实数据）。"""

from __future__ import annotations

import pytest

from star_pipeline.config import load_config
from star_pipeline.pipeline import STEPS


def test_load_config_defaults():
    cfg = load_config()
    assert cfg.name == "NEW_STAR"
    assert cfg.paths.warehouse.name == "star.duckdb"
    assert len(cfg.source.files) == 8
    assert cfg.min_row_counts["ods.orders"] >= 99000


def test_load_config_missing_file(tmp_path):
    with pytest.raises(FileNotFoundError):
        load_config(tmp_path / "nope.yaml")


def test_step_order_follows_warehouse_layers():
    layers = [s.layer for s in STEPS]
    assert layers.index("ods") < layers.index("dwd") < layers.index("dws") < layers.index("ads") < layers.index("quality")
