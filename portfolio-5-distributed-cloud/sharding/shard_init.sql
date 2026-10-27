-- Runs on EACH shard (copay_shard database). A shard is an ordinary PostgreSQL
-- database that holds only the users whose hash(user_id) maps to it.
CREATE TABLE wallets_s (
    id      bigint PRIMARY KEY,
    user_id bigint        NOT NULL,
    kind    text          NOT NULL,
    balance numeric(14,2) NOT NULL CHECK (balance >= 0)
);
CREATE INDEX wallets_s_user ON wallets_s (user_id);

-- The ledger rows of a user's wallet live on the same shard as the wallet, so a
-- statement for one user never needs a second shard. user_id is repeated on the
-- row (denormalised) because it is the shard key.
CREATE TABLE ledger_entries_s (
    id         bigint PRIMARY KEY,
    txn_id     bigint        NOT NULL,
    wallet_id  bigint        NOT NULL,
    user_id    bigint        NOT NULL,
    amount     numeric(14,2) NOT NULL CHECK (amount <> 0),
    created_at timestamptz   NOT NULL
);
CREATE INDEX ledger_entries_s_wallet ON ledger_entries_s (wallet_id, created_at DESC);
