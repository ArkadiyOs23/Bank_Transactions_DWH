# Bank Transactions DWH — a data warehouse for bank transaction analytics (OLAP)

![PostgreSQL](https://img.shields.io/badge/DB-PostgreSQL_16-336791)
![ClickHouse](https://img.shields.io/badge/DB-ClickHouse-yellow)
![Python](https://img.shields.io/badge/Python-3.11-blue)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

A star-schema data warehouse design for analyzing a bank's financial transactions,
plus a runnable demo: schema DDL, a synthetic data generator, and OLAP queries
you can execute end to end on your own machine.

The data model, the ETL design, and the technology comparisons in this repo come
from a course project ("Курсовая работа по дисциплине «Хранилища данных»»,
Financial University under the Government of the Russian Federation, 2025) —
see [Origin](#origin). What makes this repo more than the paper: real, executable
DDL, a Faker-based data generator that actually populates the schema, and a
docker-compose setup so anyone can run the whole thing in a few commands. No
real bank data is used anywhere — every row is synthetic.

## Business problem

Banks run their day-to-day operations on OLTP systems (core banking, card
processing, CRM) optimized for fast, small, single-record transactions. Those
systems are the wrong place to ask analytical questions — "what's our transaction
volume by channel this quarter", "who are our top clients by turnover", "what
share of activity has moved to mobile" — because scanning and aggregating
millions of rows for that kind of query competes with the same system's job of
processing live customer transactions. A data warehouse separates the two
workloads: it consolidates data from multiple operational systems into one
structure purpose-built for the read-heavy, aggregate-heavy queries analysts
actually run.

## Architecture

Three layers, each doing the job it's good at:

```mermaid
flowchart LR
    subgraph Sources
        ABS[Core Banking / АБС]
        CRM[CRM]
        DBO[Internet & Mobile Banking logs]
        CARD[Card Processing]
        EXT[External sources: KYC, credit bureaus]
    end
    Sources --> ETL[Airflow-orchestrated ETL\nPython + SQL]
    ETL --> STG[(PostgreSQL\nstaging + dimensions)]
    STG --> DWH[(ClickHouse\nfact_transactions, partitioned)]
    DWH --> BI[Power BI / Apache Superset]
    STG --> BI
```

| Layer | Technology | Role |
|---|---|---|
| Storage | PostgreSQL | Staging zone and dimension tables — transactional updates, referential integrity, SCD handling |
| Storage | ClickHouse | Fact table at scale — columnar storage, MergeTree partitioning, fast aggregation over hundreds of millions of rows |
| Integration | Apache Airflow + Python/SQL | Orchestrates nightly (and optionally intraday) ETL: extract from source systems, clean and conform in staging, load dimensions then facts |
| Analytics | Power BI (business users) / Apache Superset (technical analysts, open-source, strong ClickHouse support) | Dashboards and ad-hoc OLAP: slice, dice, drill-down, drill-through |

**Why PostgreSQL *and* ClickHouse, not just one:** PostgreSQL gives full
transactional guarantees for data that changes (customer records, account
status), which matters for correctness but doesn't need to be fast at massive
scale. ClickHouse gives near-real-time aggregation over the fact table, which
is append-only and can grow into the billions of rows — but it only supports
transactions partially (eventual consistency on insert) and isn't a good fit
for data that gets updated. ETL loads staging and dimensions into PostgreSQL
first, then feeds the fact table into ClickHouse.

## Data model

Kimball star schema: one fact table (`fact_transactions`) surrounded by six
dimensions, each reachable from the fact table in a single join.

```mermaid
erDiagram
    DIM_CUSTOMER ||--o{ FACT_TRANSACTIONS : "makes"
    DIM_DATE ||--o{ FACT_TRANSACTIONS : "occurs on"
    DIM_ACCOUNT ||--o{ FACT_TRANSACTIONS : "used in"
    DIM_CHANNEL ||--o{ FACT_TRANSACTIONS : "via"
    DIM_TRANSACTION_TYPE ||--o{ FACT_TRANSACTIONS : "classified as"
    DIM_PRODUCT ||--o{ FACT_TRANSACTIONS : "relates to"
    DIM_CUSTOMER ||--o{ DIM_ACCOUNT : "owns"
    DIM_PRODUCT ||--o{ DIM_ACCOUNT : "of type"

    DIM_CUSTOMER {
        int customer_id PK
        string full_name
        date birth_date
        string segment
        string region
        string client_type
        int risk_rating
    }
    DIM_DATE {
        int date_id PK
        date calendar_date
        int day_of_week
        int month
        int quarter
        int year
        bool is_weekend
    }
    DIM_ACCOUNT {
        int account_id PK
        string account_number
        int customer_id FK
        int product_id FK
        string account_type
        string currency
        date open_date
        date close_date
    }
    DIM_CHANNEL {
        int channel_id PK
        string channel_name
        string channel_type
    }
    DIM_TRANSACTION_TYPE {
        int type_id PK
        string type_name
        string category
    }
    DIM_PRODUCT {
        int product_id PK
        string product_name
        string product_category
    }
    FACT_TRANSACTIONS {
        bigint transaction_id PK
        int date_id FK
        int customer_id FK
        int account_id FK
        int channel_id FK
        int type_id FK
        int product_id FK
        numeric amount
        numeric fee
        string currency
        timestamp transaction_time
        numeric balance_before
        numeric balance_after
        string document_id
    }
```

### Why star, not snowflake

| Criterion | Star | Snowflake |
|---|---|---|
| Dimension normalization | Denormalized (one table per dimension) | Normalized into sub-tables by hierarchy |
| Query complexity | Low — one join per dimension | Higher — multiple joins per dimension |
| Read performance | Higher (fewer joins) | Can be lower on complex queries |
| Ease of understanding for analysts | High | Lower |
| Best fit | Most BI use cases with moderate-size dimensions | Deep hierarchical dimensions where storage duplication matters |

Banking dimensions here (customers, accounts, channels) are small and flat
enough that star wins on both query simplicity and read speed — the standard
choice for this kind of workload.

### Why OLTP and OLAP are split at all

| | OLTP | OLAP |
|---|---|---|
| Goal | Process individual transactions in real time | Analyze large historical volumes, surface insights |
| Workload | Frequent small writes (INSERT/UPDATE) | Infrequent, heavy read/aggregate queries |
| Schema | Normalized (3NF) — minimize duplication | Denormalized (star/snowflake) — optimize for reads |
| Latency | Milliseconds per transaction | Seconds to minutes per query is acceptable |
| History retained | Days to months | Years to decades |
| Typical engines | PostgreSQL, Oracle, MySQL | ClickHouse, Greenplum, Vertica |

### Slowly Changing Dimensions

Customer and account attributes change over time (a customer's segment, an
account's status). `dim_customer` is the SCD-sensitive dimension here: the
design supports SCD Type 2 (a new row per change, with validity time
boundaries) so that historical transactions stay linked to the customer state
that was true when they happened — important for point-in-time reporting.
This demo's generator loads current-state rows only; extending
`dim_customer` with `valid_from`/`valid_to`/`is_current` columns is the
natural next step for full history tracking.

### Partitioning and indexing

- **PostgreSQL**: declarative `PARTITION BY RANGE` on `transaction_time`
  (monthly partitions) so archiving old data is a `DETACH PARTITION`, not a
  slow row-by-row delete. See `sql/03_indexes_and_partitioning.sql`.
- **ClickHouse**: `PARTITION BY toYYYYMM(date)` is native to the `MergeTree`
  engine, combined with `ORDER BY (date, customer_id)` for fast range scans.
- Indexes are added selectively — on `date_id`, `customer_id`, `account_id` —
  the columns that actually appear in `WHERE`/`JOIN` clauses. Indexing every
  column of a fact table just slows down bulk loads for no read-side benefit.
- **FOREIGN KEY trade-off**: this demo keeps FKs on `fact_transactions` in
  PostgreSQL (they catch bad loads early and the demo's data volume is small
  enough that the write-side cost is negligible). At real banking scale,
  dropping FKs from the fact table and enforcing referential integrity
  procedurally in the ETL layer (load dimensions before the facts that
  reference them) is standard practice — it removes the constraint-checking
  bottleneck on bulk inserts. ClickHouse doesn't support FK constraints at
  all, by design, for the same reason.

## ETL process

Nightly batch load (with optional intraday incremental runs for fresher data),
orchestrated by Apache Airflow, implemented in Python + SQL:

1. **Extract** — pull from core banking (nightly SQL dump), CRM (API/replica),
   online/mobile banking logs (SFTP, CSV/JSON), card processing (message
   stream/files), external sources (REST APIs). Land everything unmodified
   in a staging area first.
2. **Transform** — deduplicate by business key, parse XML/JSON into tabular
   form, normalize currency codes (ISO 4217) and units, enrich (compute
   `date_id` from a timestamp, look up industry from a tax ID), validate
   referential integrity against the dimensions (reject or flag orphaned
   records), generate surrogate keys.
3. **Load** — upsert dimensions first (including SCD handling for
   `dim_customer`), then bulk-load facts (`COPY` in PostgreSQL, batch insert
   in ClickHouse), and record load metadata (`last_etl_time`, row counts) so
   a failed run can be safely reprocessed without creating duplicates —
   transactions are deduplicated by their unique business key from the core
   banking system.

Why Airflow: it doesn't transform data itself, but it schedules tasks,
tracks dependencies as a DAG, retries on failure, and gives you a web UI to
monitor runs — the standard way to make a hand-written Python/SQL ETL
pipeline operable rather than a pile of cron jobs.

## Sample queries and results

`sql/04_analytical_queries.sql` has 10 queries; all were run against the
generated sample dataset (500 customers, 20,000 transactions, 2024–2025) to
confirm they work. Two examples:

**Volume and turnover by channel, October 2025** (aggregation — slice + dice):

| channel | transaction_count | total_amount |
|---|---|---|
| POS Terminal | 161 | 1,848,031.71 |
| ATM | 191 | 1,788,768.77 |
| Internet Banking | 162 | 1,684,878.96 |
| Mobile App | 156 | 1,469,787.86 |
| Branch | 179 | 1,401,512.87 |

**Top-5 customers by turnover, 2025** (window function — `RANK() OVER`):

| full_name | segment | total_amount | rnk |
|---|---|---|---|
| Ostap Frolovich Knyazev | Mass Market | 831,911.77 | 1 |
| Tverdislav Izmailovich Nekrasov | Corporate | 700,836.79 | 2 |
| Yevgenia Yakusheva | VIP | 563,641.94 | 3 |
| Eleonora Martynova | Mass Market | 549,898.13 | 4 |
| Sobolev & Partners | Mass Affluent | 540,349.54 | 5 |

(Numbers are from randomly generated synthetic data — re-running the
generator produces different figures, since it uses a fixed random seed
only for reproducibility of structure, not specific values across runs of
different sizes.)

## Repository structure

```
sql/
  01_schema_postgresql.sql       — star schema DDL (6 dimensions + fact table)
  02_schema_clickhouse.sql       — ClickHouse fact table variant (MergeTree, partitioned)
  03_indexes_and_partitioning.sql — indexing strategy + PostgreSQL range partitioning
  04_analytical_queries.sql      — 10 OLAP queries: aggregation, drill-down,
                                    ranking, pivot, drill-through, window functions
data/
  generate_sample_data.py        — synthetic data generator (Faker), fully runnable
docker-compose.yml                — spins up PostgreSQL with the schema pre-applied
```

## Quickstart

```bash
git clone <this-repo-url>
cd Bank_Transactions_DWH

# 1. Start PostgreSQL with the schema already applied
docker compose up -d

# 2. Install generator dependencies
pip install psycopg2-binary faker

# 3. Populate with synthetic data
python data/generate_sample_data.py \
    --dsn "postgresql://dwh_user:dwh_pass@localhost:5432/bank_dwh" \
    --customers 500 --transactions 20000

# 4. Run the analytical queries
psql "postgresql://dwh_user:dwh_pass@localhost:5432/bank_dwh" -f sql/04_analytical_queries.sql
```

The ClickHouse script (`sql/02_schema_clickhouse.sql`) is included as the
reference design for the fact table at scale; this demo's docker-compose
runs the PostgreSQL-only path end to end, since standing up a ClickHouse
cluster is out of scope for a local demo.

## Origin

The data model (star schema, SCD design), the ETL architecture, the
PostgreSQL/ClickHouse technology comparison, and the analytical queries in
`sql/04_analytical_queries.sql` originate from my course project "Проектирование
хранилища данных для анализа финансовых операций банка с применением
OLAP-технологий" (Data Warehouses course, Financial University under the
Government of the Russian Federation, 2025). This repository adds: cleaned-up,
runnable DDL split into logical files; a synthetic data generator
(`data/generate_sample_data.py`); a docker-compose setup; and this README —
turning the paper's design into something anyone can clone and run.

## License

MIT — see [LICENSE](LICENSE).
