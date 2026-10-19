-- =============================================================================
-- 40_ads.sql  |  应用层（ADS）
-- 目标：直接支撑看板的指标表，一张表对应一个图表/卡片。
-- 技术点：
--   1. LAG / SUM() OVER 计算环比与累计（帕累托、累计 GMV）
--   2. CASE WHEN 条件聚合实现"行转列"的留存矩阵
--   3. NTILE / PERCENT_RANK 做分层与分位
--   4. 除零保护与口径注释，保证指标可复现
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. 总览卡片
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ads.kpi_overview AS
WITH base AS (
    SELECT
        COUNT(DISTINCT order_id)                                        AS orders_total,
        COUNT(DISTINCT CASE WHEN is_delivered THEN order_id END)         AS orders_delivered,
        COUNT(DISTINCT CASE WHEN is_canceled THEN order_id END)          AS orders_canceled,
        COUNT(DISTINCT customer_key)                                    AS customers_total,
        ROUND(SUM(gmv), 2)                                              AS gmv_total,
        ROUND(SUM(gmv) / NULLIF(COUNT(DISTINCT order_id), 0), 2)         AS aov,
        ROUND(AVG(CASE WHEN is_delivered THEN delivery_days END), 1)     AS avg_delivery_days,
        ROUND(AVG(CASE WHEN is_delivered THEN CAST(is_late AS INTEGER) END), 4) AS late_rate,
        ROUND(AVG(review_score), 2)                                     AS avg_review,
        MIN(purchase_ts)                                                AS first_order_ts,
        MAX(purchase_ts)                                                AS last_order_ts
    FROM dws.order_wide
),
repeat_calc AS (
    SELECT
        COUNT(*)                                                       AS customers,
        COUNT(*) FILTER (WHERE frequency > 1)                          AS repeat_customers
    FROM dws.customer_rfm
)
SELECT
    b.*,
    s.repeat_customers,
    ROUND(s.repeat_customers * 1.0 / NULLIF(s.customers, 0), 4)        AS repeat_rate,
    ROUND(b.gmv_total / NULLIF(s.customers, 0), 2)                     AS arpu
FROM base b CROSS JOIN repeat_calc s;

-- ---------------------------------------------------------------------------
-- 2. 月度经营指标（含环比与累计）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ads.kpi_monthly AS
WITH monthly AS (
    SELECT
        STRFTIME(purchase_ts, '%Y-%m')                                  AS year_month,
        COUNT(DISTINCT order_id)                                        AS orders,
        COUNT(DISTINCT customer_key)                                    AS customers,
        ROUND(SUM(gmv), 2)                                              AS gmv,
        ROUND(SUM(gmv) / NULLIF(COUNT(DISTINCT order_id), 0), 2)         AS aov,
        ROUND(AVG(CASE WHEN is_delivered THEN delivery_days END), 1)     AS avg_delivery_days,
        ROUND(AVG(CASE WHEN is_delivered THEN CAST(is_late AS INTEGER) END), 4) AS late_rate,
        ROUND(AVG(review_score), 2)                                     AS avg_review,
        ROUND(AVG(CASE WHEN is_canceled THEN 1.0 ELSE 0.0 END), 4)       AS cancel_rate
    FROM dws.order_wide
    GROUP BY year_month
)
SELECT
    year_month, orders, customers, gmv, aov, avg_delivery_days, late_rate, avg_review, cancel_rate,
    LAG(gmv) OVER (ORDER BY year_month)                                 AS prev_gmv,
    ROUND((gmv - LAG(gmv) OVER (ORDER BY year_month))
          / NULLIF(LAG(gmv) OVER (ORDER BY year_month), 0), 4)          AS gmv_mom,
    ROUND(SUM(gmv) OVER (ORDER BY year_month ROWS UNBOUNDED PRECEDING), 2) AS gmv_cumulative
FROM monthly
ORDER BY year_month;

-- ---------------------------------------------------------------------------
-- 3. 客户 RFM 分群
-- 打分口径（业务阈值 + 分位结合，避免 Olist 一客一单导致 NTILE 大面积并列）：
--   R：距快照日天数，越近分越高
--   F：购买次数，1 次为最低档
--   M：金额按五等分位（PERCENT_RANK）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ads.rfm_scored AS
WITH scored AS (
    SELECT
        *,
        CASE WHEN recency_days <= 30  THEN 5
             WHEN recency_days <= 90  THEN 4
             WHEN recency_days <= 180 THEN 3
             WHEN recency_days <= 365 THEN 2
             ELSE 1 END                                                 AS r_score,
        CASE WHEN frequency >= 5 THEN 5
             WHEN frequency = 4  THEN 4
             WHEN frequency = 3  THEN 3
             WHEN frequency = 2  THEN 2
             ELSE 1 END                                                 AS f_score,
        NTILE(5) OVER (ORDER BY monetary)                               AS m_score,
        PERCENT_RANK() OVER (ORDER BY monetary)                         AS m_percentile
    FROM dws.customer_rfm
)
SELECT
    customer_key, recency_days, frequency, monetary, avg_order_value,
    avg_review, avg_delivery_days,
    r_score, f_score, m_score,
    r_score * 100 + f_score * 10 + m_score                              AS rfm_code,
    ROUND(m_percentile, 4)                                              AS m_percentile,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 THEN '重要价值客户'
        WHEN r_score >= 4 AND f_score <  4 THEN '重要发展客户'
        WHEN r_score <  4 AND f_score >= 4 THEN '重要保持客户'
        WHEN r_score <  4 AND m_score >= 4 THEN '重要挽留客户'
        WHEN r_score <= 2 AND f_score <= 2 THEN '流失客户'
        ELSE '一般客户'
    END                                                                 AS segment
FROM scored;

CREATE OR REPLACE TABLE ads.rfm_summary AS
SELECT
    segment,
    COUNT(*)                                                            AS customers,
    ROUND(COUNT(*) * 1.0 / SUM(COUNT(*)) OVER (), 4)                     AS customer_share,
    ROUND(SUM(monetary), 2)                                             AS total_gmv,
    ROUND(SUM(monetary) / SUM(SUM(monetary)) OVER (), 4)                 AS gmv_share,
    ROUND(AVG(monetary), 2)                                             AS avg_monetary,
    ROUND(AVG(recency_days), 1)                                         AS avg_recency_days,
    ROUND(AVG(frequency), 2)                                            AS avg_frequency
FROM ads.rfm_scored
GROUP BY segment
ORDER BY total_gmv DESC;

-- ---------------------------------------------------------------------------
-- 4. 同期群留存矩阵（行转列）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ads.cohort_matrix AS
WITH base AS (
    SELECT
        cohort_month,
        month_offset,
        active_customers,
        MAX(CASE WHEN month_offset = 0 THEN active_customers END) OVER (PARTITION BY cohort_month) AS cohort_size
    FROM dws.cohort_retention
)
SELECT
    cohort_month,
    MAX(cohort_size)                                                    AS cohort_size,
    MAX(CASE WHEN month_offset = 0 THEN ROUND(active_customers * 1.0 / NULLIF(cohort_size, 0), 4) END) AS m0,
    MAX(CASE WHEN month_offset = 1 THEN ROUND(active_customers * 1.0 / NULLIF(cohort_size, 0), 4) END) AS m1,
    MAX(CASE WHEN month_offset = 2 THEN ROUND(active_customers * 1.0 / NULLIF(cohort_size, 0), 4) END) AS m2,
    MAX(CASE WHEN month_offset = 3 THEN ROUND(active_customers * 1.0 / NULLIF(cohort_size, 0), 4) END) AS m3,
    MAX(CASE WHEN month_offset = 4 THEN ROUND(active_customers * 1.0 / NULLIF(cohort_size, 0), 4) END) AS m4,
    MAX(CASE WHEN month_offset = 5 THEN ROUND(active_customers * 1.0 / NULLIF(cohort_size, 0), 4) END) AS m5,
    MAX(CASE WHEN month_offset = 6 THEN ROUND(active_customers * 1.0 / NULLIF(cohort_size, 0), 4) END) AS m6
FROM base
GROUP BY cohort_month
ORDER BY cohort_month;

-- ---------------------------------------------------------------------------
-- 5. 配送 SLA（按州）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ads.delivery_sla_by_state AS
WITH j AS (
    SELECT c.state, o.*
    FROM dws.order_wide o
    JOIN dwd.dim_customer c ON c.customer_key = o.customer_key
    WHERE o.is_delivered AND c.state IS NOT NULL
)
SELECT
    state,
    COUNT(DISTINCT order_id)                                            AS delivered_orders,
    ROUND(AVG(delivery_days), 1)                                        AS avg_delivery_days,
    ROUND(quantile_cont(delivery_days, 0.5), 0)                         AS median_delivery_days,
    ROUND(quantile_cont(delivery_days, 0.9), 0)                         AS p90_delivery_days,
    ROUND(AVG(CAST(is_late AS INTEGER)), 4)                             AS late_rate,
    ROUND(AVG(review_score), 2)                                         AS avg_review,
    ROUND(AVG(gmv), 2)                                                  AS aov
FROM j
GROUP BY state
HAVING COUNT(DISTINCT order_id) >= 100
ORDER BY late_rate DESC;

-- ---------------------------------------------------------------------------
-- 6. 品类经营 + 帕累托
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ads.category_performance AS
WITH cat AS (
    SELECT
        category,
        -- 月度已聚合，这里按品类汇总；同一订单跨月会被计多次，故命名为 order_months
        SUM(orders)                                                     AS order_months,
        SUM(items)                                                      AS items,
        ROUND(SUM(gmv), 2)                                              AS gmv,
        ROUND(AVG(avg_price), 2)                                        AS avg_price,
        ROUND(AVG(late_rate), 4)                                        AS late_rate,
        ROUND(AVG(avg_review), 2)                                       AS avg_review
    FROM dws.category_monthly
    GROUP BY category
)
SELECT
    category, order_months, items, gmv, avg_price, late_rate, avg_review,
    ROUND(gmv / SUM(gmv) OVER (), 4)                                    AS gmv_share,
    ROUND(SUM(gmv) OVER (ORDER BY gmv DESC ROWS UNBOUNDED PRECEDING)
          / SUM(gmv) OVER (), 4)                                        AS gmv_cumulative_share,
    RANK() OVER (ORDER BY gmv DESC)                                     AS gmv_rank
FROM cat
ORDER BY gmv DESC;

-- ---------------------------------------------------------------------------
-- 7. 卖家分层（四象限 + 分位）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ads.seller_scorecard AS
WITH s AS (
    SELECT * FROM dws.seller_performance WHERE orders >= 5
)
SELECT
    seller_key, seller_state, orders, gmv, avg_item_price, active_months,
    avg_delivery_days, late_rate, avg_review, stuck_rate,
    NTILE(4) OVER (ORDER BY gmv DESC)                                   AS gmv_quartile,
    ROUND(PERCENT_RANK() OVER (ORDER BY gmv), 4)                        AS gmv_percentile,
    ROUND(PERCENT_RANK() OVER (ORDER BY COALESCE(late_rate, 0) DESC), 4) AS late_percentile,
    CASE
        WHEN gmv >= (SELECT quantile_cont(gmv, 0.5) FROM s)
         AND COALESCE(late_rate, 1) <= (SELECT quantile_cont(late_rate, 0.5) FROM s) THEN '核心卖家'
        WHEN gmv >= (SELECT quantile_cont(gmv, 0.5) FROM s) THEN '规模待优化'
        WHEN COALESCE(late_rate, 1) <= (SELECT quantile_cont(late_rate, 0.5) FROM s) THEN '潜力卖家'
        ELSE '尾部卖家'
    END                                                                 AS seller_tier
FROM s;

-- ---------------------------------------------------------------------------
-- 8. 支付方式与分期
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ads.payment_mix AS
SELECT
    payment_types,
    COUNT(*)                                                            AS orders,
    ROUND(COUNT(*) * 1.0 / SUM(COUNT(*)) OVER (), 4)                     AS order_share,
    ROUND(SUM(paid_amount), 2)                                          AS paid_amount,
    ROUND(SUM(paid_amount) / SUM(COUNT(*)) OVER (), 2)                   AS gmv_per_order_avg,
    ROUND(AVG(max_installments), 2)                                     AS avg_installments
FROM dws.order_wide
WHERE payment_types IS NOT NULL
GROUP BY payment_types
ORDER BY orders DESC;

-- ---------------------------------------------------------------------------
-- 9. 订单状态分布
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ads.order_status_distribution AS
SELECT
    order_status,
    COUNT(*)                                                            AS orders,
    ROUND(COUNT(*) * 1.0 / SUM(COUNT(*)) OVER (), 4)                     AS order_share,
    ROUND(SUM(gmv), 2)                                                  AS gmv
FROM dws.order_wide
GROUP BY order_status
ORDER BY orders DESC;
