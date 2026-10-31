# Portfolio 5 in pgAdmin 4: partitioning, replication checks and shard routing

The scripts that create servers (`setup_replication.ps1`, `setup_shards.ps1`), the lag, synchronous commit, failover and two phase commit demos, and the backup test are PowerShell scripts and are run from the terminal. This guide covers the parts that are plain SQL and are easier to run and capture in pgAdmin's Query Tool.

**Rules for pgAdmin**
- Paste one step at a time (select all, delete, paste) and press F5 with nothing selected. pgAdmin shows only the **last** statement's result of a multi statement paste, so steps that need a visible result are kept to a single query.
- `EXPLAIN` output appears in **Data Output**, one line per row.
- Save screenshots into `evidence/` using the exact names below.
- Passwords are never written in this repository. Where a step asks for a password, use the one you set for the `copay_admin` role (the same value as `POSTGRES_PASSWORD` in your local `.env`).

## Part 1: range partitioning of the ledger (main database)

Open a Query Tool on the **copay** database of your normal server (port 5432).

### Step 1: create the partitioned table and the monthly partitions
```sql
DROP TABLE IF EXISTS ledger_entries_part CASCADE;

CREATE TABLE ledger_entries_part (
    id         bigint        NOT NULL,
    txn_id     bigint        NOT NULL,
    wallet_id  bigint        NOT NULL,
    amount     numeric(14,2) NOT NULL CHECK (amount <> 0),
    created_at timestamptz   NOT NULL,
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

DO $$
DECLARE
    m date := date '2025-01-01';
BEGIN
    WHILE m < date '2027-01-01' LOOP
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF ledger_entries_part FOR VALUES FROM (%L) TO (%L)',
            'ledger_entries_p' || to_char(m, 'YYYY_MM'),
            to_char(m, 'YYYY-MM-DD') || ' 00:00:00+00',
            to_char(m + interval '1 month', 'YYYY-MM-DD') || ' 00:00:00+00');
        m := (m + interval '1 month')::date;
    END LOOP;
END $$;

CREATE TABLE ledger_entries_pdefault PARTITION OF ledger_entries_part DEFAULT;
CREATE INDEX ledger_entries_part_wallet_created ON ledger_entries_part (wallet_id, created_at DESC);
```
Expected: Messages shows `Query returned successfully`. No screenshot needed.

### Step 2: copy the live ledger into it
```sql
INSERT INTO ledger_entries_part (id, txn_id, wallet_id, amount, created_at)
SELECT id, txn_id, wallet_id, amount, created_at FROM ledger_entries;
ANALYZE ledger_entries_part;
```
Expected: about 180,000 rows inserted. No screenshot.

### Step 3: rows per partition (proves the data was routed)
```sql
SELECT tableoid::regclass AS partition, count(*) AS rows, min(created_at)::date AS first_day, max(created_at)::date AS last_day
FROM ledger_entries_part GROUP BY 1 ORDER BY 1;
```
Expected: 22 partitions with rows. **Screenshot `p5-07-1-partition-rows.png`.**

### Step 4: the counts match the live ledger
```sql
SELECT (SELECT count(*) FROM ledger_entries) AS live_rows, (SELECT count(*) FROM ledger_entries_part) AS partitioned_rows;
```
Expected: the two numbers are equal. **Screenshot `p5-07-2-counts-match.png`.**

### Step 5: partition pruning (a one month query reads one partition)
```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT count(*), sum(amount) FROM ledger_entries_part
WHERE created_at >= '2026-03-01 00:00+00' AND created_at < '2026-04-01 00:00+00';
```
Expected: one scan on `ledger_entries_p2026_03` only. **Screenshot `p5-07-3-pruning.png`.**

### Step 6: the same question on the unpartitioned ledger
```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT count(*), sum(amount) FROM ledger_entries
WHERE created_at >= '2026-03-01 00:00+00' AND created_at < '2026-04-01 00:00+00';
```
Expected: a scan of the whole `ledger_entries` table with "Rows Removed by Filter". **Screenshot `p5-07-4-unpartitioned.png`.**

### Step 7: how many partitions each query touches
```sql
CREATE OR REPLACE FUNCTION count_partitions_scanned(p_query text) RETURNS integer
LANGUAGE plpgsql AS
$$
DECLARE
    r text;
    n integer := 0;
BEGIN
    FOR r IN EXECUTE 'EXPLAIN (COSTS OFF) ' || p_query LOOP
        IF r ~ '^\s*(->\s+)?(Parallel )?(Seq Scan|Bitmap Heap Scan|Index Scan|Index Only Scan)( Backward)?( using \S+)? on ledger_entries_p' THEN
            n := n + 1;
        END IF;
    END LOOP;
    RETURN n;
END;
$$;
```
Then, as a **separate** paste:
```sql
SELECT 'one month filter' AS query, count_partitions_scanned($q$SELECT count(*) FROM ledger_entries_part WHERE created_at >= '2026-03-01 00:00+00' AND created_at < '2026-04-01 00:00+00'$q$) AS partitions_scanned
UNION ALL
SELECT 'wallet only, no date', count_partitions_scanned($q$SELECT count(*) FROM ledger_entries_part WHERE wallet_id = 100$q$)
UNION ALL
SELECT 'wallet + one month', count_partitions_scanned($q$SELECT count(*) FROM ledger_entries_part WHERE wallet_id = 100 AND created_at >= '2026-09-01 00:00+00' AND created_at < '2026-10-01 00:00+00'$q$);
```
Expected: `1`, `25`, `1`. **Screenshot `p5-08-partitions-scanned.png`.**

### Step 8 (optional): retention, detach an old month
Run these three as **separate** pastes, in order:
```sql
BEGIN;
ALTER TABLE ledger_entries_part DETACH PARTITION ledger_entries_p2025_01;
```
```sql
SELECT (SELECT count(*) FROM ledger_entries_p2025_01) AS detached_rows, (SELECT count(*) FROM ledger_entries_part WHERE created_at < '2025-02-01 00:00+00') AS still_in_parent;
```
Expected: `detached_rows` about 61 and `still_in_parent` 0. **Screenshot `p5-08-2-detach.png`.** Then:
```sql
ROLLBACK;
```

## Part 2: replication checks in pgAdmin

First run `.\replication\setup_replication.ps1 -LoadData` in the terminal. Then register the two new servers in pgAdmin: right-click **Servers**, Register, Server.
- Name `Primary 5433`: host `localhost`, port `5433`, maintenance database `postgres`, username `copay_admin`, password (the `copay_admin` password), tick Save password.
- Name `Replica 5434`: the same with port `5434`.

### Step 1: replication status (on the primary)
Open a Query Tool on **Primary 5433**, database `postgres`:
```sql
SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication;
```
Expected: `replica1 | streaming | async`. **Screenshot `p5-01-pg-stat-replication.png`.**

### Step 2: write on the primary
Open a Query Tool on **Primary 5433**, database `copay`, and run:
```sql
CREATE TABLE IF NOT EXISTS hello(id serial, at timestamptz DEFAULT now());
INSERT INTO hello DEFAULT VALUES;
```

### Step 3: read on the replica
Open a Query Tool on **Replica 5434**, database `copay`, and run:
```sql
SELECT * FROM hello;
```
Expected: the row you wrote. **Screenshot `p5-02-1-replica-read.png`.**

### Step 4: the replica refuses writes
In the same replica Query Tool:
```sql
INSERT INTO hello DEFAULT VALUES;
```
Expected in Messages: `cannot execute INSERT in a read-only transaction`. **Screenshot `p5-02-2-replica-readonly.png`.**

Then continue with the terminal scripts: `lag_demo.ps1`, `sync_experiment.ps1`, and last `failover.ps1`.

## Part 3: shard routing in pgAdmin

First run `.\cleanup.ps1` and `.\sharding\setup_shards.ps1` in the terminal. Then register the router: name `Router 5440`, host `localhost`, port `5440`, maintenance database `copay_router`, username `copay_admin`, password (the `copay_admin` password). Open a Query Tool on database **copay_router**.

### Step 1: pick sample ids
```sql
SELECT user_id, id AS wallet_id FROM wallets_sharded ORDER BY user_id OFFSET 500 LIMIT 1;
```
Note both numbers. With the standard seed they are usually `509` and `504`; use whatever you get in place of those two numbers below.

### Step 2: which shard each row lives on
```sql
SELECT tableoid::regclass AS shard_table, count(*) AS wallets, sum(balance)::numeric(16,2) AS total_balance
FROM wallets_sharded GROUP BY 1 ORDER BY 1;
```
Expected: two rows, about 1,600 wallets each. **Screenshot `p5-10-1-shard-rows.png`.**

### Step 3: a query with the shard key goes to one shard
```sql
EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM wallets_sharded WHERE user_id = 509;
```
Expected: one `Foreign Scan`. **Screenshot `p5-10-2-one-shard.png`.**

### Step 4: a query without the shard key goes to every shard
```sql
EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM wallets_sharded WHERE id = 504;
```
Expected: an `Append` of two `Foreign Scan`s. **Screenshot `p5-10-3-fanout.png`.**

### Step 5: what is pushed down in aggregates
First paste:
```sql
SET enable_partitionwise_aggregate = on;
```
Then, as separate pastes (each in the same tab):
```sql
EXPLAIN (VERBOSE, COSTS OFF) SELECT count(*), sum(balance) FROM wallets_sharded;
```
Expected: the Remote SQL selects only `balance` (every row travels to the router). **Screenshot `p5-10-4-global-aggregate.png`.**
```sql
EXPLAIN (VERBOSE, COSTS OFF) SELECT user_id, sum(balance) FROM wallets_sharded GROUP BY user_id;
```
Expected: `GROUP BY` appears inside the Remote SQL (each shard computes its own groups). **Screenshot `p5-10-5-grouped-aggregate.png`.**

### Step 6: skew
```sql
SELECT user_id, tableoid::regclass AS shard_table, count(*) AS entries,
       round(100.0 * count(*) / (SELECT count(*) FROM ledger_sharded), 2) AS pct_of_all
FROM ledger_sharded GROUP BY user_id, tableoid ORDER BY entries DESC LIMIT 5;
```
Expected: the five busiest users and their share of all ledger rows. **Screenshot `p5-10-6-skew.png`.**

## Terminal steps (for reference)

`setup_replication.ps1`, `lag_demo.ps1`, `sync_experiment.ps1`, `failover.ps1`, `cleanup.ps1`, `setup_shards.ps1`, `cross_shard_2pc.ps1` and `backup_restore_test.ps1` are run from PowerShell. See `README.md` in this folder.
