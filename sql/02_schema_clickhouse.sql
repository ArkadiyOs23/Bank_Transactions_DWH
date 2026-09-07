-- =============================================================================
-- Bank Transactions DWH — ClickHouse schema (analytical fact layer)
--
-- Role in the architecture: ClickHouse stores fact_transactions at scale
-- and serves the heavy aggregating queries (see 04_analytical_queries.sql).
-- Dimensions stay small enough that they are usually looked up from
-- PostgreSQL or mirrored into ClickHouse as Dictionary tables; only the
-- fact table is shown here since that is where the engine choice matters.
-- =============================================================================

CREATE TABLE fact_transactions
(
    date         Date,
    customer_id  UInt32,
    account_id   UInt32,
    channel_id   UInt8,      -- < 256 channels: compact type
    type_id      UInt16,     -- < 65536 transaction types: compact type
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

-- Compact column types (UInt8/UInt16 for low-cardinality dimension keys)
-- keep the columnar footprint small and speed up scans — see README for
-- the full PostgreSQL-vs-ClickHouse trade-off table.
--
-- Skip index example — accelerates filtering by an attribute that is not
-- part of the ORDER BY key (e.g. filtering by currency without scanning
-- every granule):
--
-- ALTER TABLE fact_transactions
--     ADD INDEX idx_currency currency TYPE set(0) GRANULARITY 4;

-- No FOREIGN KEY / referential-integrity enforcement in ClickHouse by
-- design (columnar + MPP engines generally skip FKs — see README).
-- Referential integrity is instead guaranteed procedurally: the ETL
-- process loads/refreshes dimension tables before it loads facts that
-- reference them (see docs — ETL section reproduced from the source
-- coursework).
