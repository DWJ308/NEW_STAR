"""报表生成：matplotlib 图表 + 自包含 HTML 看板（不依赖任何外网资源）。"""

from __future__ import annotations

import base64
import io
import json
import logging
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager, rcParams  # noqa: E402

from .config import Config  # noqa: E402
from .warehouse import Warehouse  # noqa: E402

logger = logging.getLogger(__name__)

# 配色：主色深蓝 + 辅助灰，整体保持克制，避免花哨
INK = "#1F3A5F"
ACCENT = "#D85A30"
MUTED = "#8A8F98"
GRID = "#E6E3DC"
FILL = "#8FB3D9"


def _setup_font() -> str:
    candidates = ["Microsoft YaHei", "SimHei", "Noto Sans CJK SC", "Source Han Sans SC", "PingFang SC"]
    available = {f.name for f in font_manager.fontManager.ttflist}
    for name in candidates:
        if name in available:
            rcParams["font.sans-serif"] = [name]
            rcParams["axes.unicode_minus"] = False
            return name
    logger.warning("未找到中文字体，图表将使用默认字体（可能出现方块）")
    return "DejaVu Sans"


def _style(ax) -> None:
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color(GRID)
    ax.spines["bottom"].set_color(GRID)
    ax.tick_params(colors="#5F5E5A", labelsize=9)
    ax.grid(axis="y", color=GRID, linewidth=0.8, alpha=0.7)
    ax.set_axisbelow(True)


def _save(fig, path: Path) -> Path:
    fig.tight_layout()
    fig.savefig(path, dpi=180, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    logger.info("图表已生成: %s", path.name)
    return path


# --------------------------------------------------------------------------- #
# 各主题图表
# --------------------------------------------------------------------------- #
def chart_monthly(wh: Warehouse, out: Path) -> Path:
    df = wh.query(
        # 2018-09 起源数据临近采集截止，订单量骤降，属于截断而非业务下滑，趋势图予以剔除
        "SELECT year_month, gmv, orders FROM ads.kpi_monthly "
        "WHERE year_month >= '2017-01' AND year_month <= '2018-08' ORDER BY year_month"
    )
    fig, ax1 = plt.subplots(figsize=(9, 4.2))
    ax1.bar(df["year_month"], df["gmv"], color=FILL, width=0.68, label="GMV")
    ax1.set_ylabel("GMV (BRL)", color=INK, fontsize=10)
    ax1.set_ylim(0, df["gmv"].max() * 1.25)
    _style(ax1)
    ax2 = ax1.twinx()
    ax2.plot(df["year_month"], df["orders"], color=INK, marker="o", markersize=3.5, linewidth=1.6, label="订单量")
    ax2.set_ylabel("订单量", color=INK, fontsize=10)
    ax2.spines["top"].set_visible(False)
    ax2.tick_params(colors="#5F5E5A", labelsize=9)
    ax1.set_xticks(range(len(df)))
    ax1.set_xticklabels(df["year_month"], rotation=45, ha="right", fontsize=8)
    ax1.set_title("月度 GMV 与订单量", fontsize=12, color=INK, pad=12)
    return _save(fig, out / "01_monthly_gmv.png")


def chart_rfm(wh: Warehouse, out: Path) -> Path:
    df = wh.query("SELECT segment, gmv_share, customers FROM ads.rfm_summary ORDER BY gmv_share")
    fig, ax = plt.subplots(figsize=(8, 3.8))
    colors = [ACCENT if s in ("重要价值客户", "重要挽留客户") else FILL for s in df["segment"]]
    bars = ax.barh(df["segment"], df["gmv_share"] * 100, color=colors, height=0.6)
    for bar, share, cnt in zip(bars, df["gmv_share"], df["customers"]):
        ax.text(bar.get_width() + 0.6, bar.get_y() + bar.get_height() / 2,
                f"{share*100:.1f}%  ({cnt:,} 人)", va="center", fontsize=9, color="#5F5E5A")
    ax.set_xlabel("GMV 贡献占比 (%)", fontsize=10, color=INK)
    ax.set_xlim(0, df["gmv_share"].max() * 100 * 1.32)
    _style(ax)
    ax.grid(axis="y", visible=False)
    ax.set_title("RFM 客户分群：谁在贡献收入", fontsize=12, color=INK, pad=12)
    return _save(fig, out / "02_rfm_segments.png")


def chart_cohort(wh: Warehouse, out: Path) -> Path:
    df = wh.query(
        """
        SELECT cohort_month, cohort_size, m1, m2, m3, m4, m5, m6
        FROM ads.cohort_matrix
        WHERE cohort_size >= 200 AND cohort_month >= DATE '2017-01-01'
        ORDER BY cohort_month
        """
    )
    matrix = df[["m1", "m2", "m3", "m4", "m5", "m6"]].fillna(0) * 100
    fig, ax = plt.subplots(figsize=(7.6, 4.2))
    im = ax.imshow(matrix.values, cmap="Blues", aspect="auto", vmin=0, vmax=3)
    ax.set_xticks(range(6))
    ax.set_xticklabels(["M+1", "M+2", "M+3", "M+4", "M+5", "M+6"], fontsize=9)
    ax.set_yticks(range(len(df)))
    ax.set_yticklabels([str(m)[:7] for m in df["cohort_month"]], fontsize=8)
    for i in range(matrix.shape[0]):
        for j in range(matrix.shape[1]):
            ax.text(j, i, f"{matrix.values[i, j]:.2f}", ha="center", va="center", fontsize=8, color="#2C2C2A")
    ax.set_title("同期群留存率（首购月 → 后续月，%）", fontsize=12, color=INK, pad=12)
    ax.set_xlabel("相对首购月的偏移月", fontsize=10, color=INK)
    fig.colorbar(im, ax=ax, fraction=0.03, pad=0.02)
    return _save(fig, out / "03_cohort_retention.png")


def chart_delivery(wh: Warehouse, out: Path) -> Path:
    df = wh.query(
        """
        SELECT state, avg_delivery_days, late_rate, delivered_orders
        FROM ads.delivery_sla_by_state ORDER BY delivered_orders DESC LIMIT 12
        """
    )
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.scatter(df["avg_delivery_days"], df["late_rate"] * 100,
               s=df["delivered_orders"] / 220, color=FILL, edgecolor=INK, linewidth=0.8, alpha=0.85)
    for _, row in df.iterrows():
        ax.annotate(row["state"], (row["avg_delivery_days"], row["late_rate"] * 100),
                    textcoords="offset points", xytext=(6, 5), fontsize=9, color=INK)
    ax.axhline(df["late_rate"].mean() * 100, color=ACCENT, linestyle="--", linewidth=1)
    ax.text(df["avg_delivery_days"].min(), df["late_rate"].mean() * 100 + 0.25,
            "全国平均延误率", fontsize=8.5, color=ACCENT)
    ax.set_xlabel("平均配送天数", fontsize=10, color=INK)
    ax.set_ylabel("延误率 (%)", fontsize=10, color=INK)
    _style(ax)
    ax.set_title("各州配送时效 vs 延误率（气泡大小 = 订单量）", fontsize=12, color=INK, pad=12)
    return _save(fig, out / "04_delivery_sla.png")


def chart_pareto(wh: Warehouse, out: Path) -> Path:
    df = wh.query("SELECT category, gmv, gmv_cumulative_share FROM ads.category_performance ORDER BY gmv_rank LIMIT 20")
    fig, ax1 = plt.subplots(figsize=(9, 4.2))
    ax1.bar(range(len(df)), df["gmv"], color=FILL, width=0.68)
    ax1.set_ylabel("GMV (BRL)", fontsize=10, color=INK)
    _style(ax1)
    ax2 = ax1.twinx()
    ax2.plot(range(len(df)), df["gmv_cumulative_share"] * 100, color=INK, marker="o", markersize=3, linewidth=1.6)
    ax2.axhline(80, color=ACCENT, linestyle="--", linewidth=1)
    ax2.set_ylabel("累计占比 (%)", fontsize=10, color=INK)
    ax2.set_ylim(0, 105)
    ax2.spines["top"].set_visible(False)
    ax2.tick_params(colors="#5F5E5A", labelsize=9)
    ax1.set_xticks(range(len(df)))
    ax1.set_xticklabels([c.replace("_", " ")[:16] for c in df["category"]], rotation=55, ha="right", fontsize=7.5)
    ax1.set_title("品类帕累托：前 20 品类贡献结构", fontsize=12, color=INK, pad=12)
    return _save(fig, out / "05_category_pareto.png")


def chart_payment(wh: Warehouse, out: Path) -> Path:
    df = wh.query("SELECT payment_types, orders FROM ads.payment_mix ORDER BY orders DESC LIMIT 6")
    fig, ax = plt.subplots(figsize=(7.2, 3.2))
    bars = ax.bar(df["payment_types"], df["orders"], color=FILL, width=0.55)
    for bar, cnt in zip(bars, df["orders"]):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height(), f"{cnt:,}",
                ha="center", va="bottom", fontsize=9, color="#5F5E5A")
    _style(ax)
    ax.set_ylabel("订单数", fontsize=10, color=INK)
    ax.set_title("支付方式结构", fontsize=12, color=INK, pad=12)
    return _save(fig, out / "06_payment_mix.png")


# --------------------------------------------------------------------------- #
# HTML 看板
# --------------------------------------------------------------------------- #
def _img_tag(path: Path) -> str:
    b64 = base64.b64encode(path.read_bytes()).decode("ascii")
    return f'<img src="data:image/png;base64,{b64}" alt="{path.stem}">'


def _fmt(value, digits=0) -> str:
    try:
        if digits == 0:
            return f"{value:,.0f}"
        return f"{value:,.{digits}f}"
    except (TypeError, ValueError):
        return str(value)


def _table(df, cols: list[tuple[str, str, int]], max_rows: int = 10) -> str:
    head = "".join(f"<th>{label}</th>" for _, label, _ in cols)
    body = []
    for _, row in df.head(max_rows).iterrows():
        cells = []
        for key, _, digits in cols:
            val = row[key]
            if isinstance(val, float):
                cells.append(f"<td class='num'>{_fmt(val, digits)}</td>")
            else:
                cells.append(f"<td>{val}</td>")
        body.append("<tr>" + "".join(cells) + "</tr>")
    return f"<table><thead><tr>{head}</tr></thead><tbody>{''.join(body)}</tbody></table>"


def build_report(cfg: Config, wh: Warehouse) -> dict:
    reports = cfg.paths.reports
    reports.mkdir(parents=True, exist_ok=True)
    font = _setup_font()

    charts = [
        ("01 经营趋势", "GMV 与订单量随时间的变化，用于判断增长是否健康。", chart_monthly(wh, reports)),
        ("02 客户分层", "RFM 分群看收入集中度：少数高价值客户贡献了多少 GMV。", chart_rfm(wh, reports)),
        ("03 留存", "同期群留存率，反映复购能力与生命周期价值。", chart_cohort(wh, reports)),
        ("04 履约体验", "各州配送时效与延误率，定位体验短板。", chart_delivery(wh, reports)),
        ("05 品类结构", "帕累托曲线，判断收入是否过度依赖少数品类。", chart_pareto(wh, reports)),
        ("06 支付结构", "支付方式分布，辅助判断分期与结算策略。", chart_payment(wh, reports)),
    ]

    kpi = wh.query("SELECT * FROM ads.kpi_overview").iloc[0]
    monthly = wh.query("SELECT * FROM ads.kpi_monthly WHERE year_month <= '2018-08' ORDER BY year_month DESC LIMIT 6")
    rfm = wh.query("SELECT * FROM ads.rfm_summary ORDER BY gmv_share DESC")
    cats = wh.query("SELECT category, gmv, gmv_share, avg_review FROM ads.category_performance ORDER BY gmv_rank LIMIT 10")
    states = wh.query(
        "SELECT state, delivered_orders, avg_delivery_days, late_rate, avg_review FROM ads.delivery_sla_by_state ORDER BY late_rate DESC LIMIT 8"
    )

    cards = [
        ("累计 GMV", f"R$ {_fmt(kpi['gmv_total']/1e6, 2)} M"),
        ("订单量", _fmt(kpi["orders_total"])),
        ("客单价 AOV", f"R$ {_fmt(kpi['aov'], 2)}"),
        ("客户数", _fmt(kpi["customers_total"])),
        ("复购率", f"{kpi['repeat_rate']*100:.2f}%"),
        ("平均配送", f"{_fmt(kpi['avg_delivery_days'], 1)} 天"),
        ("延误率", f"{kpi['late_rate']*100:.2f}%"),
        ("平均评分", f"{_fmt(kpi['avg_review'], 2)} / 5"),
    ]
    card_html = "".join(
        f"<div class='card'><div class='k'>{label}</div><div class='v'>{value}</div></div>" for label, value in cards
    )

    sections = "".join(
        f"<section><h2>{title}</h2><p class='desc'>{desc}</p>{_img_tag(path)}</section>" for title, desc, path in charts
    )

    html = f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NEW_STAR · Olist 电商经营分析看板</title>
<style>
  :root {{ --ink:#1F3A5F; --text:#2C2C2A; --muted:#6E6D69; --line:#E6E3DC; --bg:#FBFAF7; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--text);
         font-family:"Microsoft YaHei","PingFang SC",-apple-system,"Segoe UI",sans-serif; line-height:1.65; }}
  .wrap {{ max-width:1080px; margin:0 auto; padding:48px 24px 64px; }}
  header {{ border-bottom:2px solid var(--ink); padding-bottom:20px; margin-bottom:32px; }}
  h1 {{ font-size:26px; font-weight:600; color:var(--ink); margin:0 0 8px; letter-spacing:.5px; }}
  .sub {{ color:var(--muted); font-size:13px; }}
  .grid {{ display:grid; grid-template-columns:repeat(4,1fr); gap:14px; margin:0 0 36px; }}
  .card {{ background:#fff; border:1px solid var(--line); border-radius:10px; padding:16px 18px; }}
  .card .k {{ font-size:12px; color:var(--muted); margin-bottom:6px; }}
  .card .v {{ font-size:21px; font-weight:600; color:var(--ink); font-variant-numeric:tabular-nums; }}
  section {{ background:#fff; border:1px solid var(--line); border-radius:12px; padding:22px 24px; margin-bottom:22px; }}
  h2 {{ font-size:16px; font-weight:600; color:var(--ink); margin:0 0 6px; }}
  .desc {{ font-size:13px; color:var(--muted); margin:0 0 16px; }}
  img {{ width:100%; height:auto; border-radius:6px; }}
  h3 {{ font-size:14px; font-weight:600; color:var(--ink); margin:26px 0 10px; }}
  table {{ width:100%; border-collapse:collapse; font-size:12.5px; }}
  th {{ text-align:left; font-weight:500; color:var(--muted); border-bottom:1px solid var(--line); padding:8px 6px; }}
  td {{ padding:7px 6px; border-bottom:1px solid #F2F0EA; }}
  td.num {{ text-align:right; font-variant-numeric:tabular-nums; }}
  footer {{ color:var(--muted); font-size:12px; margin-top:32px; border-top:1px solid var(--line); padding-top:18px; }}
  @media (max-width:760px) {{ .grid {{ grid-template-columns:repeat(2,1fr); }} }}
</style></head>
<body><div class="wrap">
<header>
  <h1>Olist 电商经营分析看板</h1>
  <div class="sub">NEW_STAR 数据仓库 · 数据区间 {str(kpi['first_order_ts'])[:10]} ~ {str(kpi['last_order_ts'])[:10]} · 引擎 DuckDB</div>
</header>
<div class="grid">{card_html}</div>
{sections}
<section>
  <h2>附：明细指标</h2>
  <h3>近 6 个月经营</h3>
  {_table(monthly, [("year_month","月份",0),("orders","订单量",0),("gmv","GMV",0),("aov","客单价",2),("late_rate","延误率",4),("avg_review","评分",2)])}
  <h3>客户分群</h3>
  {_table(rfm, [("segment","分群",0),("customers","人数",0),("customer_share","人数占比",4),("gmv_share","GMV 占比",4),("avg_monetary","人均消费",2)])}
  <h3>Top 品类</h3>
  {_table(cats, [("category","品类",0),("gmv","GMV",0),("gmv_share","占比",4),("avg_review","评分",2)])}
  <h3>延误率最高的州</h3>
  {_table(states, [("state","州",0),("delivered_orders","已送达订单",0),("avg_delivery_days","平均天数",1),("late_rate","延误率",4),("avg_review","评分",2)])}
</section>
<footer>数据来源：GitHub 开源 Olist Brazilian E-Commerce 数据集 · 生成时间 {__import__('datetime').datetime.now():%Y-%m-%d %H:%M} · 图表字体 {font}</footer>
</div></body></html>"""

    out = reports / "dashboard.html"
    out.write_text(html, encoding="utf-8")

    summary = {
        "kpi": {k: (float(v) if hasattr(v, "isoformat") is False and not isinstance(v, (str, bool)) else str(v))
                for k, v in kpi.to_dict().items()},
        "charts": [str(p) for _, _, p in charts],
        "rfm": rfm.to_dict(orient="records"),
        "top_categories": cats.to_dict(orient="records"),
        "worst_states": states.to_dict(orient="records"),
        "monthly": monthly.to_dict(orient="records"),
    }
    (reports / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2, default=str), encoding="utf-8")
    logger.info("看板已生成: %s", out)
    return summary
