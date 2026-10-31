-- =============================================================================
-- Portfolio 5: declarative RANGE partitioning of the ledger by month.
-- Run on the main Copay database after Portfolio 1:  psql -f 01_range_partition_ledger.sql
--
-- Why partition the ledger: it only ever grows (append only), almost every query
-- filters by date (statements, monthly reports, reconciliation of one period),
-- and old months become cold. Monthly partitions give:
--   * partition pruning: a query for March reads only March;
--   * cheap retention: an old month is DETACHed or archived as one operation
--     instead of a huge DELETE (and deletes are forbidden on the ledger anyway);
--   * smaller indexes per partition and faster maintenance (VACUUM, REINDEX).
--
-- This builds a partitioned COPY (ledger_entries_part) so the live ledger and its
-- triggers from Portfolio 1 stay untouched. In production the migration would be
-- done on a new table with the triggers recreated, then swapped during a window.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

DROP TABLE IF EXISTS ledger_entries_part CASCADE;

-- The partition key must be part of every primary key / unique constraint.
CREATE TABLE ledger_entries_part (
    id         bigint        NOT NULL,
    txn_id     bigint        NOT NULL,
    wallet_id  bigint        NOT NULL,
    amount     numeric(14,2) NOT NULL CHECK (amount <> 0),
    created_at timestamptz   NOT NULL,
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- One partition per month for the period covered by the data, plus a DEFAULT
-- partition so a row outside the planned range is never rejected.
DO $$
DECLARE
    m date := date '2025-01-01';
BEGIN
    WHILE m < date '2027-01-01' LOOP
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF ledger_entries_part FOR VALUES FROM (%L) TO (%L)',
            'ledger_entries_p' || to_char(m, 'YYYY_MM'),
            to_char(m, 'YYYY-MM-DD') || ' 00:00:00+00',                       -- explicit UTC boundaries
            to_char(m + interval '1 month', 'YYYY-MM-DD') || ' 00:00:00+00');
        m := (m + interval '1 month')::date;
    END LOOP;
END $$;
CREATE TABLE ledger_entries_pdefault PARTITION OF ledger_entries_part DEFAULT;

-- An index on the parent is created on every partition automatically.
CREATE INDEX ledger_entries_part_wallet_created ON ledger_entries_part (wallet_id, created_at DESC);

INSERT INTO ledger_entries_part (id, txn_id, wallet_id, amount, created_at)
SELECT id, txn_id, wallet_id, amount, created_at FROM ledger_entries;
ANALYZE ledger_entries_part;

\echo
\echo '=== Rows per partition (proves data was routed) ==='
SELECT tableoid::regclass AS partition, count(*) AS rows, min(created_at)::date AS first_day, max(created_at)::date AS last_day
  FROM ledger_entries_part GROUP BY 1 ORDER BY 1;

\echo
\echo '=== Row count check: partitioned copy equals the live ledger ==='
SELECT (SELECT count(*) FROM ledger_entries) AS live_rows, (SELECT count(*) FROM ledger_entries_part) AS partitioned_rows;

\echo
\echo '=== Partition pruning: a one month query touches ONE partition ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT count(*), sum(amount) FROM ledger_entries_part
 WHERE created_at >= '2026-03-01 00:00+00' AND created_at < '2026-04-01 00:00+00';

\echo
\echo '=== Same question on the unpartitioned live ledger, for comparison (full table, filter by date) ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT count(*), sum(amount) FROM ledger_entries
 WHERE created_at >= '2026-03-01 00:00+00' AND created_at < '2026-04-01 00:00+00';

\echo
\echo '=== How many partitions does each query touch? (pruning only works when the partition key is filtered) ==='
CREATE OR REPLACE FUNCTION count_partitions_scanned(p_query text) RETURNS integer
LANGUAGE plpgsql AS
$$
DECLARE
    r text;
    n integer := 0;
BEGIN
    FOR r IN EXECUTE 'EXPLAIN (COSTS OFF) ' || p_query LOOP
        -- A scan node of any kind on a ledger partition: Seq/Bitmap Heap/Index/Index Only Scan, optionally
        -- Parallel, Backward and "using <index>", followed by "on ledger_entries_p<month or default>".
        IF r ~ '^\s*(->\s+)?(Parallel )?(Seq Scan|Bitmap Heap Scan|Index Scan|Index Only Scan)( Backward)?( using \S+)? on ledger_entries_p' THEN
            n := n + 1;
        END IF;
    END LOOP;
    RETURN n;
END;
$$;
SELECT 'one month filter'          AS query, count_partitions_scanned($q$SELECT count(*) FROM ledger_entries_part WHERE created_at >= '2026-03-01 00:00+00' AND created_at < '2026-04-01 00:00+00'$q$) AS partitions_scanned
UNION ALL
SELECT 'wallet only, no date',        count_partitions_scanned($q$SELECT count(*) FROM ledger_entries_part WHERE wallet_id = 100$q$)
UNION ALL
SELECT 'wallet + one month',          count_partitions_scanned($q$SELECT count(*) FROM ledger_entries_part WHERE wallet_id = 100 AND created_at >= '2026-09-01 00:00+00' AND created_at < '2026-10-01 00:00+00'$q$);
\echo 'Without a date filter every partition (plus the DEFAULT one) is scanned. Design rule: statement queries must always carry a date range.'

\echo
\echo '=== A wallet statement WITH a date range uses pruning plus the per partition index ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT * FROM ledger_entries_part
 WHERE wallet_id = 100 AND created_at >= '2026-09-01 00:00+00' AND created_at < '2026-10-01 00:00+00'
 ORDER BY created_at DESC;

\echo
\echo '=== Retention: detach an old month in one fast metadata operation, then archive or drop it ==='
BEGIN;
ALTER TABLE ledger_entries_part DETACH PARTITION ledger_entries_p2025_01;
SELECT 'detached table now stands alone: ' || count(*) || ' rows' AS note FROM ledger_entries_p2025_01;
SELECT 'parent no longer contains January 2025: ' || count(*) || ' rows in that month'
  FROM ledger_entries_part WHERE created_at >= '2025-01-01' AND created_at < '2025-02-01';
ROLLBACK;     -- demo only; a real job would archive the detached table to cheap storage

\echo
\echo '=== Routine job: create next month''s partition ahead of time ==='
CREATE OR REPLACE FUNCTION create_next_ledger_partition(p_month date DEFAULT (date_trunc('month', now()) + interval '1 month')::date)
RETURNS text LANGUAGE plpgsql AS
$$
DECLARE
    v_name text := 'ledger_entries_p' || to_char(p_month, 'YYYY_MM');
BEGIN
    IF to_regclass(v_name) IS NOT NULL THEN
        RETURN v_name || ' already exists';
    END IF;
    EXECUTE format('CREATE TABLE %I PARTITION OF ledger_entries_part FOR VALUES FROM (%L) TO (%L)',
                   v_name, to_char(p_month, 'YYYY-MM-DD') || ' 00:00:00+00',
                   to_char(p_month + interval '1 month', 'YYYY-MM-DD') || ' 00:00:00+00');
    RETURN v_name || ' created';
END;
$$;
SELECT create_next_ledger_partition(date '2027-01-01');
SELECT create_next_ledger_partition(date '2027-01-01');   -- second call is a no-op
