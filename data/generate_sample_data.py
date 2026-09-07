"""
Synthetic data generator for the Bank Transactions DWH demo.

The coursework this repo is based on designed the schema and the analytical
queries; this script is the part that turns it into something you can
actually run: it fills the star schema with realistic, fully synthetic
data (Faker-generated customers, a 2024-2025 date dimension, random but
plausible transactions) so that sql/04_analytical_queries.sql returns real
results instead of running against empty tables.

No real bank data of any kind is used or referenced here.

Usage:
    pip install psycopg2-binary faker
    python generate_sample_data.py \
        --dsn "postgresql://dwh_user:dwh_pass@localhost:5432/bank_dwh" \
        --customers 500 --transactions 20000

Run sql/01_schema_postgresql.sql against the target database first.
"""

import argparse
import random
from datetime import date, datetime, timedelta

from faker import Faker
import psycopg2
import psycopg2.extras

fake = Faker("ru_RU")
Faker.seed(42)
random.seed(42)

SEGMENTS = ["Mass Market", "Mass Affluent", "VIP", "Corporate"]
REGIONS = ["Moscow", "Saint Petersburg", "Novosibirsk", "Kazan", "Yekaterinburg", "Sochi"]

CHANNELS = [
    ("Internet Banking", "remote"),
    ("Mobile App", "remote"),
    ("Branch", "physical"),
    ("ATM", "physical"),
    ("POS Terminal", "physical"),
]

TRANSACTION_TYPES = [
    ("Payment", "Debit"),
    ("Withdrawal", "Debit"),
    ("Transfer", "Debit"),
    ("Deposit", "Credit"),
    ("Fee Charge", "Debit"),
    ("Interest Accrual", "Credit"),
]

PRODUCTS = [
    ("Debit Card", "Card"),
    ("Credit Card", "Card"),
    ("Savings Account", "Deposit"),
    ("Current Account", "Account"),
    ("Mortgage Loan", "Loan"),
    ("Consumer Loan", "Loan"),
]

ACCOUNT_TYPES = ["current", "card", "credit"]
CURRENCIES = ["RUB", "USD", "EUR"]
# Overwhelming majority of transactions should be in RUB, matching a
# realistic Russian-bank transaction mix.
CURRENCY_WEIGHTS = [0.92, 0.05, 0.03]

DATE_START = date(2024, 1, 1)
DATE_END = date(2025, 12, 31)


def daterange(start: date, end: date):
    days = (end - start).days
    for i in range(days + 1):
        yield start + timedelta(days=i)


def load_dim_date(cur):
    rows = []
    for d in daterange(DATE_START, DATE_END):
        rows.append((
            d, d.isoweekday(), d.month, (d.month - 1) // 3 + 1, d.year,
            d.isoweekday() in (6, 7),
        ))
    result = psycopg2.extras.execute_values(
        cur,
        """INSERT INTO dim_date (calendar_date, day_of_week, month, quarter, year, is_weekend)
           VALUES %s RETURNING date_id""",
        rows,
        page_size=1000, fetch=True,
    )
    return [r[0] for r in result]


def load_dim_channel(cur):
    result = psycopg2.extras.execute_values(
        cur,
        "INSERT INTO dim_channel (channel_name, channel_type) VALUES %s RETURNING channel_id",
        CHANNELS,
        fetch=True,
    )
    return [r[0] for r in result]


def load_dim_transaction_type(cur):
    result = psycopg2.extras.execute_values(
        cur,
        "INSERT INTO dim_transaction_type (type_name, category) VALUES %s RETURNING type_id",
        TRANSACTION_TYPES,
        fetch=True,
    )
    return [r[0] for r in result]


def load_dim_product(cur):
    result = psycopg2.extras.execute_values(
        cur,
        "INSERT INTO dim_product (product_name, product_category) VALUES %s RETURNING product_id",
        PRODUCTS,
        fetch=True,
    )
    return [r[0] for r in result]


def load_dim_customer(cur, n_customers):
    rows = []
    # A named, deterministic customer so sql/04_analytical_queries.sql's
    # drill-through example (query 8) has a guaranteed match out of the box.
    rows.append(("Ivanov I.I.", date(1985, 3, 12), "VIP", "Moscow", "individual", 2))
    for _ in range(n_customers - 1):
        is_corporate = random.random() < 0.15
        rows.append((
            fake.company() if is_corporate else fake.name(),
            None if is_corporate else fake.date_of_birth(minimum_age=18, maximum_age=80),
            random.choices(SEGMENTS, weights=[0.55, 0.2, 0.1, 0.15])[0],
            random.choice(REGIONS),
            "legal" if is_corporate else "individual",
            random.randint(1, 5),
        ))
    result = psycopg2.extras.execute_values(
        cur,
        """INSERT INTO dim_customer (full_name, birth_date, segment, region, client_type, risk_rating)
           VALUES %s RETURNING customer_id""",
        rows,
        page_size=1000, fetch=True,
    )
    return [r[0] for r in result]


def load_dim_account(cur, customer_ids, product_ids):
    rows = []
    for cust_id in customer_ids:
        for _ in range(random.randint(1, 2)):
            open_dt = fake.date_between(start_date=date(2018, 1, 1), end_date=date(2024, 6, 1))
            rows.append((
                fake.iban(),
                cust_id,
                random.choice(product_ids),
                random.choice(ACCOUNT_TYPES),
                random.choices(CURRENCIES, weights=CURRENCY_WEIGHTS)[0],
                open_dt,
                None,
            ))
    result = psycopg2.extras.execute_values(
        cur,
        """INSERT INTO dim_account
           (account_number, customer_id, product_id, account_type, currency, open_date, close_date)
           VALUES %s RETURNING account_id, customer_id""",
        rows,
        page_size=1000, fetch=True,
    )
    return result  # list of (account_id, customer_id)


def load_fact_transactions(cur, n_transactions, accounts, date_ids_by_ymd,
                            channel_ids, type_ids, product_ids):
    rows = []
    for _ in range(n_transactions):
        account_id, customer_id = random.choice(accounts)
        d = fake.date_between(start_date=DATE_START, end_date=DATE_END)
        date_id = date_ids_by_ymd[d]
        amount = round(random.lognormvariate(8.5, 1.2), 2)  # skewed, realistic-looking amounts
        fee = round(amount * random.choice([0, 0, 0, 0.005, 0.01]), 2)
        balance_before = round(random.uniform(0, 500_000), 2)
        balance_after = round(balance_before + amount, 2)
        t = datetime.combine(d, fake.time_object())
        rows.append((
            date_id, customer_id, account_id,
            random.choice(channel_ids), random.choice(type_ids), random.choice(product_ids),
            amount, fee, random.choices(CURRENCIES, weights=CURRENCY_WEIGHTS)[0],
            t, balance_before, balance_after,
            fake.bothify(text="DOC-########"), None,
        ))
    psycopg2.extras.execute_values(
        cur,
        """INSERT INTO fact_transactions
           (date_id, customer_id, account_id, channel_id, type_id, product_id,
            amount, fee, currency, transaction_time, balance_before, balance_after,
            document_id, comment)
           VALUES %s""",
        rows,
        page_size=1000,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dsn", required=True, help="PostgreSQL connection string")
    parser.add_argument("--customers", type=int, default=500)
    parser.add_argument("--transactions", type=int, default=20000)
    args = parser.parse_args()

    conn = psycopg2.connect(args.dsn)
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            print("Loading dim_date ...")
            date_ids = load_dim_date(cur)
            cur.execute("SELECT date_id, calendar_date FROM dim_date")
            date_ids_by_ymd = {row[1]: row[0] for row in cur.fetchall()}

            print("Loading dim_channel, dim_transaction_type, dim_product ...")
            channel_ids = load_dim_channel(cur)
            type_ids = load_dim_transaction_type(cur)
            product_ids = load_dim_product(cur)

            print(f"Loading dim_customer ({args.customers} customers) ...")
            customer_ids = load_dim_customer(cur, args.customers)

            print("Loading dim_account ...")
            accounts = load_dim_account(cur, customer_ids, product_ids)

            print(f"Loading fact_transactions ({args.transactions} rows) ...")
            load_fact_transactions(
                cur, args.transactions, accounts, date_ids_by_ymd,
                channel_ids, type_ids, product_ids,
            )
        conn.commit()
        print("Done.")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
