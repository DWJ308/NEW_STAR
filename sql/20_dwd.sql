-- =============================================================================
-- 20_dwd.sql  |  明细层（DWD）
-- 目标：把 VARCHAR 贴源数据收敛为强类型星型模型，脏数据进隔离区而不是静默丢弃。
-- 技术点：
--   1. 递归 CTE 生成日期维度（无依赖外部日历表）
--   2. ROW_NUMBER() 窗口去重，处理 Olist 一客多单 / 重复评价
--   3. TRY_CAST 容错转换：非法值转 NULL 而非中断全批
--   4. HASH + ROW_NUMBER 生成确定性代理键
--   5. 隔离区（quality.quarantine_*）保留被拒绝记录，可回溯
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 隔离区：先落地，后续 DWD 只处理通过校验的记录
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE quality.quarantine_orders AS
WITH raw AS (
    SELECT *,
           NULLIF(TRIM(order_id), '')                            AS order_id_c,
           TRY_CAST(NULLIF(TRIM(order_purchase_timestamp), '') AS TIMESTAMP) AS purchase_ts
    FROM ods.orders
)
SELECT order_id, order_status, order_purchase_timestamp,
       CASE
           WHEN order_id_c IS NULL      THEN 'NULL_ORDER_ID'
           WHEN purchase_ts IS NULL     THEN 'INVALID_PURCHASE_TIMESTAMP'
           ELSE 'UNKNOWN'
       END AS reject_reason,
       CURRENT_TIMESTAMP AS quarantined_at
FROM raw
WHERE order_id_c IS NULL OR purchase_ts IS NULL;

-- ---------------------------------------------------------------------------
-- 维度：日期（递归 CTE 生成，覆盖订单事实的全部日期范围）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dwd.dim_date AS
WITH RECURSIVE bounds AS (
    SELECT MIN(CAST(NULLIF(TRIM(order_purchase_timestamp), '') AS DATE)) AS d0,
           MAX(CAST(NULLIF(TRIM(order_purchase_timestamp), '') AS DATE)) AS d1
    FROM ods.orders
),
spine AS (
    SELECT d0 AS d FROM bounds WHERE d0 IS NOT NULL
    UNION ALL
    SELECT CAST(d + INTERVAL 1 DAY AS DATE) FROM spine, bounds WHERE spine.d < bounds.d1
)
SELECT
    CAST(STRFTIME(d, '%Y%m%d') AS INTEGER) AS date_key,
    d                                       AS date_day,
    YEAR(d)                                 AS year,
    QUARTER(d)                              AS quarter,
    MONTH(d)                                AS month,
    STRFTIME(d, '%Y-%m')                    AS year_month,
    DAYOFWEEK(d)                            AS day_of_week,
    STRFTIME(d, '%a')                       AS week_day_name,
    CASE WHEN DAYOFWEEK(d) IN (0, 6) THEN TRUE ELSE FALSE END AS is_weekend
FROM spine;

-- ---------------------------------------------------------------------------
-- 维度：客户
-- 口径说明：Olist 的 customer_id 是"每单一个"，customer_unique_id 才是自然人。
-- 因此客户维度必须按 customer_unique_id 去重，否则复购率、RFM 全部失真。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dwd.dim_customer AS
WITH base AS (
    SELECT
        c.customer_id,
        NULLIF(TRIM(c.customer_unique_id), '')            AS customer_unique_id,
        NULLIF(TRIM(c.customer_city), '')                 AS city,
        NULLIF(TRIM(c.customer_state), '')                AS state,
        TRY_CAST(NULLIF(TRIM(c.customer_zip_code_prefix), '') AS INTEGER) AS zip_prefix,
        TRY_CAST(NULLIF(TRIM(o.order_purchase_timestamp), '') AS TIMESTAMP) AS purchase_ts
    FROM ods.customers c
    LEFT JOIN ods.orders o USING (customer_id)
    WHERE NULLIF(TRIM(c.customer_unique_id), '') IS NOT NULL
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id
                              ORDER BY purchase_ts NULLS LAST, customer_id) AS rn,
           COUNT(*) OVER (PARTITION BY customer_unique_id) AS observed_orders
    FROM base
)
SELECT
    ROW_NUMBER() OVER (ORDER BY customer_unique_id) AS customer_sk,
    customer_unique_id                              AS customer_key,
    customer_id                                     AS first_customer_id,
    city, state, zip_prefix,
    purchase_ts                                     AS first_order_ts,
    observed_orders
FROM ranked
WHERE rn = 1;

-- ---------------------------------------------------------------------------
-- 维度：商品（关联葡->英品类翻译，缺失品类归为 unknown）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dwd.dim_product AS
WITH ranked AS (
    SELECT
        p.*,
        ROW_NUMBER() OVER (PARTITION BY p.product_id ORDER BY p._ingested_at DESC) AS rn
    FROM ods.products p
    WHERE NULLIF(TRIM(p.product_id), '') IS NOT NULL
)
SELECT
    r.product_id                                                       AS product_key,
    COALESCE(NULLIF(TRIM(r.product_category_name), ''), 'unknown')     AS category_pt,
    COALESCE(NULLIF(TRIM(t.product_category_name_english), ''), 'unknown') AS category_en,
    TRY_CAST(NULLIF(TRIM(r.product_name_lenght), '') AS INTEGER)       AS name_length,
    TRY_CAST(NULLIF(TRIM(r.product_description_lenght), '') AS INTEGER) AS description_length,
    TRY_CAST(NULLIF(TRIM(r.product_photos_qty), '') AS INTEGER)        AS photos_qty,
    TRY_CAST(NULLIF(TRIM(r.product_weight_g), '') AS DOUBLE)           AS weight_g,
    TRY_CAST(NULLIF(TRIM(r.product_length_cm), '') AS DOUBLE)          AS length_cm,
    TRY_CAST(NULLIF(TRIM(r.product_height_cm), '') AS DOUBLE)          AS height_cm,
    TRY_CAST(NULLIF(TRIM(r.product_width_cm), '') AS DOUBLE)           AS width_cm
FROM ranked r
LEFT JOIN ods.category_translation t
       ON TRIM(t.product_category_name) = TRIM(r.product_category_name)
WHERE r.rn = 1;

-- ---------------------------------------------------------------------------
-- 维度：卖家
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dwd.dim_seller AS
WITH ranked AS (
    SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.seller_id ORDER BY s._ingested_at DESC) AS rn
    FROM ods.sellers s
    WHERE NULLIF(TRIM(s.seller_id), '') IS NOT NULL
)
SELECT
    seller_id                          AS seller_key,
    NULLIF(TRIM(seller_city), '')      AS city,
    NULLIF(TRIM(seller_state), '')     AS state,
    TRY_CAST(NULLIF(TRIM(seller_zip_code_prefix), '') AS INTEGER) AS zip_prefix
FROM ranked WHERE rn = 1;

-- ---------------------------------------------------------------------------
-- 事实：订单头（粒度 = 1 订单）
-- 派生：配送天数、是否延迟、是否完成、是否首单
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dwd.fct_orders AS
WITH typed AS (
    SELECT
        NULLIF(TRIM(o.order_id), '')                AS order_id,
        NULLIF(TRIM(o.customer_id), '')             AS customer_id,
        NULLIF(TRIM(o.order_status), '')            AS order_status,
        TRY_CAST(NULLIF(TRIM(o.order_purchase_timestamp), '')  AS TIMESTAMP) AS purchase_ts,
        TRY_CAST(NULLIF(TRIM(o.order_approved_at), '')         AS TIMESTAMP) AS approved_ts,
        TRY_CAST(NULLIF(TRIM(o.order_delivered_carrier_date), '')  AS TIMESTAMP) AS shipped_ts,
        TRY_CAST(NULLIF(TRIM(o.order_delivered_customer_date), '') AS TIMESTAMP) AS delivered_ts,
        TRY_CAST(NULLIF(TRIM(o.order_estimated_delivery_date), '') AS TIMESTAMP) AS estimated_ts
    FROM ods.orders o
)
SELECT
    t.order_id,
    c.customer_unique_id                        AS customer_key,
    d.date_key                                  AS purchase_date_key,
    t.order_status,
    t.purchase_ts,
    t.approved_ts,
    t.shipped_ts,
    t.delivered_ts,
    t.estimated_ts,
    DATE_DIFF('day', t.purchase_ts, t.delivered_ts)   AS delivery_days,
    DATE_DIFF('day', t.purchase_ts, t.estimated_ts)   AS promised_days,
    DATE_DIFF('day', t.delivered_ts, t.estimated_ts)  AS days_vs_promise,
    COALESCE(t.delivered_ts > t.estimated_ts, FALSE)  AS is_late,
    COALESCE(t.delivered_ts IS NOT NULL, FALSE)       AS is_delivered,
    COALESCE(t.order_status = 'canceled', FALSE)      AS is_canceled
FROM typed t
LEFT JOIN ods.customers c USING (customer_id)
LEFT JOIN dwd.dim_date d ON d.date_day = CAST(t.purchase_ts AS DATE)
WHERE t.order_id IS NOT NULL
  AND t.purchase_ts IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 事实：订单商品明细（粒度 = 1 订单 1 行商品）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dwd.fct_order_items AS
SELECT
    NULLIF(TRIM(i.order_id), '')        AS order_id,
    TRY_CAST(NULLIF(TRIM(i.order_item_id), '') AS INTEGER)  AS order_item_id,
    NULLIF(TRIM(i.product_id), '')      AS product_key,
    NULLIF(TRIM(i.seller_id), '')       AS seller_key,
    TRY_CAST(NULLIF(TRIM(i.price), '') AS DOUBLE)           AS price,
    TRY_CAST(NULLIF(TRIM(i.freight_value), '') AS DOUBLE)   AS freight_value,
    TRY_CAST(NULLIF(TRIM(i.shipping_limit_date), '') AS TIMESTAMP) AS shipping_limit_ts,
    TRY_CAST(NULLIF(TRIM(i.price), '') AS DOUBLE)
      + TRY_CAST(NULLIF(TRIM(i.freight_value), '') AS DOUBLE) AS gross_amount
FROM ods.order_items i
WHERE NULLIF(TRIM(i.order_id), '') IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 事实：支付（粒度 = 1 订单 1 支付流水）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dwd.fct_payments AS
SELECT
    NULLIF(TRIM(p.order_id), '')        AS order_id,
    TRY_CAST(NULLIF(TRIM(p.payment_sequential), '') AS INTEGER) AS payment_sequential,
    NULLIF(TRIM(p.payment_type), '')    AS payment_type,
    TRY_CAST(NULLIF(TRIM(p.payment_installments), '') AS INTEGER) AS installments,
    TRY_CAST(NULLIF(TRIM(p.payment_value), '') AS DOUBLE)         AS payment_value
FROM ods.order_payments p
WHERE NULLIF(TRIM(p.order_id), '') IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 事实：评价（粒度 = 1 review_id）
-- 注意：同一 review_id 在源数据中可能重复出现，保留最新一条，避免评分重复计数。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE dwd.fct_reviews AS
WITH ranked AS (
    SELECT
        NULLIF(TRIM(r.review_id), '')   AS review_id,
        NULLIF(TRIM(r.order_id), '')    AS order_id,
        TRY_CAST(NULLIF(TRIM(r.review_score), '') AS INTEGER) AS review_score,
        NULLIF(TRIM(r.review_comment_message), '') AS comment_message,
        TRY_CAST(NULLIF(TRIM(r.review_creation_date), '') AS TIMESTAMP) AS review_ts,
        TRY_CAST(NULLIF(TRIM(r.review_answer_timestamp), '') AS TIMESTAMP) AS answered_ts,
        ROW_NUMBER() OVER (PARTITION BY TRIM(r.review_id)
                           ORDER BY TRY_CAST(NULLIF(TRIM(r.review_answer_timestamp), '') AS TIMESTAMP) DESC) AS rn
    FROM ods.order_reviews r
    WHERE NULLIF(TRIM(r.review_id), '') IS NOT NULL
)
SELECT review_id, order_id, review_score, comment_message, review_ts, answered_ts,
       COALESCE(review_score <= 2, FALSE) AS is_negative
FROM ranked WHERE rn = 1;
