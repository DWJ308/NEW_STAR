"""DuckDB 连接与 SQL 执行封装：占位符替换、耗时统计、运行审计。"""

from __future__ import annotations

import logging
import time
import uuid
from datetime import datetime
from pathlib import Path

import duckdb

logger = logging.getLogger(__name__)


class Warehouse:
    """薄封装：所有 SQL 都从这里进出，便于统一打点与后续切换引擎（PG/Spark）。"""

    def __init__(self, db_path: Path) -> None:
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.con = duckdb.connect(str(self.db_path))
        # 列存引擎的常用调优：限制线程避免和本机其他任务抢核，开启进度条便于观察大表
        self.con.execute("SET preserve_insertion_order = false;")

    # ---------------- 基础执行 ----------------
    def execute(self, sql: str, params: list | None = None) -> None:
        if params is None:
            self.con.execute(sql)
        else:
            self.con.execute(sql, params)

    def query(self, sql: str):
        return self.con.execute(sql).df()

    def scalar(self, sql: str):
        row = self.con.execute(sql).fetchone()
        return row[0] if row else None

    def close(self) -> None:
        self.con.close()

    # ---------------- 文件级执行 ----------------
    def run_sql_file(self, path: Path, variables: dict[str, str] | None = None) -> float:
        """执行一个 .sql 文件，返回毫秒耗时。"""
        if not Path(path).exists():
            raise FileNotFoundError(f"SQL 文件不存在: {path}")
        sql = Path(path).read_text(encoding="utf-8")
        for key, value in (variables or {}).items():
            sql = sql.replace("{{" + key + "}}", str(value).replace("\\", "/"))

        started = time.perf_counter()
        self.con.execute(sql)
        return (time.perf_counter() - started) * 1000

    # ---------------- 审计 ----------------
    def count_rows(self, schema: str) -> int:
        """统计某个 schema 下所有表的行数总和，作为该层的产出规模。"""
        tables = self.con.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = ?", [schema]
        ).fetchall()
        total = 0
        for (table,) in tables:
            total += int(self.scalar(f'SELECT COUNT(*) FROM "{schema}"."{table}"') or 0)
        return total

    def list_tables(self, schema: str) -> list[str]:
        rows = self.con.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = ? ORDER BY table_name",
            [schema],
        ).fetchall()
        return [r[0] for r in rows]

    def log_run(
        self,
        run_id: str,
        layer: str,
        step: str,
        started: datetime,
        duration_ms: float,
        row_count: int,
        status: str,
        error: str | None = None,
    ) -> None:
        self.con.execute(
            """
            INSERT INTO meta.pipeline_runs
            (run_id, layer, step_name, started_at, finished_at, duration_ms, row_count, status, error_message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [run_id, layer, step, started, datetime.now(), int(duration_ms), row_count, status, error],
        )

    def reset_runs(self) -> None:
        self.con.execute("DELETE FROM meta.pipeline_runs")


def new_run_id() -> str:
    return f"{datetime.now():%Y%m%d%H%M%S}-{uuid.uuid4().hex[:6]}"
