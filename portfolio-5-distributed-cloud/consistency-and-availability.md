# Consistency and availability at Copay

This is the design discussion for the distributed exercise. The experiments that support it are in `replication/` (lag, synchronous commit, failover) and `sharding/` (cross shard transfer).

## 1. CAP and PACELC in one paragraph

CAP says that during a network **P**artition a distributed database must choose between **C**onsistency (every read sees the latest write, or an error) and **A**vailability (every request gets an answer, possibly stale). Partitions are rare, so PACELC adds the everyday trade off: **E**lse (no partition) you still choose between **L**atency and **C**onsistency, because waiting for other nodes to confirm a write costs time.

## 2. What Copay needs, data type by data type

| Data | Needs | Choice | Reason |
|---|---|---|---|
| Wallet balances, ledger, loan funding, repayments | Strong consistency | **CP** (and PC/EC) | A stale balance can allow an overdraft or a double spend. Refusing a payment for a few seconds during an outage is better than moving money wrongly. |
| Loan request status and funding progress | Strong consistency for the write, short staleness acceptable on the marketplace list | CP for writes, replica reads allowed for browsing | Two lenders must not over fund a request, but the list a lender browses can be a second or two behind. |
| Notifications | Eventual | **AP** | A notification arriving a few seconds late harms nobody. Never blocks a payment. |
| Activity events, analytics, admin dashboard | Eventual | **AP** | Aggregates tolerate staleness; served from a replica or MongoDB. |
| Idempotency keys | Strong | CP | A retry must reliably see the earlier attempt. |
| Search by name, KYC document metadata | Eventual | AP | Convenience features. |

Rule of thumb used in the design: **money is CP, everything around money is AP.**

## 3. Replication trade off, measured here

`replication/sync_experiment.ps1` runs the same 300 commits in each mode on the local primary and replica:

| Mode | What the commit waits for | Data loss risk if the primary dies | Latency | Availability if the replica is down |
|---|---|---|---|---|
| `synchronous_commit = off` | nothing, not even the local WAL flush | the last few hundred milliseconds of commits | lowest | unaffected |
| `local` | local WAL flush only | commits not yet shipped to the replica | low | unaffected |
| `on` with no synchronous standby | local flush (replication is asynchronous) | same as `local` | low | unaffected |
| `remote_write` with a sync standby | replica has received the WAL | very small | higher | **blocked** |
| `on` with a sync standby | replica has flushed the WAL to disk | none for acknowledged commits | higher | **blocked** |
| `remote_apply` with a sync standby | replica has replayed the change (visible to reads there) | none | highest | **blocked** |

Record your own timings in the table in the README. The relative order, not the absolute numbers, is the lesson: each step of safety adds a network round trip.

Part C of the script shows the availability cost directly: with a synchronous standby required and the replica stopped, an `INSERT` waits in the `SyncRep` state indefinitely. The operator (or an HA tool such as Patroni) has to decide to degrade to asynchronous replication. This is the "consistency over availability" choice in practice.

**Copay's choice.** Wallet and ledger writes use synchronous replication to one standby in another availability zone (`synchronous_commit = on`, `synchronous_standby_names = 'ANY 1 (replica_a, replica_b)'` once two standbys exist, so that one standby being down does not block payments). Everything else may run asynchronously.

## 4. Read your own writes

`replication/lag_demo.ps1` makes the replica apply changes five seconds late. A row written to the primary is invisible on the replica until the delay passes. In product terms: a user tops up a wallet, the app reads the balance from a lagging replica, and the screen shows the old balance. Rules for Copay:

1. After a write, read the affected wallet from the **primary** (or pass the commit LSN and wait for the replica to reach it).
2. Reads that may be stale go to replicas: marketplace listing, history older than a minute, search, dashboards.
3. Expose replication lag as a metric and alert on it, and stop sending reads to a replica that is more than a few seconds behind.

## 5. Failover

`replication/failover.ps1` stops the primary, shows that the replica is still read only, then runs `pg_promote()`. What the application and operators do in production:

1. Detect the failure (health checks, not a single missed ping) and **fence** the old primary so it cannot accept writes (stop it, revoke its network access). Two primaries accepting writes is split brain.
2. Promote the most up to date replica (compare replay LSNs). With synchronous replication none of the acknowledged commits are lost; with asynchronous replication the most recent ones may be.
3. Repoint the application (DNS, a virtual IP or a connection proxy such as PgBouncer or HAProxy). The application retries idempotent requests; the idempotency keys from Portfolio 3 make a retry safe even if the original commit actually succeeded.
4. Rebuild the old primary as a replica of the new one (`pg_rewind` or a fresh base backup). The new timeline number (it changes from 1 to 2 on promotion) prevents it silently rejoining as a primary.
5. Reconcile: run the ledger reconciliation query on the new primary.

Failover here is manual. A managed service (RDS Multi-AZ, see `cloud-deployment.md`) automates detection, promotion and DNS repointing, typically in one to two minutes.

## 6. Where the choices appear in the other portfolios

- Portfolio 3: row locks and `SERIALIZABLE` give consistency inside one node.
- Portfolio 4: MongoDB defaults favour consistency for writes on the primary but allow tunable read and write concerns; used only for AP style data.
- This portfolio: replication across nodes and sharding across servers raise the same questions at larger scale.
