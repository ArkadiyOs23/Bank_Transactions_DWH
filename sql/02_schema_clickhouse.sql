-- =============================================================================
-- Bank Transactions DWH — схема ClickHouse (аналитический слой фактов)
--
-- Роль в архитектуре: ClickHouse хранит fact_transactions в промышленном
-- масштабе и обслуживает тяжёлые агрегирующие запросы (см.
-- 04_analytical_queries.sql). Измерения достаточно небольшие, поэтому их
-- обычно читают из PostgreSQL или зеркалируют в ClickHouse как таблицы
-- типа Dictionary; здесь показана только факт-таблица, поскольку именно
-- на ней выбор движка имеет значение.
-- =============================================================================

CREATE TABLE fact_transactions
(
    date         Date,
    customer_id  UInt32,
    account_id   UInt32,
    channel_id   UInt8,      -- < 256 каналов: компактный тип
    type_id      UInt16,     -- < 65536 видов операций: компактный тип
    product_id   UInt32,
    amount       Decimal(15, 2),
    fee          Decimal(15, 2),
    currency     FixedString(3),
    transaction_time DateTime
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, customer_id)
SETTINGS index_granularity = 8192;

-- Компактные типы колонок (UInt8/UInt16 для ключей измерений с низкой
-- кардинальностью) уменьшают колоночный объём и ускоряют сканирование —
-- полное сравнение PostgreSQL и ClickHouse — в README.
--
-- Пример скип-индекса — ускоряет фильтрацию по атрибуту, не входящему в
-- ORDER BY (например, фильтр по валюте без сканирования каждой гранулы):
--
-- ALTER TABLE fact_transactions
--     ADD INDEX idx_currency currency TYPE set(0) GRANULARITY 4;

-- В ClickHouse намеренно нет FOREIGN KEY / проверки ссылочной
-- целостности (колоночные и MPP-движки в целом отказываются от FK —
-- см. README). Вместо этого целостность обеспечивается процедурно: ETL
-- сначала загружает/обновляет таблицы измерений, и только потом —
-- факты, которые на них ссылаются (см. описание ETL-процесса,
-- воспроизведённое из исходной курсовой).
