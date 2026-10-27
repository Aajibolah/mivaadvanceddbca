#!/usr/bin/env python3
"""
Copies user wallets and ledger entries from the main Copay database into the sharded
tables on the router. The router decides the shard for each row from hash(user_id);
this script just inserts through the router and never chooses a shard itself.

    python shard_loader.py --source-port 5432 --router-port 5440 --ledger-limit 60000

Credentials come from PGPASSWORD / PGUSER (and .env), as for the other scripts.
"""
import argparse
import os
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parents[2]


def load_dotenv():
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def dsn(port, db):
    load_dotenv()
    g = os.environ.get
    return (f"host=localhost port={port} dbname={db} user={g('PGUSER', g('POSTGRES_USER', 'copay_admin'))} "
            f"password={g('PGPASSWORD', g('POSTGRES_PASSWORD', ''))}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source-port", default="5432")
    ap.add_argument("--source-db", default=os.environ.get("PGDATABASE", "copay"))
    ap.add_argument("--router-port", default="5440")
    ap.add_argument("--ledger-limit", type=int, default=60000)
    ap.add_argument("--batch", type=int, default=2000)
    args = ap.parse_args()

    with psycopg.connect(dsn(args.source_port, args.source_db)) as src, \
            psycopg.connect(dsn(args.router_port, "copay_router")) as dst:
        wallets = src.execute("SELECT id, user_id, kind::text, balance FROM wallets WHERE kind = 'USER' ORDER BY id").fetchall()
        with dst.cursor() as cur:
            for i in range(0, len(wallets), args.batch):
                cur.executemany("INSERT INTO wallets_sharded (id, user_id, kind, balance) VALUES (%s, %s, %s, %s)",
                                wallets[i:i + args.batch])
        dst.commit()
        print(f"wallets loaded: {len(wallets):,}")

        # Most recent entries first, because recent history is what a statement screen reads.
        rows = src.execute("""SELECT e.id, e.txn_id, e.wallet_id, w.user_id, e.amount, e.created_at
                                FROM ledger_entries e JOIN wallets w ON w.id = e.wallet_id
                               WHERE w.kind = 'USER' ORDER BY e.id DESC LIMIT %s""", (args.ledger_limit,)).fetchall()
        with dst.cursor() as cur:
            for i in range(0, len(rows), args.batch):
                cur.executemany("INSERT INTO ledger_sharded (id, txn_id, wallet_id, user_id, amount, created_at) "
                                "VALUES (%s, %s, %s, %s, %s, %s)", rows[i:i + args.batch])
        dst.commit()
        print(f"ledger entries loaded: {len(rows):,}")

        for name, table in (("wallets", "wallets_sharded"), ("ledger", "ledger_sharded")):
            dist = dst.execute(f"SELECT tableoid::regclass::text, count(*) FROM {table} GROUP BY 1 ORDER BY 1").fetchall()
            print(f"{name} distribution across shards: " + ", ".join(f"{t}={n:,}" for t, n in dist))


if __name__ == "__main__":
    main()
