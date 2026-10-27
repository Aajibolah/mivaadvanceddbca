# Backup and recovery

## 1. What was run: logical backup and restore test

`backup/backup_restore_test.ps1` performs, against the local Copay database:

1. a compressed custom format `pg_dump` (plus a schema only SQL dump for review);
2. a restore with `pg_restore` into a brand new database (`copay_restore_test`, created from `template0`);
3. a comparison of row counts, the sum of ledger amounts, an MD5 checksum over every ledger row, and the reconciliation result between the source and the restored copy;
4. a check that the restored database still enforces a business rule (the append only trigger rejects a ledger delete).

A backup is only proven by a restore: a dump file that has never been restored is an assumption. The script stops at "backup verified by restore" only if every check matches.

### Your results (fill in from your own run)

Run `.\backup\backup_restore_test.ps1 | Tee-Object evidence\p5-backup-restore.log` and record:

| Item | Your value |
|---|---|
| Database size on disk | |
| Dump file size | |
| Dump time (s) | |
| Restore time (s) | |
| Checks matching | x of 10 |
| Restore errors | |

### Why `pg_dump` custom format

| Format | Use |
|---|---|
| `-Fc` custom | compressed, can restore selected tables, parallel restore (`-j`); chosen |
| plain SQL | readable, good for schema review and diffs, slow to restore large data |
| `-Fd` directory | parallel dump as well as parallel restore for big databases |

### What a logical backup cannot do

It captures the database as of the moment the dump started (it is a consistent snapshot thanks to MVCC), but it cannot restore to a different point in time, and restoring a large database re-creates every index so it is slow. The recovery point is the time of the last dump: with a nightly dump, up to 24 hours of payments could be lost. That is not acceptable for a payments platform, which is why point in time recovery is needed.

## 2. Point in time recovery (PITR): explained, not executed

> The PITR steps below are an explanation. They were **not** run in this project.

**Idea.** Take a physical base backup occasionally, and keep every WAL (write ahead log) segment generated afterwards. Restoring the base backup and replaying WAL up to a chosen moment recreates the database as it was at that moment, to the second.

**Setup on the primary**
```
wal_level = replica
archive_mode = on
archive_command = 'copy "%p" "D:\\pg_wal_archive\\%f"'     (on Linux: cp, or a tool such as pgBackRest or WAL-G to object storage)
```
Take a base backup: `pg_basebackup -D D:\base\2026-10-25 -X stream -Ft -z`.

**Disaster.** At 14:07 someone runs a wrong `UPDATE` that corrupts balances. The team decides to return to 14:06.

**Recovery**
1. Stop the damaged server (or restore on a separate server, which is safer).
2. Restore the last base backup into an empty data directory.
3. Configure `restore_command = 'copy "D:\\pg_wal_archive\\%f" "%p"'`, `recovery_target_time = '2026-10-25 14:06:00'`, `recovery_target_action = 'promote'`, and create an empty `recovery.signal` file.
4. Start PostgreSQL. It replays WAL until the target time, then promotes itself on a new timeline.
5. Verify (reconciliation query, spot checks), then redirect the application, or copy the corrected data back into production.

**Properties**
- Recovery point objective: seconds (as long as WAL is archived continuously, or less with streaming replicas).
- Recovery time: restore time of the base backup plus WAL replay time. Frequent base backups keep replay short.
- It also protects against logical mistakes that replication would copy instantly to the replica (a bad `UPDATE` replicates).
- The ledger is append only, so most corrections can be done by posting reversing entries; PITR is for the cases where that is not enough.

## 3. Recommended backup strategy for Copay

| Layer | What | Frequency | Retention | Purpose |
|---|---|---|---|---|
| Replication | synchronous standby in a second zone | continuous | n/a | hardware or zone failure, not human error |
| Physical base backup + WAL archive | PITR | base weekly, WAL continuous | 14 to 35 days | human error, corruption |
| Logical dump (`pg_dump`) | portability, schema review, single table recovery | nightly | 30 days | migrations, auditing, small restores |
| Off site copy | encrypted copy in another region or provider | daily | per policy | regional disaster, ransomware |
| Restore drill | run `backup_restore_test.ps1` equivalent | monthly | n/a | proves the backups work |

Also keep backups encrypted, access controlled, and monitored (alert when a backup fails or WAL archiving falls behind).

## 4. Recovery objectives

| Scenario | Protection | Typical RPO | Typical RTO |
|---|---|---|---|
| Primary server crash | synchronous standby, failover | 0 for acknowledged commits | minutes |
| Operator deleted a table | PITR | seconds | tens of minutes |
| Corrupted data discovered days later | PITR within retention, or reversing ledger entries | seconds | hours |
| Loss of the whole region or provider | off site backup restored elsewhere | up to the last copy | hours |

The numbers are targets for discussion, not measurements from this project.
