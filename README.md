# NEW_STAR · Olist 电商数据仓库与分析平台

基于 **GitHub 开源的 Olist 巴西电商真实交易数据**（99,441 笔订单 / 96,096 名客户 / 1,794 名卖家 / R$ 1,359 万 GMV），
从零搭建的一套**可复现、可测试、可审计**的数据仓库 + 经营分析项目。

不是语法演示，而是一个真实生产思路的缩影：分层数仓建模 → 数据质量门禁 → 指标口径管理 → 面向业务的分析看板。

## 核心结果（全部由本项目管道从真实数据算出）

| 指标 | 数值 | 指标 | 数值 |
|---|---|---|---|
| 累计 GMV | R$ 13,591,643.70 | 客单价 AOV | R$ 136.68 |
| 订单量 | 99,441（已送达 96,478，97.0%） | 客户数 | 96,096 |
| 复购率 | 3.06%（2,924 人） | ARPU | R$ 142.23 |
| 平均配送 | 12.5 天 | 延误率 | 8.11% |
| 平均评分 | 4.09 / 5 | 数据区间 | 2016-09 ~ 2018-10 |

业务结论（详见 `reports/dashboard.html`）：

- **收入高度集中在"近 180 天内首购"人群**：RFM「重要挽留客户」以 35.8% 的人数贡献 68.9% 的 GMV，复购率仅 3.06%，M+1 留存不足 0.5% —— 典型的一次性流量型电商，增长依赖拉新而非留存；
- **品类长尾明显**：72 个品类中前 17 个贡献 80% GMV，health_beauty、watches_gifts、bed_bath_table 居前；
- **配送体验的南北差异**：东北部州（AL 23.9%、MA 19.5%）延误率是全国均值（8.1%）的 2-3 倍，南部州 PR 仅 4.99%；
- **支付结构**：信用卡 74.7%、boleto（巴西线下票据）19.9%，"信用卡+优惠券"组合支付占 2.3%。

## 架构

```
GitHub 开源数据 (CSV)
        │  scripts/fetch_data.py（校验 + 备用通道）
        ▼
┌─────────────────────────────────────────────────────┐
│  DuckDB 数仓（列存 OLAP）                             │
│                                                     │
│  ods  贴源层  全 VARCHAR + 审计列，不做业务清洗          │
│   │  20_dwd.sql：类型收敛 / 去重 / 星型建模 / 隔离区     │
│  dwd  明细层  dim_date · dim_customer · dim_product   │
│   │          dim_seller · fct_orders · fct_order_items│
│   │          fct_payments · fct_reviews               │
│   │  30_dws.sql：主题宽表 / RFM / 同期群               │
│  dws  汇总层  order_wide · customer_rfm               │
│   │          category_monthly · seller_performance    │
│   │          cohort_retention                         │
│   │  40_ads.sql：LAG / 累计 / 行转列 / NTILE           │
│  ads  应用层  kpi_monthly · rfm_scored · cohort_matrix│
│              delivery_sla_by_state · seller_scorecard │
│   │                                                   │
│  quality  16 项自动化质量断言 + 隔离区                  │
│  meta     运行审计 + 增量水位线                         │
└─────────────────────────────────────────────────────┘
        │
        ▼
reports/dashboard.html（自包含看板） · CSV 指标导出 · summary.json
```

## SQL 能力清单（对应 `sql/` 目录）

| 能力 | 落点 |
|---|---|
| 递归 CTE 生成日期维度 | `20_dwd.sql` dim_date |
| ROW_NUMBER() 窗口去重（自然人去重、评价去重） | `20_dwd.sql` dim_customer / fct_reviews |
| TRY_CAST 容错转换 + 脏数据隔离区 | `20_dwd.sql` quarantine_orders |
| 多粒度聚合回连（订单宽表） | `30_dws.sql` order_wide |
| 同期群留存（自连接 + 月偏移） | `30_dws.sql` cohort_retention |
| LAG 环比 / SUM() OVER 累计（帕累托） | `40_ads.sql` kpi_monthly / category_performance |
| CASE WHEN 条件聚合实现行转列 | `40_ads.sql` cohort_matrix |
| NTILE / PERCENT_RANK / RANK 分层 | `40_ads.sql` rfm_scored / seller_scorecard |
| quantile_cont 分位数（配送 P90） | `40_ads.sql` delivery_sla_by_state |
| 财务勾稽（支付 vs 商品+运费对账） | `50_quality.sql` |
| FILTER / NULLIF / COALESCE 口径保护 | 全部文件 |

## 工程化能力清单（对应 `src/star_pipeline/`）

- **配置驱动**：路径、数据源、阈值全部收敛到 `config/pipeline.yaml`，代码零硬编码
- **可复现**：`make all` 一键从原始 CSV 到看板；快照日口径写入 `meta.snapshot`
- **可观测**：每次运行写入 `meta.pipeline_runs`（耗时/行数/状态），失败留痕到具体层
- **质量门禁**：16 项 SQL 断言落表 `quality.check_results`，ERROR 级失败阻断发布（`--ignore-quality-gate` 可显式绕过）
- **测试**：`pytest` 11 个用例，用合成小数据验证转换契约（去重、勾稽、隔离区、RFM 快照口径），不依赖真实数据
- **工程韧性**：取数脚本带 raw 直连 + codeload 快照双通道，网络受限环境可回退

## 快速开始

```bash
# 1. 环境
make setup            # 或: python -m venv .venv && .venv/Scripts/pip install -r requirements.txt

# 2. 数据（约 62MB，来自 GitHub 开源数据集）
make fetch            # 或: PYTHONPATH=src python scripts/fetch_data.py

# 3. 一键运行：ETL -> 建模 -> 指标 -> 质量校验 -> 导出
make all

# 4. 查看结果
open reports/dashboard.html

# 测试
make test
```

## 数据来源与许可

- 数据：[Olist Brazilian E-Commerce Dataset](https://github.com/Ajandaghian/olist-ecommerce-etl-pipeline)（Kaggle "Brazilian E-Commerce Public Dataset by Olist" 的 GitHub 镜像），100k 订单，2016-2018
- 许可：CC BY-NC-SA 4.0，仅用于学习与研究
- 口径说明：GMV = 商品金额（不含运费）；快照日 = 数据内最大下单时间；2018-09 起数据临近采集截止，趋势图中已剔除截断月份

## 目录结构

```
NEW_STAR/
├── config/pipeline.yaml      # 全部配置：路径 / 数据源 / 质量阈值
├── sql/                      # 分层 SQL（00_ddl → 50_quality）
├── src/star_pipeline/        # Python 管道：配置 / 编排 / 报表 / CLI
├── tests/                    # 转换契约测试（合成数据，秒级运行）
├── scripts/fetch_data.py     # 数据获取（双通道 + sha256 指纹）
├── docs/                     # 数据字典
├── reports/                  # dashboard.html + 指标 CSV + summary.json
└── Makefile
```
