# 数据字典 · NEW_STAR

## 贴源层 ods（全 VARCHAR + 审计列 `_ingested_at`, `_src_file`）

| 表 | 粒度 | 关键列 | 行数（真实数据） |
|---|---|---|---|
| ods.orders | 1 订单 | order_id, customer_id, order_status, 各时间戳 | 99,441 |
| ods.order_items | 1 订单 1 行商品 | order_id, order_item_id, product_id, seller_id, price, freight_value | 112,650 |
| ods.order_payments | 1 笔支付流水 | order_id, payment_sequential, payment_type, installments, payment_value | 103,886 |
| ods.order_reviews | 1 条评价 | review_id, order_id, review_score | 104,719 |
| ods.customers | 1 个 customer_id（≠自然人） | customer_id, customer_unique_id, city, state | 99,441 |
| ods.products | 1 商品 | product_id, product_category_name, 尺寸重量 | 32,951 |
| ods.sellers | 1 卖家 | seller_id, city, state | 3,095 |
| ods.category_translation | 1 品类 | 葡文名 → 英文名 | 71 |

## 明细层 dwd（强类型星型模型）

| 表 | 粒度 | 说明 |
|---|---|---|
| dwd.dim_date | 1 天 | 递归 CTE 生成，覆盖订单日期全范围；date_key = YYYYMMDD |
| dwd.dim_customer | 1 自然人（customer_unique_id） | 按 ROW_NUMBER 去重；observed_orders 保留观测单数 |
| dwd.dim_product | 1 商品 | 关联英译品类，缺失归 'unknown' |
| dwd.dim_seller | 1 卖家 | — |
| dwd.fct_orders | 1 有效订单 | 派生 delivery_days / promised_days / is_late / is_delivered / is_canceled |
| dwd.fct_order_items | 1 订单 1 行商品 | gross_amount = price + freight_value |
| dwd.fct_payments | 1 笔支付流水 | — |
| dwd.fct_reviews | 1 review_id | 同 review_id 保留 answer 最新一条 |

**隔离区** `quality.quarantine_orders`：order_id 为空或下单时间非法的订单，带 reject_reason，不进事实表。

## 汇总层 dws

| 表 | 粒度 | 内容 |
|---|---|---|
| dws.order_wide | 1 订单 | 明细聚合回连：gmv（=Σprice）、freight、支付、评分、amount_gap |
| dws.customer_rfm | 1 自然人 | recency（相对快照日）、frequency、monetary、avg_review |
| dws.category_monthly | 品类 × 月 | gmv、均价、延误率、评分 |
| dws.seller_performance | 1 卖家 | 订单、gmv、活跃月数、延误率、评分 |
| dws.cohort_retention | 首购月 × 偏移月 | 活跃客户数 |

## 应用层 ads

| 表 | 用途 |
|---|---|
| ads.kpi_overview | 总览卡片（GMV/AOV/复购率/延误率等） |
| ads.kpi_monthly | 月度趋势 + LAG 环比 + 累计 GMV |
| ads.rfm_scored / ads.rfm_summary | RFM 打分（R=业务阈值，F=次数规则，M=NTILE 五分位）与分群汇总 |
| ads.cohort_matrix | 留存矩阵（M+0 ~ M+6 行转列） |
| ads.delivery_sla_by_state | 州级 SLA：均值/中位数/P90、延误率（≥100 单才纳入） |
| ads.category_performance | 品类排名 + GMV 占比 + 累计帕累托 |
| ads.seller_scorecard | 卖家四分层（核心/规模待优化/潜力/尾部） |
| ads.payment_mix / ads.order_status_distribution | 支付与订单状态结构 |

## 关键口径

- **GMV** = Σ price（商品金额，不含运费）；`gmv_with_freight` 含运费
- **快照日** = 数据内最大下单时间（2018-10-17），所有 recency 以此为基准
- **延误** = delivered_ts > estimated_ts，仅对已送达订单计算
- **复购** = customer_unique_id 在数据区间内下单次数 > 1
- **剔除截断月**：2018-09 起数据临近采集截止，趋势图与"近 6 个月"表不含这两个月
