"""数据管道编排：按层执行 SQL，落审计表，导出分析结果。"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from datetime import datetime

from .config import Config
from .warehouse import Warehouse, new_run_id

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class Step:
    name: str
    layer: str          # 该步骤主要产出的 schema，用于统计行数
    sql_file: str


STEPS: tuple[Step, ...] = (
    Step("ddl", "meta", "00_ddl.sql"),
    Step("ods_load", "ods", "10_ods.sql"),
    Step("dwd_model", "dwd", "20_dwd.sql"),
    Step("dws_aggregate", "dws", "30_dws.sql"),
    Step("ads_metrics", "ads", "40_ads.sql"),
    Step("quality_checks", "quality", "50_quality.sql"),
)

# 需要导出为 CSV 的分析结果（同时用于报表与项目书取数）
EXPORT_TABLES = (
    ("ads", "kpi_overview"),
    ("ads", "kpi_monthly"),
    ("ads", "rfm_summary"),
    ("ads", "rfm_scored"),
    ("ads", "cohort_matrix"),
    ("ads", "delivery_sla_by_state"),
    ("ads", "category_performance"),
    ("ads", "seller_scorecard"),
    ("ads", "payment_mix"),
    ("ads", "order_status_distribution"),
)


class Pipeline:
    def __init__(self, cfg: Config, warehouse: Warehouse | None = None) -> None:
        self.cfg = cfg
        self.wh = warehouse or Warehouse(cfg.paths.warehouse)
        self.run_id = new_run_id()

    def run(self, only: list[str] | None = None) -> dict:
        self.cfg.paths.reports.mkdir(parents=True, exist_ok=True)
        variables = {"RAW_DIR": str(self.cfg.paths.raw)}
        results: list[dict] = []

        logger.info("run_id=%s 开始执行管道，共 %d 步", self.run_id, len(STEPS))
        for step in STEPS:
            if only and step.name not in only:
                continue
            sql_path = self.cfg.sql_file(step.sql_file)
            started = datetime.now()
            t0 = time.perf_counter()
            logger.info("[%s] 执行 %s", step.layer, step.sql_file)
            try:
                self.wh.run_sql_file(sql_path, variables)
            except Exception as exc:  # 失败要留痕，方便定位是哪一层挂的
                cost = (time.perf_counter() - t0) * 1000
                self.wh.log_run(self.run_id, step.layer, step.name, started, cost, 0, "FAILED", str(exc)[:500])
                logger.error("[%s] 失败: %s", step.layer, exc)
                raise
            cost = (time.perf_counter() - t0) * 1000
            rows = self.wh.count_rows(step.layer) if step.layer != "meta" else 0
            self.wh.log_run(self.run_id, step.layer, step.name, started, cost, rows, "SUCCESS")
            logger.info("[%s] 完成，%d 行，%.1f ms", step.layer, rows, cost)
            results.append({"layer": step.layer, "step": step.name, "rows": rows, "ms": round(cost, 1)})

        # 把水位线推进到快照日，作为下一次增量的起点
        self._update_watermark()
        return {"run_id": self.run_id, "steps": results}

    def _update_watermark(self) -> None:
        try:
            snapshot = self.wh.scalar("SELECT snapshot_ts FROM meta.snapshot")
            if snapshot:
                self.wh.execute(
                    """
                    INSERT INTO meta.watermarks (table_name, watermark_ts, updated_at)
                    VALUES ('dws.order_wide', ?, CURRENT_TIMESTAMP)
                    ON CONFLICT (table_name) DO UPDATE
                    SET watermark_ts = excluded.watermark_ts, updated_at = excluded.updated_at
                    """,
                    [snapshot],
                )
        except Exception as exc:  # 水位线不是主链路，失败只告警
            logger.warning("水位线更新失败: %s", exc)

    def export(self) -> list[str]:
        out_dir = self.cfg.paths.reports / "data"
        out_dir.mkdir(parents=True, exist_ok=True)
        written: list[str] = []
        for schema, table in EXPORT_TABLES:
            df = self.wh.query(f'SELECT * FROM "{schema}"."{table}"')
            path = out_dir / f"{table}.csv"
            df.to_csv(path, index=False, encoding="utf-8-sig")
            written.append(str(path))
            logger.info("导出 %s.%s -> %s (%d 行)", schema, table, path.name, len(df))
        return written

    def quality_summary(self):
        return self.wh.query(
            """
            SELECT check_name, layer, severity, failed_rows, threshold, passed
            FROM quality.check_results
            ORDER BY passed, severity, check_name
            """
        )

    def close(self) -> None:
        self.wh.close()
