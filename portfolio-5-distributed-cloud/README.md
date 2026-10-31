# Portfolio 5: Distributed and Cloud Database Exercise (Copay)

Same Copay case study. Everything runs **natively on Windows**, with several PostgreSQL instances on different ports. No Docker is needed. The cloud part is a design discussion and is labelled as such.

## What was run locally and what is discussion only

| Topic | Type | Where |
|---|---|---|
| Streaming replication primary to replica, `pg_stat_replication`, read only replica | **Run locally** | `replication/` |
| Replication lag and stale reads | **Run locally** | `replication/lag_demo.ps1` |
| Synchronous against asynchronous commit, timings, availability cost | **Run locally** | `replication/sync_experiment.ps1` |
| Failover by stopping the primary and `pg_promote()` | **Run locally** | `replication/failover.ps1` |
| Range partitioning of the ledger by month, partition pruning | **Run locally** | `partitioning/` |
| Hash sharding by `user_id` across two servers with `postgres_fdw` | **Run locally** | `sharding/` |
| Cross shard transfer with two phase commit | **Run locally** | `sharding/cross_shard_2pc.ps1` |
| Backup and restore with verification | **Run locally** | `backup/` |
| CAP, PACELC, consistency and availability mapped to Copay | Discussion | [consistency-and-availability.md](consistency-and-availability.md) |
| Shard key choice, sagas, hot spots, why `postgres_fdw` | Discussion with the demo as support | [sharding-design.md](sharding-design.md) |
| Point in time recovery | Discussion (not run) | [backup-and-recovery.md](backup-and-recovery.md) |
| Cloud deployment (RDS, Multi-AZ, security, cost, NDPA) | **Discussion only, nothing deployed** | [cloud-deployment.md](cloud-deployment.md) |

## Setup

Prerequisites: Portfolio 1 loaded in your main database, PostgreSQL server binaries (the PostgreSQL installer includes `initdb`, `pg_ctl`, `pg_basebackup`, `postgres_fdw`), PowerShell, the Python venv.

```powershell
cd portfolio-5-distributed-cloud
$env:PGPASSWORD = "<the password from your .env>"      # also used as the password of every test instance
$env:PGBIN = "C:\Program Files\PostgreSQL\18\bin"        # only if different
```

If scripts are blocked: `powershell -ExecutionPolicy Bypass -File .\replication\setup_replication.ps1`.

The test instances live in `.cluster\` (git ignored). They use ports 5433 and 5434 (replication) and 5440 to 5442 (sharding), so they do not touch your main PostgreSQL service on 5432. `cleanup.ps1` stops and deletes them.

## 1. Replication

```powershell
.\replication\setup_replication.ps1 -LoadData     # primary 5433 + replica 5434, loads the Copay data first (about 3 minutes)
```

Without `-LoadData` the pair is created empty, which is enough for every replication demo.

Checks (run each against the port shown):

```powershell
psql -h localhost -p 5433 -U copay_admin -d postgres -c "SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication"
psql -h localhost -p 5434 -U copay_admin -d postgres -c "SELECT pg_is_in_recovery()"          # t on the replica
psql -h localhost -p 5433 -U copay_admin -d copay -c "CREATE TABLE IF NOT EXISTS hello(id serial, at timestamptz default now()); INSERT INTO hello DEFAULT VALUES;"
psql -h localhost -p 5434 -U copay_admin -d copay -c "SELECT * FROM hello"                    # the row arrived
psql -h localhost -p 5434 -U copay_admin -d copay -c "INSERT INTO hello DEFAULT VALUES"       # ERROR: read-only transaction
```

Then the experiments, in this order:

```powershell
.\replication\lag_demo.ps1            # stale read on the replica for 5 seconds
.\replication\sync_experiment.ps1     # timings per commit mode; a commit that blocks when the replica is gone
.\replication\failover.ps1            # stop primary, promote replica, new timeline  (run last: it ends the primary)
```

`replication_checks.sql` collects the monitoring queries (`pg_stat_replication`, slots, replica lag functions) with comments.

What the application would do on failover (fencing, promotion, repointing, idempotent retries, rebuilding the old primary) is in [consistency-and-availability.md](consistency-and-availability.md).

## 2. Partitioning

Runs on your main Copay database:

```powershell
psql -f partitioning\01_range_partition_ledger.sql
```

It builds `ledger_entries_part`, a copy of the ledger partitioned by month, loads it from the live ledger, proves the row counts match, and shows: rows per partition, a one month query scanning one partition while the unpartitioned ledger needs a full scan, a count of partitions scanned for different query shapes (one month: 1, wallet without a date: all), detaching an old month as a metadata operation, and a function that creates next month's partition.

Design decisions: monthly range partitions on `created_at` because the ledger is append only and almost every report is date bound; the primary key must include the partition key `(id, created_at)`; a DEFAULT partition catches out of range rows; the live ledger is left untouched so the Portfolio 1 triggers keep protecting it.

## 3. Sharding

```powershell
.\cleanup.ps1                                       # if replication instances are still running
.\sharding\setup_shards.ps1                         # shard1 5441, shard2 5442, router 5440, loads wallets and ledger rows
psql -h localhost -p 5440 -U copay_admin -d copay_router -f sharding\routing_queries.sql
.\sharding\cross_shard_2pc.ps1
```

Pass `-SourcePort` if your main database is not on 5432, and `-LedgerLimit` to change how many ledger rows are copied (default 60,000 of the most recent).

`routing_queries.sql` shows: which shard each row landed on, single shard pruning for a query with `user_id`, fan out without it, which aggregates are pushed to the shards, inserts routed by the key, and skew. `cross_shard_2pc.ps1` runs three scenarios: a successful two phase transfer, a failure on the second shard with rollback of the first, and an in doubt prepared transaction that blocks the row. Reasoning and the recommended saga design: [sharding-design.md](sharding-design.md).

## 4. Backup and restore

Run against the main database (set the `PG*` variables first):

```powershell
.\backup\backup_restore_test.ps1 | Tee-Object evidence\p5-backup-restore.log
```

See [backup-and-recovery.md](backup-and-recovery.md) for the results table to fill in, PITR, and the strategy.

## Tools used and why

The scripts that create and stop servers (`setup_replication.ps1`, `setup_shards.ps1`, `lag_demo.ps1`, `sync_experiment.ps1`, `failover.ps1`, `cross_shard_2pc.ps1`, `backup_restore_test.ps1`, `cleanup.ps1`) can only be run from PowerShell, so those steps and their screenshots come from the terminal. The plain SQL steps (partitioning, the replication status and read only checks, and the shard routing queries) I ran in pgAdmin 4, as I did for the concurrency scenarios in Portfolio 3, because results and errors are easy to read and capture there and typing SQL at a PowerShell prompt had already caused errors. In pgAdmin, each extra instance is a registered server on its own port (`Primary 5433`, `Replica 5434`, `Router 5440`), and the tab title (for example `copay/copay_admin@Router 5440`) shows which server a result came from. The statements I pasted into pgAdmin are in [pgadmin-steps.md](pgadmin-steps.md).

## Evidence

| File | Tool | Shows |
|---|---|---|
| `evidence/p5-01-pg-stat-replication.png` | pgAdmin, `Primary 5433` | `replica1`, `streaming`, `async` |
| `evidence/p5-02-1-replica-read.png` | pgAdmin, `Replica 5434` | the rows written on the primary are readable on the replica |
| `evidence/p5-02-2-replica-readonly.png` | pgAdmin, `Replica 5434` | a write is refused: `cannot execute INSERT in a read-only transaction` |
| `evidence/p5-03-lag.png` | terminal, `lag_demo.ps1` | a row written on the primary is not visible on the replica, then visible after the delay |
| `evidence/p5-04-sync-timings.png` | terminal, `sync_experiment.ps1` | 300 commits per mode: 16 ms (`off`), 44 ms (`local`), 43 ms (`on`, async); with a synchronous standby 39, 87, 94 and 112 ms |
| `evidence/p5-05-sync-blocked.png` | terminal, `sync_experiment.ps1` Part C | the commit is stuck in `SyncRep` while the replica is down, and is released by falling back to asynchronous replication |
| `evidence/p5-06-failover.png` | terminal, `failover.ps1` | the replica is read only, `pg_promote()` makes it a primary, a write is accepted, timeline 2 |
| `evidence/p5-07-1-partition-rows.png` | pgAdmin, main server | rows in each of the 22 monthly partitions |
| `evidence/p5-07-2-counts-match.png` | pgAdmin, main server | live ledger and partitioned copy both hold 180,874 rows |
| `evidence/p5-07-3-pruning.png` | pgAdmin, main server | a one month query scans only `ledger_entries_p2026_03` |
| `evidence/p5-07-4-unpartitioned.png` | pgAdmin, main server | the same query on the unpartitioned ledger scans the whole table |
| `evidence/p5-08-partitions-scanned.png` | pgAdmin, main server | partitions touched: 1 with a date range, 25 with no date, 1 with wallet and date range |
| `evidence/p5-08-2-detach.png` | pgAdmin, main server | a partition detached in one operation keeps its 61 rows and leaves the parent |
| `evidence/p5-09-shard-distribution.png` | terminal, `setup_shards.ps1` | wallets 1,594 and 1,601 per shard; ledger rows 28,653 and 31,347 |
| `evidence/p5-10-1-shard-rows.png` | pgAdmin, `Router 5440` | wallets and balances per shard |
| `evidence/p5-10-2-one-shard.png` | pgAdmin, `Router 5440` | a query with the shard key goes to one `Foreign Scan` |
| `evidence/p5-10-3-fanout.png` | pgAdmin, `Router 5440` | a query without the shard key goes to both shards |
| `evidence/p5-10-4-global-aggregate.png` | pgAdmin, `Router 5440` | a global total pulls every row to the router |
| `evidence/p5-10-5-grouped-aggregate.png` | pgAdmin, `Router 5440` | a total grouped by the shard key is computed on each shard |
| `evidence/p5-10-6-skew.png` | pgAdmin, `Router 5440` | the five busiest users and their share of the ledger (the busiest holds 3.56 percent) |
| `evidence/p5-11-2pc.png` | terminal, `cross_shard_2pc.ps1` | two phase commit: success, rollback after a failure, and an in doubt transaction blocking a row |
| `evidence/p5-12-backup-restore.png`, `evidence/p5-backup-restore.log` | terminal, `backup_restore_test.ps1` | dump and restore with ten matching checks and 0 restore errors |

## Limits of this setup (state them in your write up)

- All instances run on one machine, so network latency, partitions and independent hardware failures are simulated by stopping processes, not real. Replication lag was produced artificially with `recovery_min_apply_delay`.
- `postgres_fdw` is a teaching substitute for a sharding system (see [sharding-design.md](sharding-design.md) section 7).
- Failover is manual. Production uses an HA tool or a managed service.
- Cloud deployment was not performed.

## Testing

I ran every script in `replication/`, `partitioning/`, `sharding/` and `backup/` on my own laptop with PostgreSQL 18.1 and captured the results listed above. Running them found two problems that I fixed: the helper that counts partitions scanned missed index scans (it first reported 1, 6 and 0 instead of 1, 25 and 1), and a screenshot taken on the wrong server (the main server instead of the primary on port 5433) showed an empty replication view. I re-ran both and retook the screenshots.
