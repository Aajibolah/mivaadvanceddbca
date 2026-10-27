-- =============================================================================
-- Sharding: what the router does with different queries.
-- Run:  psql -h localhost -p 5440 -U copay_admin -d copay_router -f routing_queries.sql
-- =============================================================================
\pset pager off
\set ON_ERROR_STOP off

\echo '=== 1. Where do the rows live? (tableoid shows the foreign partition = shard) ==='
SELECT tableoid::regclass AS shard_table, count(*) AS wallets, sum(balance)::numeric(16,2) AS total_balance
  FROM wallets_sharded GROUP BY 1 ORDER BY 1;

SELECT user_id AS sample_user FROM wallets_sharded ORDER BY user_id OFFSET 500 LIMIT 1 \gset
SELECT id AS sample_wallet FROM wallets_sharded WHERE user_id = :sample_user \gset

\echo
\echo '=== 2. Query WITH the shard key: the router sends it to ONE shard (partition pruning) ==='
EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM wallets_sharded WHERE user_id = :sample_user;
\echo '--- the whole statement screen for that user also hits one shard (wallet and ledger are co-located):'
EXPLAIN (VERBOSE, COSTS OFF)
SELECT l.created_at, l.amount FROM ledger_sharded l WHERE l.user_id = :sample_user ORDER BY l.created_at DESC LIMIT 20;

\echo
\echo '=== 3. Query WITHOUT the shard key: fan-out to EVERY shard ==='
EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM wallets_sharded WHERE id = :sample_wallet;
\echo 'Looking a wallet up by wallet id (not user id) asks both shards. Fine with 2 shards, expensive with 50.'
\echo 'Common fix: always carry user_id with the wallet id in the API, or keep a small lookup table wallet_id -> user_id.'

\echo
\echo '=== 4. Cross-shard aggregates: what is pushed down to the shards and what is not ==='
SET enable_partitionwise_aggregate = on;
\echo '--- 4a. A global total: the Remote SQL only selects the column, so EVERY row travels to the router and is summed there'
EXPLAIN (VERBOSE, COSTS OFF) SELECT count(*), sum(balance) FROM wallets_sharded;
\echo '--- 4b. Grouped BY THE SHARD KEY: each shard computes its own groups (look for GROUP BY inside Remote SQL)'
EXPLAIN (VERBOSE, COSTS OFF) SELECT user_id, sum(balance) FROM wallets_sharded GROUP BY user_id;
\echo 'Lesson: queries that group or filter by the shard key scale with the number of shards; global reports move data.'
\echo 'Analytics like the admin dashboard belong on a replica or warehouse, not on the sharded write path.'
SELECT count(*) AS wallets, sum(balance)::numeric(16,2) AS total FROM wallets_sharded;

\echo
\echo '=== 5. An insert is routed by the shard key ==='
BEGIN;
INSERT INTO wallets_sharded (id, user_id, kind, balance) VALUES (9000001, 9000001, 'USER', 0), (9000002, 9000002, 'USER', 0);
SELECT user_id, tableoid::regclass AS landed_on FROM wallets_sharded WHERE user_id IN (9000001, 9000002) ORDER BY user_id;
ROLLBACK;

\echo
\echo '=== 6. Skew and hot spots ==='
\echo 'Entries per shard (rows are spread by user, not by volume, so a busy user loads one shard):'
SELECT tableoid::regclass AS shard_table, count(*) AS ledger_rows,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
  FROM ledger_sharded GROUP BY 1 ORDER BY 1;
\echo 'The five busiest users and the share of all entries each holds:'
SELECT user_id, tableoid::regclass AS shard_table, count(*) AS entries,
       round(100.0 * count(*) / (SELECT count(*) FROM ledger_sharded), 2) AS pct_of_all
  FROM ledger_sharded GROUP BY user_id, tableoid ORDER BY entries DESC LIMIT 5;

\echo
\echo '=== 7. A foreign key / join across shards is not possible locally ==='
\echo 'Joining wallets_sharded to ledger_sharded on user_id is co-located, but a transfer between users on different shards is two writes on two servers: see cross_shard_2pc.ps1.'
