"""转换逻辑契约测试：用合成小数据驱动 DWD/DWS/ADS 全链路。

设计思路：数仓最容易坏的不是"跑不跑得通"，而是口径悄悄变了。
所以这里验证的是契约（contract）：
  1. 非法时间戳的订单必须进隔离区，且不进事实表
  2. 客户维度按自然人去重（Olist 一客多单的坑）
  3. 评价按 review_id 去重，防止评分重复计数
  4. 订单宽表 GMV 必须与明细严格勾稽
  5. RFM 快照日取数据内最大时间，而非系统当前时间
"""

from __future__ import annotations

from pathlib import Path

import duckdb
import pytest

from star_pipeline.warehouse import Warehouse

SQL_DIR = Path(__file__).resolve().parents[1] / "sql"

CUSTOMERS = """
SELECT * FROM (VALUES
    ('c1', 'u1', '01001', 'sao paulo', 'SP'),
    ('c2', 'u1', '01002', 'sao paulo', 'SP'),
    ('c3', 'u2', '20000', 'rio de janeiro', 'RJ')
) AS t(customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state)
"""

ORDERS = """
SELECT * FROM (VALUES
    ('o1', 'c1', 'delivered', '2018-01-10 10:00:00', '2018-01-10 11:00:00', '2018-01-12 09:00:00', '2018-01-20 10:00:00', '2018-01-25 00:00:00'),
    ('o2', 'c2', 'delivered', '2018-03-05 10:00:00', '2018-03-05 12:00:00', '2018-03-07 09:00:00', '2018-03-15 10:00:00', '2018-03-20 00:00:00'),
    ('o3', 'c3', 'canceled',  NULL, NULL, NULL, NULL, NULL),
    ('o4', 'c3', 'delivered', '2018-01-05 08:00:00', '2018-01-05 09:00:00', '2018-01-06 09:00:00', '2018-01-15 10:00:00', '2018-01-20 00:00:00')
) AS t(order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
       order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date)
"""

ITEMS = """
SELECT * FROM (VALUES
    ('o1', 1, 'p1', 's1', '2018-01-11 00:00:00', 100.0, 10.0),
    ('o1', 2, 'p2', 's1', '2018-01-11 00:00:00', 50.0, 10.0),
    ('o2', 1, 'p1', 's2', '2018-03-06 00:00:00', 200.0, 20.0),
    ('o4', 1, 'p2', 's1', '2018-01-06 00:00:00', 80.0, 8.0)
) AS t(order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value)
"""

PAYMENTS = """
SELECT * FROM (VALUES
    ('o1', 1, 'credit_card', 3, 170.0),
    ('o2', 1, 'boleto', 1, 220.0),
    ('o4', 1, 'boleto', 1, 88.0)
) AS t(order_id, payment_sequential, payment_type, payment_installments, payment_value)
"""

REVIEWS = """
SELECT * FROM (VALUES
    ('r1', 'o1', 5, 'great', '2018-01-22 00:00:00', '2018-01-23 00:00:00'),
    ('r1', 'o1', 5, 'great', '2018-01-22 00:00:00', '2018-01-24 00:00:00'),
    ('r2', 'o2', 2, 'late', '2018-03-16 00:00:00', '2018-03-17 00:00:00')
) AS t(review_id, order_id, review_score, review_comment_message, review_creation_date, review_answer_timestamp)
"""

PRODUCTS = """
SELECT * FROM (VALUES
    ('p1', 'cama_mesa_banho', '40', '300', '2', '500', '30', '20', '10'),
    ('p2', 'beleza_saude', '30', '200', '1', '300', '20', '15', '8')
) AS t(product_id, product_category_name, product_name_lenght, product_description_lenght,
       product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm)
"""

SELLERS = """
SELECT * FROM (VALUES
    ('s1', '01001', 'sao paulo', 'SP'),
    ('s2', '20000', 'rio de janeiro', 'RJ')
) AS t(seller_id, seller_zip_code_prefix, seller_city, seller_state)
"""

TRANSLATION = """
SELECT * FROM (VALUES
    ('cama_mesa_banho', 'bed_bath_table'),
    ('beleza_saude', 'health_beauty')
) AS t(product_category_name, product_category_name_english)
"""


def _load_ods(con: duckdb.DuckDBPyConnection) -> None:
    for schema in ("ods", "dwd", "dws", "ads", "meta", "quality"):
        con.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
    for table, ddl in (
        ("customers", CUSTOMERS),
        ("orders", ORDERS),
        ("order_items", ITEMS),
        ("order_payments", PAYMENTS),
        ("order_reviews", REVIEWS),
        ("products", PRODUCTS),
        ("sellers", SELLERS),
        ("category_translation", TRANSLATION),
    ):
        # ODS 层契约：所有贴源表都是全 VARCHAR + 审计列（生产中由 all_varchar=true 保证）
        con.execute(
            f"CREATE TABLE ods.{table} AS SELECT *, CURRENT_TIMESTAMP AS _ingested_at, 'test' AS _src_file FROM ({ddl})"
        )
        cols = [r[0] for r in con.execute(f"DESCRIBE ods.{table}").fetchall()]
        biz = ", ".join(f'CAST("{c}" AS VARCHAR) AS "{c}"' for c in cols if c not in ("_ingested_at", "_src_file"))
        con.execute(f"CREATE OR REPLACE TABLE ods.{table} AS SELECT {biz}, _ingested_at, _src_file FROM ods.{table}")


@pytest.fixture(scope="module")
def wh(tmp_path_factory) -> Warehouse:
    """在临时库上执行 DWD -> DWS -> ADS -> 质量校验全链路。"""
    warehouse = Warehouse(tmp_path_factory.mktemp("wh") / "test.duckdb")
    _load_ods(warehouse.con)
    variables = {"RAW_DIR": "unused"}
    for name in ("20_dwd.sql", "30_dws.sql", "40_ads.sql", "50_quality.sql"):
        warehouse.run_sql_file(SQL_DIR / name, variables)
    yield warehouse
    warehouse.close()


def test_invalid_timestamp_goes_to_quarantine(wh: Warehouse):
    assert wh.scalar("SELECT COUNT(*) FROM quality.quarantine_orders WHERE reject_reason = 'INVALID_PURCHASE_TIMESTAMP'") == 1
    assert wh.scalar("SELECT COUNT(*) FROM dwd.fct_orders WHERE order_id = 'o3'") == 0


def test_customer_dim_deduped_by_unique_id(wh: Warehouse):
    # u1 有两个 customer_id，但自然人只有一行，且观测单数保留为 2
    row = wh.con.execute(
        "SELECT COUNT(*), MAX(observed_orders) FROM dwd.dim_customer WHERE customer_key = 'u1'"
    ).fetchone()
    assert row == (1, 2)


def test_reviews_deduped_by_review_id(wh: Warehouse):
    # r1 出现两次，只保留 answer 最新的一条
    assert wh.scalar("SELECT COUNT(*) FROM dwd.fct_reviews WHERE review_id = 'r1'") == 1


def test_order_wide_gmv_reconciles_with_items(wh: Warehouse):
    # GMV 口径 = 商品金额（price），运费单独存放在 freight 列
    assert wh.scalar("SELECT SUM(gmv) FROM dws.order_wide") == 430.0
    assert wh.scalar("SELECT SUM(freight) FROM dws.order_wide") == 48.0
    assert wh.scalar("SELECT paid_amount FROM dws.order_wide WHERE order_id = 'o1'") == 170.0


def test_late_delivery_flag(wh: Warehouse):
    # o1 承诺 01-25 送达，实际 01-20，不算延误；o2 承诺 03-20，实际 03-15，同样不延误
    assert wh.scalar("SELECT COUNT(*) FROM dwd.fct_orders WHERE is_late") == 0
    assert wh.scalar("SELECT delivery_days FROM dws.order_wide WHERE order_id = 'o1'") == 10


def test_rfm_snapshot_is_data_max_not_today(wh: Warehouse):
    # 快照日 = 数据内最大下单时间 2018-03-05，而不是系统当前日期。
    # u1 最近一单就是 03-05 → recency 0；u2 最近一单是 01-05 → recency 59。
    assert wh.scalar("SELECT recency_days FROM dws.customer_rfm WHERE customer_key = 'u1'") == 0
    assert wh.scalar("SELECT recency_days FROM dws.customer_rfm WHERE customer_key = 'u2'") == 59


def test_rfm_segments_assigned(wh: Warehouse):
    segments = {r[0] for r in wh.con.execute("SELECT segment FROM ads.rfm_scored").fetchall()}
    assert segments, "RFM 分群不应为空"


def test_quality_gate_all_pass_on_clean_data(wh: Warehouse):
    rows = wh.con.execute("SELECT check_name, passed FROM quality.check_results").fetchall()
    assert rows, "质量校验结果不应为空"
    failed = [name for name, ok in rows if not ok]
    assert failed == [], f"干净数据上不应有失败校验: {failed}"
