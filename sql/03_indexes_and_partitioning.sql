-- =============================================================================
-- Bank Transactions DWH — indexing & partitioning strategy
-- Run this after 01_schema_postgresql.sql (and after the table has data,
-- for the CLUSTER example).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Indexing: only index columns that regularly appear in WHERE/JOIN clauses
-- of analytical queries — indexing every column of a fact table just slows
-- down bulk loads without a matching read-side benefit.
-- ---------------------------------------------------------------------------

CREATE INDEX idx_fact_trx_date     ON fact_transactions(date_id);
CREATE INDEX idx_fact_trx_customer ON fact_transactions(customer_id);
CREATE INDEX idx_fact_trx_account  ON fact_transactions(account_id);

-- Periodic physical re-clustering by date_id keeps rows for the same
-- time period close together on disk, which speeds up range scans over
-- a period (run during a maintenance window — CLUSTER takes an
-- exclusive lock):
--
-- CLUSTER fact_transactions USING idx_fact_trx_date;

-- ---------------------------------------------------------------------------
-- Partitioning: declarative range partitioning by month, available since
-- PostgreSQL 10. At real banking volumes (potentially billions of rows/year)
-- this is what makes archiving cheap — dropping a whole partition instead
-- of a slow row-by-row DELETE.
-- ---------------------------------------------------------------------------

-- To use this, fact_transactions has to be declared as the partitioned
-- parent up front:
--
-- CREATE TABLE fact_transactions (
--     transaction_id   BIGSERIAL,
--     date_id          INTEGER REFERENCES dim_date(date_id),
--     customer_id      INTEGER REFERENCES dim_customer(customer_id),
--     account_id       INTEGER REFERENCES dim_account(account_id),
--     channel_id       INTEGER REFERENCES dim_channel(channel_id),
--     type_id          INTEGER REFERENCES dim_transaction_type(type_id),
--     product_id       INTEGER REFERENCES dim_product(product_id),
--     amount           NUMERIC(18,2),
--     fee              NUMERIC(18,2),
--     currency         CHAR(3),
--     transaction_time TIMESTAMP NOT NULL,
--     balance_before   NUMERIC(18,2),
--     balance_after    NUMERIC(18,2),
--     document_id      VARCHAR(50),
--     comment          TEXT,
--     PRIMARY KEY (transaction_id, transaction_time)
-- ) PARTITION BY RANGE (transaction_time);
--
-- CREATE TABLE fact_transactions_2025_01 PARTITION OF fact_transactions
--     FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
-- CREATE TABLE fact_transactions_2025_02 PARTITION OF fact_transactions
--     FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
-- -- ... one partition per month, created by the ETL job ahead of time.
--
-- Archiving a period then becomes:
-- ALTER TABLE fact_transactions DETACH PARTITION fact_transactions_2020_01;
--
-- This repo's docker-compose / sample-data volume is intentionally small
-- (a demo run), so 01_schema_postgresql.sql uses the plain (non-partitioned)
-- table — this file documents the partitioned design for scale, matching
-- the ClickHouse partitioning already applied in 02_schema_clickhouse.sql
-- (PARTITION BY toYYYYMM(date)).
