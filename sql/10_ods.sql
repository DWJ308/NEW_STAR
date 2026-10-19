-- =============================================================================
-- 10_ods.sql  |  贴源层（ODS）
-- 原则：不做任何业务清洗，字段一律 VARCHAR，保留脏数据以便复查；
--       只追加 3 个审计列，保证"数据可溯源"。
-- 技术点：全列 VARCHAR 读取规避类型推断失败；原始文件指纹写入 meta 表
-- =============================================================================

CREATE OR REPLACE TABLE ods.orders AS
SELECT *, CURRENT_TIMESTAMP AS _ingested_at, 'olist_orders_dataset.csv' AS _src_file
FROM read_csv_auto('{{RAW_DIR}}/olist_orders_dataset.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE ods.order_items AS
SELECT *, CURRENT_TIMESTAMP AS _ingested_at, 'olist_order_items_dataset.csv' AS _src_file
FROM read_csv_auto('{{RAW_DIR}}/olist_order_items_dataset.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE ods.order_payments AS
SELECT *, CURRENT_TIMESTAMP AS _ingested_at, 'olist_order_payments_dataset.csv' AS _src_file
FROM read_csv_auto('{{RAW_DIR}}/olist_order_payments_dataset.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE ods.order_reviews AS
SELECT *, CURRENT_TIMESTAMP AS _ingested_at, 'olist_order_reviews_dataset.csv' AS _src_file
FROM read_csv_auto('{{RAW_DIR}}/olist_order_reviews_dataset.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE ods.customers AS
SELECT *, CURRENT_TIMESTAMP AS _ingested_at, 'olist_customers_dataset.csv' AS _src_file
FROM read_csv_auto('{{RAW_DIR}}/olist_customers_dataset.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE ods.products AS
SELECT *, CURRENT_TIMESTAMP AS _ingested_at, 'olist_products_dataset.csv' AS _src_file
FROM read_csv_auto('{{RAW_DIR}}/olist_products_dataset.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE ods.sellers AS
SELECT *, CURRENT_TIMESTAMP AS _ingested_at, 'olist_sellers_dataset.csv' AS _src_file
FROM read_csv_auto('{{RAW_DIR}}/olist_sellers_dataset.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE ods.category_translation AS
SELECT *, CURRENT_TIMESTAMP AS _ingested_at, 'product_category_name_translation.csv' AS _src_file
FROM read_csv_auto('{{RAW_DIR}}/product_category_name_translation.csv', header = true, all_varchar = true);
