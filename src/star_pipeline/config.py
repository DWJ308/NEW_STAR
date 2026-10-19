"""配置加载：把 pipeline.yaml 收敛成一个不可变对象，避免运行期被意外改写。"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

PROJECT_ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Paths:
    raw: Path
    warehouse: Path
    reports: Path
    sql: Path
    parquet: Path


@dataclass(frozen=True)
class Source:
    provider: str
    repo: str
    ref: str
    base_url: str
    license: str
    files: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class Config:
    name: str
    title: str
    paths: Paths
    source: Source
    min_row_counts: dict[str, int]
    thresholds: dict[str, float]

    def sql_file(self, name: str) -> Path:
        return self.paths.sql / name


def load_config(config_path: str | Path | None = None) -> Config:
    path = Path(config_path) if config_path else PROJECT_ROOT / "config" / "pipeline.yaml"
    if not path.is_absolute():
        path = PROJECT_ROOT / path
    if not path.exists():
        raise FileNotFoundError(f"找不到配置文件: {path}")

    raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    project = raw["project"]
    p = raw["paths"]
    s = raw["source"]
    quality = raw.get("quality", {})

    def resolve(value: str) -> Path:
        candidate = Path(value)
        return candidate if candidate.is_absolute() else PROJECT_ROOT / candidate

    return Config(
        name=project["name"],
        title=project["title"],
        paths=Paths(
            raw=resolve(p["raw"]),
            warehouse=resolve(p["warehouse"]),
            reports=resolve(p["reports"]),
            sql=resolve(p["sql"]),
            parquet=resolve(p["parquet"]),
        ),
        source=Source(
            provider=s["provider"],
            repo=s["repo"],
            ref=s["ref"],
            base_url=s["base_url"],
            license=s.get("license", ""),
            files=s.get("files", {}),
        ),
        min_row_counts=quality.get("min_row_counts", {}),
        thresholds=quality.get("thresholds", {}),
    )
