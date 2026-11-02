# Changelog

## 2026-11-02 (session 4, early morning, West Africa Time)

### Portfolio 4 run and committed
- MongoDB Community Server 9.0.4 installed as a Windows service (a leftover empty install folder had to be replaced). Scripts run in the MongoDB Compass built in shell, the seeder in PowerShell, the JSONB comparison in pgAdmin, document, index and validation views in Compass. The standalone `mongosh` was not installed because of limited disk space.
- Evidence: 23 screenshots (`p4-01` to `p4-10`). Validators rejected all five invalid documents, the seed loaded 22,178 notifications, 8,410 graph edges, 6,004 loan applications and 80,419 events, the TTL document was deleted, `explain` showed COLLSCAN turning into IXSCAN (80,419 documents examined before, 20 after), and the JSONB aggregation matched the MongoDB aggregation exactly.
- Noted honestly in the README: a GIN index was not used for an array containment query that matches about 20 percent of the table.
- Portfolio 4 README rewritten around the real evidence and the tools used.

### Still open before submission
- Retake `p1-00-version.png` (the current file shows passwords and is not committed).
- Missing Portfolio 3 pgAdmin screenshots: `p3-12-3-deadlock-error.png` and `p3-13-1-b-waiting.png`.
- Word document, viva prep, AI declaration confirmation, reflection (the student's own words), references, assessor access.

## 2026-11-01 (session 3, night, West Africa Time)

### Evidence collected and committed
- Portfolio 3 scenarios 3 to 5 run by the student in pgAdmin 4 (two Query Tool tabs) and screenshots added (`p3-04` to `p3-16`). Still missing: `p3-12-3-deadlock-error.png` and `p3-13-1-b-waiting.png`.
- Portfolio 5 run by the student: partitioning, replication checks and shard routing in pgAdmin 4; replication, lag, synchronous commit, failover, sharding setup, two phase commit and backup in PowerShell. All evidence in `portfolio-5-distributed-cloud/evidence/`.
- Portfolio 1: ER diagram exported (`er-diagram.png`). `p1-00-version.png` is held back because it shows passwords; it must be retaken before committing.

### Bugs found by running the scripts and fixed
- `count_partitions_scanned` (Portfolio 5) missed index scans and returned 1, 6 and 0 instead of 1, 25 and 1. The pattern now accepts Parallel, Backward and "using index" forms.
- A replication screenshot was taken on the main server instead of the primary on port 5433, which showed an empty result; retaken on the right server.
- The backup log was incomplete because `Tee-Object` does not capture `Write-Host` output; regenerated with `*>&1` and converted from UTF-16 to UTF-8.

### Documentation
- Added `portfolio-5-distributed-cloud/pgadmin-steps.md` (partitioning, replication checks, shard routing in pgAdmin, with no passwords).
- Portfolio 5 README now lists the real evidence files, the tool used for each, and a "Tools used and why" section.

## 2026-10-31 (session 2, evening, West Africa Time)

### Testing and evidence
- Portfolio 1 tested by the student: all 19 rule tests PASS, reconciliation 0, ER diagram exported (mermaid.live). Screenshots reviewed; `p1-00-version.png` to be retaken without passwords.
- Portfolio 2 tested: 28 plan files captured, summary table generated, screenshots reviewed and committed. Fixed a Windows-only bug in `run_plans.ps1` (the SQL temp file was written with a BOM, which psql rejected). Filled in `performance-analysis.md` from the measured plans, the pasted `statistics.sql` output and the screenshots.
- Portfolio 3: `run_scenarios.py` run, log committed (all scenarios behaved as designed). The student found typing SQL into PowerShell error prone, so scenarios 3, 4 and 5 are run in pgAdmin 4 (two Query Tool tabs).

### Documentation
- Added `portfolio-3-transactions-concurrency/pgadmin-scenarios.md` (scenarios 3 to 5 with ready to paste statements, no psql variables).
- Added "Tools used and why" sections to the root README and the Portfolio 3 README, written in the student's own voice: scenarios 3 to 5 run in both pgAdmin and the command line, why pgAdmin was adopted (SQL typed at a PowerShell prompt is read as a PowerShell command) and why it was kept.
- `concurrency-guide.md` points to the pgAdmin version.

## 2026-10-25 (session 1, evening, West Africa Time)

GitHub repo created (private, `Aajibolah/mivaadvanceddbca`). Phase 1 committed and pushed first (seven commits), then on 2026-10-27 Portfolios 2 to 5, the root README update and this changelog were committed in small commits (47 commits in total, all authored by Azeez Akande) and pushed. `docs/TESTING_GUIDE.md` is excluded locally via `.git/info/exclude` and is never committed.

### Setup decisions
- No Docker (laptop cannot run it): everything native on Windows. PostgreSQL 18 (installed) instead of 16, MongoDB Community Server for Portfolio 4.
- `docker-compose.yml` kept as an optional PostgreSQL 16 file only.

### Phase 0 (already committed: `chore: initialise repo structure`, `docs: add Copay case study`)
- Repository structure, `.gitignore`, `.env.example`, `docker-compose.yml`, README skeleton.

### Portfolio 1
- `schema.sql`: 16 tables, enums, constraints, nine triggers (append only ledger, balanced double entry, cached balance, KYC limit, own request, over funding, oldest instalment first), `wallet_reconciliation` view, `mark_overdue()`.
- `seed/generate_seed.py`: event simulation (3,200 users by default, `--users 600` supported), loads with `COPY`, re-verifies reconciliation.
- `rule_tests.sql`: 19 rule tests.
- `er-diagram.md`, `normalisation.md`, `README.md`.

### Portfolio 2
- 14 query files, `queries.sql`, `indexes.sql`, `indexes_drop.sql`, `run_plans.ps1`, `summarise_plans.py`, `materialised_view.sql`, `matview_demo.sql`, `statistics.sql`, `performance-analysis.md`, `README.md`.

### Portfolio 3
- `00_functions.sql` (`fund_loan`, `disburse_loan`, `apply_repayment`, `withdraw_safe`, `transfer`, `transfer_naive`), `01_test_fixtures.sql`, scenario files 02 to 06, `run_scenarios.py`, `concurrency-guide.md`, `README.md`.
- Schema: added `WALLET_TRANSFER` transaction type.

### Portfolio 4
- `schema-validation.js`, `seed_from_postgres.py` (with `--also-jsonb`), `queries.js`, `explain.js`, `jsonb_comparison.sql`, `README.md`.

### Portfolio 5
- Native multi instance scripts: `common.ps1`, `cleanup.ps1`, `replication/` (setup, lag demo, synchronous commit experiment, failover, checks), `partitioning/01_range_partition_ledger.sql`, `sharding/` (setup, loader, routing queries, two phase commit demo), `backup/backup_restore_test.ps1`.
- Documents: `consistency-and-availability.md`, `sharding-design.md`, `cloud-deployment.md` (discussion only), `backup-and-recovery.md`, `README.md`.

### Root
- `README.md` updated (native setup, PostgreSQL 18 note, references, draft AI declaration), `docs/SETUP_WINDOWS.md`, `requirements.txt`.

### Testing done during development (not evidence)
- All code was run on temporary local PostgreSQL 18.1 and MongoDB 7.0.14 instances that have been deleted. Bugs found and fixed this way: invalid schedule insert in `disburse_loan`, stale statement query shape, unreliable "index not used" example, PowerShell argument quoting in the sync experiment, `pg_restore` into a dropped `public` schema, wrongly claimed aggregate pushdown.

### Still to do
- You run every portfolio on your own machine and capture the screenshots and logs into each `evidence/` folder.
- Export `er-diagram.png`, fill in `performance-analysis.md` and the backup results table.
- Write the technical reflection yourself; confirm the AI declaration.
- Phase 6: Word documentation (`docs/MIT8103_Copay_Portfolio_Documentation.docx`), viva prep Q and A, final checklist.
