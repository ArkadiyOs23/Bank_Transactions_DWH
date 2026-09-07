-- =============================================================================
-- Bank Transactions DWH — схема PostgreSQL (staging + слой измерений)
-- Схема «звезда» (Кимбелл): 1 факт-таблица + 6 таблиц измерений.
--
-- Роль в архитектуре: PostgreSQL хранит staging-зону и таблицы измерений
-- (данные, требующие регулярных транзакционных обновлений: новые клиенты,
-- новые счета, изменения по SCD). Большая, только пополняемая факт-таблица
-- по замыслу должна жить в ClickHouse для аналитического чтения (см.
-- 02_schema_clickhouse.sql) — но тот же DDL факт-таблицы работает и
-- отдельно в PostgreSQL для небольшого/среднего развёртывания или для
-- локальной разработки — именно так и работает docker-compose в этом
-- репозитории.
-- =============================================================================

DROP TABLE IF EXISTS fact_transactions CASCADE;
DROP TABLE IF EXISTS dim_account CASCADE;
DROP TABLE IF EXISTS dim_product CASCADE;
DROP TABLE IF EXISTS dim_transaction_type CASCADE;
DROP TABLE IF EXISTS dim_channel CASCADE;
DROP TABLE IF EXISTS dim_date CASCADE;
DROP TABLE IF EXISTS dim_customer CASCADE;

-- ---------------------------------------------------------------------------
-- Измерения
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
    channel_name  VARCHAR(50),      -- ATM / Mobile App / Branch / POS Terminal / Internet Banking
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
-- Факт-таблица
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

-- Про FOREIGN KEY: для небольшого/среднего развёртывания (в том числе для
-- демо этого репозитория) FK на факт-таблице — это нормально, они ловят
-- ошибки загрузки на раннем этапе. В реальном банковском масштабе (сотни
-- миллионов+ строк в год) обычная практика — убрать их с факт-таблицы и
-- обеспечивать ссылочную целостность процедурно на уровне ETL, поскольку
-- проверка FK становится узким местом при массовой загрузке — подробнее
-- о компромиссе в README, а партиционированный вариант для такого
-- масштаба — в 03_indexes_and_partitioning.sql.
