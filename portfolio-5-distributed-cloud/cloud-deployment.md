# Cloud deployment design for Copay (discussion only)

> **Status: design discussion. Nothing in this document was deployed.** No cloud account was used and no cloud screenshots exist. The local replication, partitioning, sharding and backup exercises are in the other files and are the only things that were actually run. Do not present this section as deployment evidence.

## 1. Choice of service

| Option | Fit for Copay | Notes |
|---|---|---|
| **Managed PostgreSQL: Amazon RDS for PostgreSQL** (chosen for the design) | Same engine as the local work, so every script, trigger and extension used in Portfolios 1 to 3 carries over unchanged | Multi-AZ failover, automated backups with point in time recovery, read replicas, encryption, patching handled by the provider |
| Amazon Aurora PostgreSQL | Faster failover and storage that scales automatically, up to 15 read replicas | Higher cost, some behaviour differences, tied to AWS |
| Google Cloud SQL or Azure Database for PostgreSQL | Equivalent managed offerings | Pick the one matching the company's cloud and region needs |
| Self managed PostgreSQL on virtual machines | Full control, can sit in a Nigerian data centre | You own patching, backups, failover (Patroni) and on call |

Reason for RDS: Copay is a small team. Operating failover and backups reliably is hard and does not differentiate the product, so buying it is cheaper than building it. Switch to Aurora only when failover time or read scaling becomes a measured problem.

## 2. Reference architecture

```
                    Internet
                        |
              [ Load balancer / WAF ]            public subnet
                        |
                [ Copay API servers ]            private subnet (app tier), 2+ AZs
                        |   TLS
        ----------------+-----------------
        |                                 |
 [ RDS PostgreSQL primary ]  --sync-->  [ Multi-AZ standby ]     private subnet (data tier)
        |                                  (different availability zone)
        +--async--> [ Read replica ] --> reports, dashboards, marketplace reads
        |
        +--> automated backups + WAL archive (point in time recovery) --> object storage
```

Mapping to the exercises: the Multi-AZ standby is the synchronous replica from `replication/sync_experiment.ps1`; the read replica is the asynchronous replica from `replication/lag_demo.ps1`; automatic failover is `replication/failover.ps1` done by the provider.

## 3. Availability and durability

- **Multi-AZ deployment.** A synchronous standby in a second availability zone. On failure the provider promotes it and repoints the DNS name, typically in one to two minutes. Matches the CP decision for money (see `consistency-and-availability.md`).
- **Read replicas** for marketplace browsing and reports, with replica lag monitored and reads that must see a user's own write sent to the primary.
- **Backups and PITR.** Automated daily snapshots plus continuous WAL archiving allow restoring to any second inside the retention window (see `backup-and-recovery.md`). A restore always creates a new instance, never overwrites production. Retention set to match audit needs, and a periodic manual snapshot copied to another region for disaster recovery.
- **Targets (to be agreed with the business):** recovery point objective close to zero for committed payments (synchronous standby); recovery time objective of minutes for an availability zone failure, hours for a regional disaster restored from the copied snapshot.

## 4. Security

| Control | Design |
|---|---|
| Encryption at rest | Storage, snapshots and replicas encrypted with a customer managed key (KMS). Cannot be turned on later for an existing instance without a snapshot copy, so it is enabled at creation |
| Encryption in transit | TLS required (`rds.force_ssl = 1`), certificate verification in the app (`sslmode=verify-full`) |
| Network | Database in private subnets with no public IP. Security group allows port 5432 only from the API tier's security group. Administration through a bastion or a session manager, never an open port |
| Identity | Separate roles for the application (no superuser, only the privileges it needs, no direct `UPDATE` on `wallets`), migrations, read only reporting, and humans (IAM authentication where possible). The shared superuser used in the local exercises would not exist here |
| Secrets | Credentials in a secrets manager with rotation, never in code or `.env` files |
| Auditing | `pgaudit` for privileged and DDL activity, database logs to a log service, CloudTrail for infrastructure changes. The application `audit_logs` table remains the business audit trail |
| Sensitive data | BVN stored only as a hash (Portfolio 1). Column level encryption for any raw identifiers that must be kept |

## 5. Cost and sizing (no figures quoted)

Prices change and depend on region, so none are quoted here. The cost drivers to estimate in the provider's pricing calculator: instance class (start small and burstable for a pilot), Multi-AZ (roughly doubles the instance cost), storage and provisioned IOPS, each read replica (a full instance), backup storage beyond the free allowance, cross region snapshot copies and data transfer. Controls: size from measured load, use reserved capacity once stable, turn off non production databases out of hours, and delete old snapshots by policy.

## 6. Nigerian data residency and regulation

The Nigeria Data Protection Act 2023 (NDPA) and the regulator (the Nigeria Data Protection Commission), plus financial sector rules from the Central Bank of Nigeria, govern personal and financial data. Points to resolve with the company's legal and compliance team before choosing a region:

- Whether customer personal data and payment records may be stored outside Nigeria, and under what safeguards (the NDPA restricts cross border transfers unless adequacy or appropriate safeguards exist).
- Whether any regulator expects financial records to be held in country or accessible locally.
- That the chosen provider offers a region close to Nigerian users for latency, and whether any region exists inside Nigeria. Availability of regions changes, so check the provider's current list rather than assume one.
- Data minimisation, retention periods, breach notification procedures and the data subject rights (access, correction, erasure subject to financial record retention duties).

If in country hosting turns out to be required and no suitable managed region exists, the fallback is self managed PostgreSQL with Patroni on virtual machines in a Nigerian data centre, which is more work but uses exactly the replication, failover and backup techniques practised locally in this portfolio.

## 7. Migration path from the local design

1. Create the RDS instance with the settings above; load the schema with `schema.sql` (with the `DROP SCHEMA` line removed).
2. Create application roles and revoke direct write access to `wallets`.
3. Load data with `pg_dump` and `pg_restore` (practised in `backup/backup_restore_test.ps1`) or logical replication for a low downtime cutover.
4. Run the reconciliation query and the rule tests from Portfolio 1 against the new database.
5. Point the application at the new endpoint, keep the old database read only for a safety period.

## 8. What was run locally and what was not

| Topic | Run locally | Discussion only |
|---|---|---|
| Streaming replication, lag, synchronous commit, failover | Yes (`replication/`) | Managed Multi-AZ automation |
| Table partitioning | Yes (`partitioning/`) | |
| Hash sharding with 2PC | Yes (`sharding/`) | Citus, rebalancing |
| Logical backup and restore | Yes (`backup/`) | Provider snapshots |
| Point in time recovery | No | Explained in `backup-and-recovery.md` |
| Cloud deployment, KMS, security groups, IAM, cost | No | This document |
