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

## Evidence to capture

| File | Command | Show |
|---|---|---|
| `evidence/p5-01-pg-stat-replication.png` | query on port 5433 | `state = streaming` |
| `evidence/p5-02-replica-readonly.png` | commands above on port 5434 | row replicated, insert refused |
| `evidence/p5-03-lag.png` | `lag_demo.ps1` | row not visible, then visible |
| `evidence/p5-04-sync-timings.png` | `sync_experiment.ps1` Parts A and B | timings per mode |
| `evidence/p5-05-sync-blocked.png` | `sync_experiment.ps1` Part C | commit stuck in `SyncRep` |
| `evidence/p5-06-failover.png` | `failover.ps1` | `pg_promote`, writes accepted, new timeline |
| `evidence/p5-07-partition-pruning.png` | partitioning script | one partition scanned |
| `evidence/p5-08-partitions-scanned.png` | partitioning script | 1 against 25 |
| `evidence/p5-09-shard-distribution.png` | `setup_shards.ps1` end and `routing_queries.sql` section 1 | rows per shard |
| `evidence/p5-10-shard-routing.png` | `routing_queries.sql` sections 2 and 3 | one Foreign Scan against two |
| `evidence/p5-11-2pc.png` | `cross_shard_2pc.ps1` | three scenarios |
| `evidence/p5-12-backup-restore.png` | backup script | all checks MATCH |

## Limits of this setup (state them in your write up)

- All instances run on one machine, so network latency, partitions and independent hardware failures are simulated by stopping processes, not real. Replication lag was produced artificially with `recovery_min_apply_delay`.
- `postgres_fdw` is a teaching substitute for a sharding system (see [sharding-design.md](sharding-design.md) section 7).
- Failover is manual. Production uses an HA tool or a managed service.
- Cloud deployment was not performed.

## Testing

Every script in `replication/`, `partitioning/`, `sharding/` and `backup/` was run end to end on a development machine on PostgreSQL 18.1 while writing them, which found and fixed several script bugs. Those runs are not your evidence: run the scripts yourself and capture your own output.
