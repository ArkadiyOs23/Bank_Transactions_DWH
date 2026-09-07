-- =============================================================================
-- Bank Transactions DWH — аналитические запросы (OLAP над схемой «звезда»)
-- Каждый запрос помечен операцией OLAP, которую он демонстрирует: slice,
-- dice, drill-down, drill-through, pivot, ранжирование/оконные функции.
-- Даты ниже рассчитаны на тестовые данные из data/generate_sample_data.py
-- (период 2024–2025) — поменяй фильтры по году/кварталу, если загрузил
-- другой период.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Объём и оборот по каналам обслуживания за месяц
--    OLAP-операции: slice (фиксированный месяц) + dice (группировка по каналу)
-- -----------------------------------------------------------------------------
SELECT ch.channel_name AS "Канал",
       COUNT(*)        AS "Число транзакций",
       SUM(f.amount)   AS "Сумма операций"
FROM fact_transactions f
JOIN dim_date d    ON f.date_id = d.date_id
JOIN dim_channel ch ON f.channel_id = ch.channel_id
WHERE d.year = 2025 AND d.month = 10
GROUP BY ch.channel_name
ORDER BY SUM(f.amount) DESC;

-- -----------------------------------------------------------------------------
-- 1b. Тот же отчёт, детализированный на уровень ниже: канал x вид операции
--     OLAP-операция: drill-down
-- -----------------------------------------------------------------------------
SELECT ch.channel_name, t.type_name,
       COUNT(*)      AS txn_count,
       SUM(f.amount) AS total_amount
FROM fact_transactions f
JOIN dim_date d              ON f.date_id = d.date_id
JOIN dim_channel ch          ON f.channel_id = ch.channel_id
JOIN dim_transaction_type t  ON f.type_id = t.type_id
WHERE d.year = 2025 AND d.month = 10
GROUP BY ch.channel_name, t.type_name
ORDER BY ch.channel_name, total_amount DESC;

-- -----------------------------------------------------------------------------
-- 2. Топ-5 клиентов по объёму операций за год
--    OLAP-операция: ранжирование через оконную функцию (RANK)
-- -----------------------------------------------------------------------------
SELECT cus.full_name, cus.segment,
       SUM(f.amount) AS total_amount,
       RANK() OVER (ORDER BY SUM(f.amount) DESC) AS rnk
FROM fact_transactions f
JOIN dim_date d       ON f.date_id = d.date_id
JOIN dim_customer cus ON f.customer_id = cus.customer_id
WHERE d.year = 2025
GROUP BY cus.customer_id, cus.full_name, cus.segment
ORDER BY total_amount DESC
LIMIT 5;

-- -----------------------------------------------------------------------------
-- 3. Распределение операций по видам со средним чеком
--    OLAP-операция: агрегация (COUNT/SUM/AVG)
-- -----------------------------------------------------------------------------
SELECT t.type_name    AS "Тип операции",
       COUNT(*)        AS "Кол-во",
       SUM(f.amount)   AS "Сумма, руб",
       AVG(f.amount)   AS "Средний чек, руб"
FROM fact_transactions f
JOIN dim_transaction_type t ON f.type_id = t.type_id
WHERE f.transaction_time BETWEEN '2025-01-01' AND '2025-12-31'
GROUP BY t.type_name
ORDER BY SUM(f.amount) DESC;

-- -----------------------------------------------------------------------------
-- 4. Матрица «канал x квартал» (pivot)
--    OLAP-операция: pivot через условную агрегацию (CASE WHEN)
-- -----------------------------------------------------------------------------
SELECT ch.channel_name,
       SUM(CASE WHEN d.quarter = 1 THEN f.amount ELSE 0 END) AS q1,
       SUM(CASE WHEN d.quarter = 2 THEN f.amount ELSE 0 END) AS q2,
       SUM(CASE WHEN d.quarter = 3 THEN f.amount ELSE 0 END) AS q3,
       SUM(CASE WHEN d.quarter = 4 THEN f.amount ELSE 0 END) AS q4
FROM fact_transactions f
JOIN dim_date d     ON f.date_id = d.date_id
JOIN dim_channel ch ON f.channel_id = ch.channel_id
WHERE d.year = 2025
GROUP BY ch.channel_name;

-- =============================================================================
-- Приложение — расширенные запросы: оконные функции, условная агрегация,
-- многомерные разрезы, drill-through
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5. Доля операций, обработанных быстрее 5 секунд
--    OLAP-операция: условная агрегация (метрика в духе SLA).
--    Требует колонку с интервалом обработки — её нет в базовой схеме
--    01_schema_postgresql.sql; добавь, если ведёшь учёт времени SLA.
-- -----------------------------------------------------------------------------
-- SELECT
--     100.0 * SUM(CASE WHEN f.processing_time <= interval '5 seconds' THEN 1 ELSE 0 END)
--         / COUNT(*) AS perc_fast
-- FROM fact_transactions f
-- WHERE f.date_id IN (SELECT date_id FROM dim_date WHERE year = 2025);

-- -----------------------------------------------------------------------------
-- 6. Помесячная динамика для одного сегмента клиентов
--    OLAP-операция: drill-down во времени
-- -----------------------------------------------------------------------------
SELECT d.year, d.month,
       COUNT(*)      AS txn_count,
       SUM(f.amount) AS total_amount
FROM fact_transactions f
JOIN dim_date d     ON f.date_id = d.date_id
JOIN dim_customer c ON f.customer_id = c.customer_id
WHERE c.segment = 'Mass Market' AND d.year = 2025
GROUP BY d.year, d.month
ORDER BY d.year, d.month;

-- -----------------------------------------------------------------------------
-- 7. Slice-and-dice: объём переводов по регионам клиентов, только Q1 2025
--    OLAP-операции: slice (квартал + тип) + dice (группировка по региону)
-- -----------------------------------------------------------------------------
SELECT c.region, SUM(f.amount) AS total_amount
FROM fact_transactions f
JOIN dim_date d             ON f.date_id = d.date_id
JOIN dim_customer c         ON f.customer_id = c.customer_id
JOIN dim_transaction_type t ON f.type_id = t.type_id
WHERE d.year = 2025 AND d.quarter = 1 AND t.type_name = 'Transfer'
GROUP BY c.region
ORDER BY 2 DESC;

-- -----------------------------------------------------------------------------
-- 8. Drill-through: полный список транзакций одного клиента за месяц
--    OLAP-операция: drill-through (агрегированный отчёт -> необработанные
--    строки факт-таблицы)
-- -----------------------------------------------------------------------------
SELECT f.transaction_id, d.calendar_date, f.amount, f.currency,
       t.type_name, ch.channel_name
FROM fact_transactions f
JOIN dim_date d              ON f.date_id = d.date_id
JOIN dim_customer c          ON f.customer_id = c.customer_id
JOIN dim_transaction_type t  ON f.type_id = t.type_id
JOIN dim_channel ch          ON f.channel_id = ch.channel_id
WHERE c.full_name = 'Иванов И.И.' AND d.year = 2025 AND d.month = 1;

-- -----------------------------------------------------------------------------
-- 9. Доля каждого канала в общем объёме операций
--    OLAP-операция: оконная функция без схлопывания через GROUP BY
--    (SUM ... OVER ())
-- -----------------------------------------------------------------------------
SELECT channel_name, txn_count, total_amount,
       total_amount * 100.0 / SUM(total_amount) OVER () AS pct_of_total
FROM (
    SELECT ch.channel_name, COUNT(*) AS txn_count, SUM(f.amount) AS total_amount
    FROM fact_transactions f
    JOIN dim_channel ch ON f.channel_id = ch.channel_id
    GROUP BY ch.channel_name
) t
ORDER BY total_amount DESC;

-- -----------------------------------------------------------------------------
-- 10. Среднее число операций на клиента, в разрезе сегмента и вида операции
--     OLAP-операция: многомерная агрегация с производной метрикой-отношением
-- -----------------------------------------------------------------------------
SELECT c.segment, t.type_name,
       COUNT(*) * 1.0 / COUNT(DISTINCT c.customer_id) AS avg_tx_per_client
FROM fact_transactions f
JOIN dim_customer c         ON f.customer_id = c.customer_id
JOIN dim_transaction_type t ON f.type_id = t.type_id
JOIN dim_date d              ON f.date_id = d.date_id
WHERE d.year = 2025 AND d.quarter = 1
GROUP BY c.segment, t.type_name;
