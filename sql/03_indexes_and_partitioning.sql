-- =============================================================================
-- Bank Transactions DWH — стратегия индексирования и партиционирования
-- Запускать после 01_schema_postgresql.sql (и после того, как в таблице
-- появятся данные — для примера с CLUSTER).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Индексы: индексировать стоит только колонки, регулярно участвующие в
-- WHERE/JOIN аналитических запросов — индексирование каждой колонки
-- факт-таблицы только замедляет массовую загрузку, не давая выигрыша на
-- чтении.
-- ---------------------------------------------------------------------------

CREATE INDEX idx_fact_trx_date     ON fact_transactions(date_id);
CREATE INDEX idx_fact_trx_customer ON fact_transactions(customer_id);
CREATE INDEX idx_fact_trx_account  ON fact_transactions(account_id);

-- Периодическая физическая кластеризация по date_id держит строки за один
-- и тот же период рядом на диске, что ускоряет выборки по диапазону дат
-- (выполнять в окне обслуживания — CLUSTER берёт эксклюзивную блокировку):
--
-- CLUSTER fact_transactions USING idx_fact_trx_date;

-- ---------------------------------------------------------------------------
-- Партиционирование: декларативное range-партиционирование по месяцам,
-- доступно начиная с PostgreSQL 10. При реальных банковских объёмах
-- (потенциально миллиарды строк в год) именно это делает архивирование
-- дешёвым — вместо медленного построчного DELETE можно просто отсоединить
-- партицию целиком.
-- ---------------------------------------------------------------------------

-- Чтобы этим воспользоваться, fact_transactions нужно изначально объявить
-- как партиционированную родительскую таблицу:
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
-- -- ... по одной партиции на месяц, создаётся заранее ETL-процессом.
--
-- Архивирование периода тогда сводится к:
-- ALTER TABLE fact_transactions DETACH PARTITION fact_transactions_2020_01;
--
-- Объём данных в docker-compose / демо-выборке этого репозитория намеренно
-- небольшой, поэтому 01_schema_postgresql.sql использует обычную
-- (непартиционированную) таблицу — этот файл документирует
-- партиционированный дизайн для промышленного масштаба, по аналогии с
-- партиционированием, уже применённым в 02_schema_clickhouse.sql
-- (PARTITION BY toYYYYMM(date)).
