-- Runs on the ROUTER (coordinator). It stores no data itself: each hash partition
-- of the parent table is a FOREIGN table pointing at one shard, so PostgreSQL
-- routes inserts and prunes reads by the shard key (user_id) automatically.
--
-- Run with:  psql -v pw="'<password>'" ...   (the setup script does this)
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

CREATE SERVER shard1 FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5441', dbname 'copay_shard', batch_size '200', fetch_size '1000');
CREATE SERVER shard2 FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5442', dbname 'copay_shard', batch_size '200', fetch_size '1000');

CREATE USER MAPPING FOR CURRENT_USER SERVER shard1 OPTIONS (user 'copay_admin', password :pw);
CREATE USER MAPPING FOR CURRENT_USER SERVER shard2 OPTIONS (user 'copay_admin', password :pw);

-- Sharded wallets: HASH on user_id, two shards.
CREATE TABLE wallets_sharded (
    id bigint, user_id bigint NOT NULL, kind text NOT NULL, balance numeric(14,2) NOT NULL
) PARTITION BY HASH (user_id);
CREATE FOREIGN TABLE wallets_sharded_p0 PARTITION OF wallets_sharded
    FOR VALUES WITH (MODULUS 2, REMAINDER 0) SERVER shard1 OPTIONS (table_name 'wallets_s');
CREATE FOREIGN TABLE wallets_sharded_p1 PARTITION OF wallets_sharded
    FOR VALUES WITH (MODULUS 2, REMAINDER 1) SERVER shard2 OPTIONS (table_name 'wallets_s');

-- Sharded ledger: same key, so a user's wallet and entries are co-located.
CREATE TABLE ledger_sharded (
    id bigint, txn_id bigint NOT NULL, wallet_id bigint NOT NULL, user_id bigint NOT NULL,
    amount numeric(14,2) NOT NULL, created_at timestamptz NOT NULL
) PARTITION BY HASH (user_id);
CREATE FOREIGN TABLE ledger_sharded_p0 PARTITION OF ledger_sharded
    FOR VALUES WITH (MODULUS 2, REMAINDER 0) SERVER shard1 OPTIONS (table_name 'ledger_entries_s');
CREATE FOREIGN TABLE ledger_sharded_p1 PARTITION OF ledger_sharded
    FOR VALUES WITH (MODULUS 2, REMAINDER 1) SERVER shard2 OPTIONS (table_name 'ledger_entries_s');
