-- =============================================================================
-- Bank Transactions DWH — PostgreSQL schema (staging + dimension layer)
-- Star schema (Kimball): 1 fact table + 6 dimension tables.
--
-- Role in the architecture: PostgreSQL holds the staging zone and the
-- dimension tables (data that needs regular, transactional updates:
-- new customers, new accounts, SCD changes). The large, append-only
-- fact table is meant to live in ClickHouse for analytical reads
-- (see 02_schema_clickhouse.sql) — but the same fact DDL also works
-- standalone in PostgreSQL for a small-to-medium deployment or for
-- local development, which is what this repo's docker-compose runs.
-- =============================================================================

DROP TABLE IF EXISTS fact_transactions CASCADE;
DROP TABLE IF EXISTS dim_account CASCADE;
DROP TABLE IF EXISTS dim_product CASCADE;
DROP TABLE IF EXISTS dim_transaction_type CASCADE;
DROP TABLE IF EXISTS dim_channel CASCADE;
DROP TABLE IF EXISTS dim_date CASCADE;
DROP TABLE IF EXISTS dim_customer CASCADE;

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

CREATE TABLE dim_customer (
    customer_id   SERIAL PRIMARY KEY,
    full_name     TEXT,
    birth_date    DATE,
    segment       VARCHAR(50),      -- Mass Market / Mass Affluent / VIP / Corporate
    region        VARCHAR(100),
    client_type   VARCHAR(10),      -- физ / юр
    risk_rating   INTEGER
);

CREATE TABLE dim_date (
    date_id       SERIAL PRIMARY KEY,
    calendar_date DATE,
    day_of_week   INTEGER,
    month         INTEGER,
    quarter       INTEGER,
    year          INTEGER,
    is_weekend    BOOLEAN
);

CREATE TABLE dim_channel (
    channel_id    SERIAL PRIMARY KEY,
    channel_name  VARCHAR(50),      -- ATM / Mobile App / Branch / POS-terminal / Internet Banking
    channel_type  VARCHAR(20)       -- физический / дистанционный
);

CREATE TABLE dim_transaction_type (
    type_id       SERIAL PRIMARY KEY,
    type_name     VARCHAR(50),      -- Payment / Withdrawal / Transfer / Fee Charge / Interest Accrual
    category      VARCHAR(20)       -- Debit / Credit
);

CREATE TABLE dim_product (
    product_id       SERIAL PRIMARY KEY,
    product_name     VARCHAR(100),  -- Debit Card / Savings Account / Mortgage Loan ...
    product_category VARCHAR(50)
);

CREATE TABLE dim_account (
    account_id     SERIAL PRIMARY KEY,
    account_number VARCHAR(34),
    customer_id    INTEGER REFERENCES dim_customer(customer_id),
    product_id     INTEGER REFERENCES dim_product(product_id),
    account_type   VARCHAR(30),     -- текущий / карточный / кредитный
    currency       CHAR(3),
    open_date      DATE,
    close_date     DATE
);

-- ---------------------------------------------------------------------------
-- Fact table
-- ---------------------------------------------------------------------------

CREATE TABLE fact_transactions (
    transaction_id   BIGSERIAL PRIMARY KEY,
    date_id          INTEGER REFERENCES dim_date(date_id),
    customer_id      INTEGER REFERENCES dim_customer(customer_id),
    account_id       INTEGER REFERENCES dim_account(account_id),
    channel_id       INTEGER REFERENCES dim_channel(channel_id),
    type_id          INTEGER REFERENCES dim_transaction_type(type_id),
    product_id       INTEGER REFERENCES dim_product(product_id),
    amount           NUMERIC(18,2),
    fee              NUMERIC(18,2),
    currency         CHAR(3),
    transaction_time TIMESTAMP,
    balance_before   NUMERIC(18,2),
    balance_after    NUMERIC(18,2),
    document_id      VARCHAR(50),
    comment          TEXT
);

-- Note on FOREIGN KEY usage: for a small/medium deployment (this repo's
-- demo included) FKs on the fact table are fine and catch bad loads early.
-- At real banking scale (hundreds of millions+ rows/year) it is common
-- practice to drop them from the fact table and enforce referential
-- integrity procedurally in the ETL layer instead, since FK checks become
-- a write-throughput bottleneck on bulk loads — see the README for the
-- trade-off discussion and 03_indexes_and_partitioning.sql for the
-- partitioned variant used at that scale.
