-- =============================================================================
-- 00_ddl.sql  |  NEW_STAR 数仓骨架
-- 引擎：DuckDB 1.x（列存 OLAP，语法兼容 PostgreSQL 主体）
-- 分层：ods 贴源 -> dwd 明细 -> dws 汇总 -> ads 应用
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS ods;    -- 贴源层：字段全 VARCHAR，保留原始形态，只加审计列
CREATE SCHEMA IF NOT EXISTS dwd;    -- 明细层：清洗、去重、类型收敛、星型建模
CREATE SCHEMA IF NOT EXISTS dws;    -- 汇总层：按主题轻度聚合，宽表
CREATE SCHEMA IF NOT EXISTS ads;    -- 应用层：面向报表/看板的指标结果
CREATE SCHEMA IF NOT EXISTS meta;   -- 元数据：运行审计、水位线
CREATE SCHEMA IF NOT EXISTS quality;-- 质量：校验结果、隔离区

-- 运行审计表：每次 run 每个 step 一行，支撑可观测性与失败重跑
CREATE TABLE IF NOT EXISTS meta.pipeline_runs (
    run_id        VARCHAR NOT NULL,
    layer         VARCHAR NOT NULL,
    step_name     VARCHAR NOT NULL,
    started_at    TIMESTAMP NOT NULL,
    finished_at   TIMESTAMP,
    duration_ms   BIGINT,
    row_count     BIGINT,
    status        VARCHAR,   -- SUCCESS / FAILED
    error_message VARCHAR
);

-- 增量水位线：记录每张表已处理到的业务时间，供增量装载使用
CREATE TABLE IF NOT EXISTS meta.watermarks (
    table_name   VARCHAR PRIMARY KEY,
    watermark_ts TIMESTAMP NOT NULL,
    updated_at   TIMESTAMP NOT NULL
);
