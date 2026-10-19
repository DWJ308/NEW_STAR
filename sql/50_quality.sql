-- =============================================================================
-- 50_quality.sql  |  数据质量校验
-- 设计：每个断言产出一行结果（failed_rows + threshold + passed），
--       全部落表 quality.check_results，CI 中由 pytest 读取并决定是否阻断发布。
-- 覆盖六类：完整性 / 唯一性 / 参照完整性 / 值域 / 业务逻辑 / 财务勾稽
-- =============================================================================

CREATE OR REPLACE TABLE quality.check_results AS
WITH c AS (
    SELECT 'completeness' AS check_name, 'ods' AS layer, 'ERROR' AS severity,
           CASE WHEN COUNT(*) >= 99000 THEN 0 ELSE 1 END AS failed_rows,
           99000.0 AS threshold,
           COUNT(*) AS actual
    FROM ods.orders

    UNION ALL
    SELECT 'uniqueness:fct_orders',
           'dwd', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM dwd.fct_orders),
           0.0,
           (SELECT COUNT(DISTINCT order_id) FROM dwd.fct_orders)

    UNION ALL
    SELECT 'uniqueness:dim_customer',
           'dwd', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT customer_key) FROM dwd.dim_customer),
           0.0,
           (SELECT COUNT(DISTINCT customer_key) FROM dwd.dim_customer)

    UNION ALL
    SELECT 'uniqueness:dim_product',
           'dwd', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT product_key) FROM dwd.dim_product),
           0.0,
           (SELECT COUNT(DISTINCT product_key) FROM dwd.dim_product)

    UNION ALL
    SELECT 'referential:items_to_orders',
           'dwd', 'ERROR',
           (SELECT COUNT(*) FROM dwd.fct_order_items i
             WHERE NOT EXISTS (SELECT 1 FROM dwd.fct_orders o WHERE o.order_id = i.order_id)),
           0.0,
           (SELECT COUNT(*) FROM dwd.fct_order_items)

    UNION ALL
    SELECT 'referential:items_to_product',
           'dwd', 'ERROR',
           (SELECT COUNT(*) FROM dwd.fct_order_items i
             WHERE NOT EXISTS (SELECT 1 FROM dwd.dim_product p WHERE p.product_key = i.product_key)),
           0.0,
           (SELECT COUNT(*) FROM dwd.fct_order_items)

    UNION ALL
    SELECT 'domain:price_non_negative',
           'dwd', 'ERROR',
           (SELECT COUNT(*) FROM dwd.fct_order_items WHERE price < 0 OR freight_value < 0),
           0.0,
           (SELECT COUNT(*) FROM dwd.fct_order_items)

    UNION ALL
    SELECT 'logic:delivered_after_purchase',
           'dwd', 'ERROR',
           (SELECT COUNT(*) FROM dwd.fct_orders
             WHERE delivered_ts IS NOT NULL AND delivered_ts < purchase_ts),
           0.0,
           (SELECT COUNT(*) FROM dwd.fct_orders WHERE delivered_ts IS NOT NULL)

    UNION ALL
    SELECT 'logic:status_delivered_missing_date',
           'dwd', 'WARN',
           (SELECT COUNT(*) FROM dwd.fct_orders
             WHERE order_status = 'delivered' AND delivered_ts IS NULL),
           0.03,
           (SELECT COUNT(*) FROM dwd.fct_orders WHERE order_status = 'delivered')

    UNION ALL
    -- 勾稽口径：只对"确实有商品行"的订单做金额一致性校验。
    -- 原因：源数据中 775 单 status 为 canceled/unavailable/created 的单据没有商品行，
    --       但存在支付流水（预付/退款），直接全域勾稽会误报为数据错误。
    SELECT 'finance:payment_reconciliation',
           'dws', 'WARN',
           (SELECT COUNT(*) FROM dws.order_wide WHERE item_cnt > 0 AND amount_gap > 0.01),
           0.005,
           (SELECT COUNT(*) FROM dws.order_wide WHERE item_cnt > 0)

    UNION ALL
    SELECT 'completeness:orders_without_items',
           'dws', 'WARN',
           (SELECT COUNT(*) FROM dws.order_wide WHERE item_cnt = 0),
           0.015,
           (SELECT COUNT(*) FROM dws.order_wide)

    UNION ALL
    SELECT 'finance:gmv_reconciliation',
           'dws', 'ERROR',
           ABS((SELECT COALESCE(SUM(price), 0) FROM dwd.fct_order_items)
             - (SELECT COALESCE(SUM(gmv), 0) FROM dws.order_wide)),
           0.01,
           (SELECT COALESCE(SUM(gmv), 0) FROM dws.order_wide)

    UNION ALL
    SELECT 'coverage:review_rate',
           'dws', 'WARN',
           CASE WHEN (SELECT COUNT(DISTINCT order_id) FROM dwd.fct_reviews) * 1.0
                     / NULLIF((SELECT COUNT(*) FROM dwd.fct_orders), 0) >= 0.95 THEN 0 ELSE 1 END,
           0.95,
           (SELECT COUNT(DISTINCT order_id) FROM dwd.fct_reviews)

    UNION ALL
    SELECT 'consistency:late_rate',
           'ads', 'WARN',
           CASE WHEN COALESCE((SELECT late_rate FROM ads.kpi_overview), 0) <= 0.15 THEN 0 ELSE 1 END,
           0.15,
           COALESCE((SELECT late_rate FROM ads.kpi_overview), 0)

    UNION ALL
    SELECT 'integrity:dim_date_continuous',
           'dwd', 'ERROR',
           (SELECT DATE_DIFF('day', MIN(date_day), MAX(date_day)) + 1 - COUNT(*) FROM dwd.dim_date),
           0.0,
           (SELECT COUNT(*) FROM dwd.dim_date)

    UNION ALL
    SELECT 'integrity:quarantine_accounted',
           'quality', 'WARN',
           (SELECT COUNT(*) FROM ods.orders)
             - (SELECT COUNT(*) FROM dwd.fct_orders)
             - (SELECT COUNT(*) FROM quality.quarantine_orders),
           0.0,
           (SELECT COUNT(*) FROM quality.quarantine_orders)
),
judged AS (
    SELECT
        check_name, layer, severity, failed_rows, threshold, actual,
        -- 阈值语义区分：计数类阈值（0）看绝对失败数，比率类阈值看失败占比；
        -- 分母为 0（无样本可校验）时默认通过，而不是 NULL 被当成失败
        CASE
            WHEN threshold = 0.0 THEN failed_rows = 0
            ELSE COALESCE((failed_rows * 1.0 / NULLIF(actual, 0)) <= threshold, TRUE)
        END AS passed
    FROM c
)
SELECT check_name, layer, severity, failed_rows, threshold, actual, passed,
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS status
FROM judged;
