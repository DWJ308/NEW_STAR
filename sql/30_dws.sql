-- =============================================================================
-- 30_dws.sql  |  汇总层（DWS）
-- 目标：沉淀 4 张主题宽表，供应用层复用，避免 ADS 反复回刷明细。
-- 技术点：多粒度聚合后回连、STRING_AGG 去重、窗口计数、快照日口径统一
-- =============================================================================

-- 全局快照日：所有 recency / 活跃度指标以数据内最大下单时间为基准，
-- 而不是 CURRENT_DATE，否则用历史数据跑出来的 recency 会全部失真。
CREATE OR REPLACE TABLE meta.snapshot AS
SELECT MAX(purchase_ts) AS snapshot_ts, CAST(MAX(purchase_ts) AS DATE) AS snapshot_date
FROM dwd.fct_orders;

-- ---------------------------------------------------------------------------
-- 主题 1：订单宽表（粒度 = 1 订单）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dws.order_wide AS
WITH item_agg AS (
    SELECT
        order_id,
        COUNT(*)                        AS item_cnt,
        COUNT(DISTINCT product_key)     AS sku_cnt,
        COUNT(DISTINCT seller_key)      AS seller_cnt,
        SUM(price)                      AS gmv,
        SUM(freight_value)              AS freight,
        MAX(product_key)                AS sample_product_key,
        MAX(seller_key)                 AS sample_seller_key
    FROM dwd.fct_order_items
    GROUP BY order_id
),
pay_agg AS (
    SELECT
        order_id,
        SUM(payment_value)      AS paid_amount,
        MAX(installments)       AS max_installments,
        COUNT(*)                AS payment_cnt
    FROM dwd.fct_payments
    GROUP BY order_id
),
pay_type AS (
    SELECT order_id, STRING_AGG(payment_type, '+' ORDER BY payment_type) AS payment_types
    FROM (SELECT DISTINCT order_id, payment_type FROM dwd.fct_payments WHERE payment_type IS NOT NULL)
    GROUP BY order_id
),
rev AS (
    SELECT order_id, MAX(review_score) AS review_score, MAX(is_negative) AS has_negative_review
    FROM dwd.fct_reviews
    GROUP BY order_id
)
SELECT
    o.order_id,
    o.customer_key,
    o.purchase_date_key,
    o.order_status,
    o.purchase_ts,
    o.delivered_ts,
    o.delivery_days,
    o.promised_days,
    o.is_late,
    o.is_delivered,
    o.is_canceled,
    COALESCE(i.item_cnt, 0)          AS item_cnt,
    COALESCE(i.sku_cnt, 0)           AS sku_cnt,
    COALESCE(i.seller_cnt, 0)        AS seller_cnt,
    COALESCE(i.gmv, 0)               AS gmv,
    COALESCE(i.freight, 0)           AS freight,
    COALESCE(i.gmv, 0) + COALESCE(i.freight, 0) AS gmv_with_freight,
    p.paid_amount,
    p.max_installments,
    pt.payment_types,
    r.review_score,
    COALESCE(r.has_negative_review, FALSE) AS has_negative_review,
    -- 金额一致性：支付总额与商品+运费应近似相等，差异超 1 分钱标记异常
    ABS(COALESCE(p.paid_amount, 0) - (COALESCE(i.gmv, 0) + COALESCE(i.freight, 0))) AS amount_gap
FROM dwd.fct_orders o
LEFT JOIN item_agg i ON i.order_id = o.order_id
LEFT JOIN pay_agg  p ON p.order_id = o.order_id
LEFT JOIN pay_type pt ON pt.order_id = o.order_id
LEFT JOIN rev      r ON r.order_id = o.order_id;

-- ---------------------------------------------------------------------------
-- 主题 2：客户 RFM 基础表（粒度 = 1 自然人）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dws.customer_rfm AS
WITH base AS (
    SELECT
        customer_key,
        MIN(purchase_ts)              AS first_order_ts,
        MAX(purchase_ts)              AS last_order_ts,
        COUNT(DISTINCT order_id)      AS frequency,
        SUM(gmv)                      AS monetary,
        SUM(freight)                  AS freight_paid,
        AVG(review_score)             AS avg_review,
        AVG(delivery_days)            AS avg_delivery_days
    FROM dws.order_wide
    WHERE NOT is_canceled
    GROUP BY customer_key
)
SELECT
    b.customer_key,
    b.first_order_ts,
    b.last_order_ts,
    b.frequency,
    ROUND(b.monetary, 2)                                  AS monetary,
    ROUND(b.monetary / NULLIF(b.frequency, 0), 2)         AS avg_order_value,
    ROUND(b.avg_review, 2)                                AS avg_review,
    ROUND(b.avg_delivery_days, 1)                         AS avg_delivery_days,
    DATE_DIFF('day', CAST(b.last_order_ts AS DATE), s.snapshot_date) AS recency_days,
    DATE_DIFF('day', CAST(b.first_order_ts AS DATE), CAST(b.last_order_ts AS DATE)) AS lifespan_days
FROM base b
CROSS JOIN meta.snapshot s;

-- ---------------------------------------------------------------------------
-- 主题 3：品类 × 月度（粒度 = 1 品类 1 自然月）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dws.category_monthly AS
SELECT
    p.category_en                                        AS category,
    STRFTIME(CAST(o.purchase_ts AS DATE), '%Y-%m')        AS year_month,
    COUNT(DISTINCT o.order_id)                           AS orders,
    COUNT(*)                                             AS items,
    ROUND(SUM(i.price), 2)                               AS gmv,
    ROUND(AVG(i.price), 2)                               AS avg_price,
    ROUND(AVG(CASE WHEN o.is_delivered THEN o.delivery_days END), 1) AS avg_delivery_days,
    ROUND(AVG(CASE WHEN o.is_delivered THEN CAST(o.is_late AS INTEGER) END), 4) AS late_rate,
    ROUND(AVG(o.review_score), 2)                        AS avg_review
FROM dwd.fct_order_items i
JOIN dws.order_wide o ON o.order_id = i.order_id
JOIN dwd.dim_product p ON p.product_key = i.product_key
WHERE o.purchase_ts IS NOT NULL
GROUP BY p.category_en, STRFTIME(CAST(o.purchase_ts AS DATE), '%Y-%m');

-- ---------------------------------------------------------------------------
-- 主题 4：卖家经营表现（粒度 = 1 卖家）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dws.seller_performance AS
SELECT
    i.seller_key,
    s.state                                              AS seller_state,
    COUNT(DISTINCT i.order_id)                           AS orders,
    COUNT(*)                                             AS items,
    ROUND(SUM(i.price), 2)                               AS gmv,
    ROUND(AVG(i.price), 2)                               AS avg_item_price,
    COUNT(DISTINCT STRFTIME(CAST(o.purchase_ts AS DATE), '%Y-%m')) AS active_months,
    ROUND(AVG(CASE WHEN o.is_delivered THEN o.delivery_days END), 1) AS avg_delivery_days,
    ROUND(AVG(CASE WHEN o.is_delivered THEN CAST(o.is_late AS INTEGER) END), 4) AS late_rate,
    ROUND(AVG(o.review_score), 2)                        AS avg_review,
    ROUND(AVG(CASE WHEN o.is_delivered = FALSE AND o.is_canceled = FALSE THEN 1.0 ELSE 0.0 END), 4) AS stuck_rate
FROM dwd.fct_order_items i
JOIN dws.order_wide o ON o.order_id = i.order_id
LEFT JOIN dwd.dim_seller s ON s.seller_key = i.seller_key
GROUP BY i.seller_key, s.state;

-- ---------------------------------------------------------------------------
-- 主题 5：客户同期群留存（粒度 = 1 首购月 1 留存月）
-- 技术点：自连接 + DATE_DIFF 计算月偏移，是留存分析的标准解法
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dws.cohort_retention AS
WITH first_purchase AS (
    SELECT customer_key, DATE_TRUNC('month', MIN(purchase_ts)) AS cohort_month
    FROM dws.order_wide
    WHERE NOT is_canceled
    GROUP BY customer_key
),
activity AS (
    SELECT DISTINCT o.customer_key, DATE_TRUNC('month', o.purchase_ts) AS activity_month
    FROM dws.order_wide o
    WHERE NOT is_canceled
)
SELECT
    CAST(f.cohort_month AS DATE)                                AS cohort_month,
    DATE_DIFF('month', f.cohort_month, a.activity_month)         AS month_offset,
    COUNT(DISTINCT a.customer_key)                              AS active_customers
FROM first_purchase f
JOIN activity a USING (customer_key)
GROUP BY f.cohort_month, month_offset;
