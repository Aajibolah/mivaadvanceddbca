# Sharding design for Copay

The runnable part is in `sharding/`: two PostgreSQL shards behind a router that uses `postgres_fdw`, with the data hash partitioned by `user_id`. This document explains the choices and the limits.

## 1. Why shard at all

Copay at 3,200 users does **not** need sharding; one PostgreSQL server (with a replica) handles it comfortably. Sharding is the answer to a different problem: a single server running out of write capacity, storage or memory. The exercise shows how the design would change if Copay grew to millions of users. The honest recommendation for the real product is to scale vertically, add read replicas, partition the ledger by month (`partitioning/`) and shard only when measurements demand it, because sharding makes joins, transactions and operations harder.

## 2. Shard key: `user_id`

| Candidate key | Good | Bad |
|---|---|---|
| **`user_id` (chosen)** | A user's wallet, ledger entries, loans as borrower and notifications are co-located. The two most common screens (balance, statement) touch one shard. Users are numerous and fairly even. | A transfer or funding between two users on different shards is a cross shard transaction. Very active users create hot spots. |
| `wallet_id` | Same distribution | Needs a lookup from the user to wallets; a user with several wallets would span shards |
| `loan_request_id` | Funding progress of one request is local | A user's statement fans out across all shards |
| Date (range) | Easy archiving | All new writes hit the newest shard: a permanent hot spot |
| Region | Data residency, local latency | Uneven sizes, cross region transfers |

Hash distribution (`MODULUS 2`) spreads users evenly. Range distribution would keep neighbouring ids together, which is useful for scans but concentrates new users on the last shard.

**Observed.** `routing_queries.sql` sections 1 and 6 show the split of wallets (very close to 50/50) and ledger rows (less even), and the share of the busiest users. Even distribution of users does not guarantee even load: one lender with thousands of entries makes their shard heavier. Record the percentages you measured.

## 3. How routing works here

The parent tables `wallets_sharded` and `ledger_sharded` are partitioned by `HASH (user_id)`. Each partition is a **foreign table** that points at a table on a shard server. PostgreSQL then:

- sends an `INSERT` to the right shard from the hash of `user_id`;
- prunes a query that filters by `user_id` to a single shard (section 2 of `routing_queries.sql`, one `Foreign Scan`);
- fans out a query without the key to every shard (section 3, an `Append` of two `Foreign Scan`s);
- pushes a grouped aggregate to the shards when the grouping is the shard key (section 4b, `GROUP BY` appears in the Remote SQL) but pulls all rows for a global total (4a).

## 4. The cross shard problem: a transfer between users on two shards

A ledger posting must be atomic: debit on shard A, credit on shard B. A plain `BEGIN ... COMMIT` cannot span two servers. Options:

| Approach | How | Trade off |
|---|---|---|
| **Two phase commit (2PC)** | Prepare both sides (`PREPARE TRANSACTION`), then commit both | Atomic, but prepared transactions hold locks while "in doubt", and a coordinator crash between phases blocks the rows until someone decides (see Scenario 3 in `cross_shard_2pc.ps1`). Needs `max_prepared_transactions > 0` |
| **Saga** | A sequence of local transactions with compensating steps | No cross server locks, scales well, but intermediate states are visible and compensations must be designed carefully |
| **Avoid cross shard writes** | Put both sides on one shard by design | Not possible for arbitrary user to user flows |

**What Copay would do.** Money movement uses a **saga with an escrow account on each shard**, which keeps every individual step a local ACID transaction:

1. Shard A, local transaction: debit the lender's wallet, credit shard A's escrow wallet, record an outbox message "transfer T1 to shard B" with an idempotency key.
2. A relay delivers the message to shard B (at least once).
3. Shard B, local transaction: debit shard B's escrow wallet, credit the borrower. Idempotent on the key, so redelivery is safe.
4. If step 3 cannot complete (the destination is closed), a compensating transaction on shard A returns the money to the lender.

At every moment money is in exactly one place (a user wallet or an escrow wallet) and each shard's ledger balances to zero, so the reconciliation query still works per shard. This is why the Portfolio 1 ledger was built as double entry with explicit system wallets.

2PC is shown because it is the textbook answer and the failure mode is instructive; the saga is the recommended design for high volume.

## 5. Global tables

Not everything is sharded: system wallets (ESCROW, FEES, EXTERNAL) are singletons that every transaction touches. In a sharded design they become **one per shard**, reconciled periodically, otherwise they are a serialisation point (a hot row, already noted in Portfolio 3). Reference data (bank codes, enums) is replicated to every shard.

## 6. Rebalancing and growth

With `MODULUS 2`, going to 3 shards changes the home of most rows. Production approaches: create many more logical partitions than servers (for example 64) and move whole partitions between servers; or use consistent hashing. Neither is automated by `postgres_fdw`.

## 7. Why `postgres_fdw` and not Citus

Citus would give a real distributed planner, parallel queries across shards, distributed transactions and a shard rebalancer. It is distributed as Linux packages or containers and has no Windows installer, so it cannot run on this machine without Docker or a VM. `postgres_fdw` ships with PostgreSQL and is enough to demonstrate: a shard key, routing, pruning, fan out, co-location, and the cross shard transaction problem. What it lacks, and a production system would need: parallel fan out (shards are queried one after another), automatic distributed transactions, shard rebalancing, and cluster wide DDL.

## 8. Operations checklist for a sharded Copay

- Backups and replicas per shard, plus a consistent snapshot strategy across shards for audit.
- Monitor skew (rows and load per shard) and prepared transactions (`pg_prepared_xacts`).
- Schema changes rolled out shard by shard, backwards compatible.
- Reporting from a separate replicated warehouse, not from the sharded write path.
