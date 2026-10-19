"""命令行入口：python -m star_pipeline <command>"""

from __future__ import annotations

import argparse
import logging
import sys
import time
from pathlib import Path

from .config import PROJECT_ROOT, load_config
from .pipeline import Pipeline
from .report import build_report
from .warehouse import Warehouse

logger = logging.getLogger("star_pipeline")


def _setup_logging(verbose: bool = False) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    log_dir = PROJECT_ROOT / "logs"
    log_dir.mkdir(exist_ok=True)
    handlers.append(logging.FileHandler(log_dir / "pipeline.log", encoding="utf-8"))
    logging.basicConfig(
        level=level,
        format="%(asctime)s | %(levelname)-7s | %(message)s",
        datefmt="%H:%M:%S",
        handlers=handlers,
        force=True,
    )
    logging.getLogger("matplotlib").setLevel(logging.WARNING)


def verify_data(cfg) -> bool:
    """检查原始文件是否齐全、是否像被截断。返回是否全部通过。"""
    missing, small = [], []
    for filename in cfg.source.files:
        path = cfg.paths.raw / filename
        if not path.exists():
            missing.append(filename)
        elif path.stat().st_size < 1024:
            small.append(f"{filename} ({path.stat().st_size}B)")
    if missing:
        logger.error("缺少原始文件: %s", ", ".join(missing))
    if small:
        logger.error("文件疑似损坏/被拦截: %s", ", ".join(small))
    if not missing and not small:
        total = sum((cfg.paths.raw / f).stat().st_size for f in cfg.source.files)
        logger.info("原始数据齐全，共 %d 个文件，%.1f MB", len(cfg.source.files), total / 1024 / 1024)
        return True
    logger.info("可执行以下命令从 GitHub 重新获取：python scripts/fetch_data.py")
    return False


def cmd_run(cfg, args) -> int:
    if not verify_data(cfg):
        return 2
    pipe = Pipeline(cfg)
    started = time.perf_counter()
    result = pipe.run()
    elapsed = time.perf_counter() - started

    q = pipe.quality_summary()
    failed = q[q["passed"] == False]  # noqa: E712
    passed = int(q["passed"].sum())
    logger.info("质量校验：%d/%d 通过", passed, len(q))
    if len(failed):
        for _, row in failed.iterrows():
            logger.warning("未通过 %s（失败 %s 行，阈值 %s）", row["check_name"], row["failed_rows"], row["threshold"])
    if args.export:
        pipe.export()
    logger.info("管道完成，run_id=%s，总耗时 %.1f 秒", result["run_id"], elapsed)
    pipe.close()

    hard_fail = failed[failed["severity"] == "ERROR"]
    if len(hard_fail) and not args.ignore_quality_gate:
        logger.error("存在 ERROR 级质量失败，阻断发布（可用 --ignore-quality-gate 跳过）")
        return 1
    return 0


def cmd_report(cfg, args) -> int:
    wh = Warehouse(cfg.paths.warehouse)
    try:
        summary = build_report(cfg, wh)
        kpi = summary["kpi"]
        logger.info("累计 GMV R$ %s，订单 %s，客户 %s",
                    f"{kpi.get('gmv_total', 0):,.0f}", f"{kpi.get('orders_total', 0):,.0f}", f"{kpi.get('customers_total', 0):,.0f}")
        logger.info("看板路径：%s", cfg.paths.reports / "dashboard.html")
    finally:
        wh.close()
    return 0


def cmd_all(cfg, args) -> int:
    code = cmd_run(cfg, args)
    if code != 0 and not args.ignore_quality_gate:
        return code
    return cmd_report(cfg, args)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="star_pipeline", description="NEW_STAR 电商数仓管道")
    parser.add_argument("--config", default=None, help="配置文件路径，默认 config/pipeline.yaml")
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    p_run = sub.add_parser("run", help="执行取数到质量校验的全流程")
    p_run.add_argument("--no-export", dest="export", action="store_false", help="不导出 CSV")
    p_run.add_argument("--ignore-quality-gate", action="store_true", help="ERROR 级校验失败也不阻断")
    p_run.set_defaults(func=cmd_run, export=True)

    p_report = sub.add_parser("report", help="生成图表与 HTML 看板")
    p_report.set_defaults(func=cmd_report, export=True, ignore_quality_gate=False)

    p_all = sub.add_parser("all", help="run + report")
    p_all.add_argument("--ignore-quality-gate", action="store_true")
    p_all.set_defaults(func=cmd_all, export=True)

    p_verify = sub.add_parser("verify-data", help="检查原始数据完整性")
    p_verify.set_defaults(func=lambda cfg, args: 0 if verify_data(cfg) else 2, export=False, ignore_quality_gate=False)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    _setup_logging(args.verbose)
    cfg = load_config(args.config)
    return args.func(cfg, args)


if __name__ == "__main__":
    raise SystemExit(main())
